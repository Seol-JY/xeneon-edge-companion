import Foundation

// SMC temperatures, fans and system power, sampled every 5 s.
// Key discovery follows vladkens/macmon src/metrics.rs `init_smc` (MIT): enumerate all keys once,
// keep the Tp*/Te*/Ts* (CPU) and Tg* (GPU) keys that read as 4-byte floats, then read only those.

final class SensorsReader: TelemetryReader {
  private var temperatureHistory = HistoryBuffer()
  private var powerHistory = HistoryBuffer()
  struct Keys {
    var cpu: [UInt32] = []
    var gpu: [UInt32] = []
    var fans: [UInt32] = []
    var hasPower = false
  }

  private let model: SensorsModel
  private var smc: SMCConnection?
  private var opened = false
  /// Discovered once per process and kept for its lifetime.
  private(set) var keys: Keys?
  private(set) var discoveryMillis: Double = 0
  static let validTemperature: ClosedRange<Float> = 0.001...130
  private static let power = SMCConnection.fourCC("PSTR")

  init(model: SensorsModel) { self.model = model }

  func reset() {}
  func deactivate() {}  // keep the SMC connection and key list for the next activation

  func sample(tick: Int, now: UInt64) {
    guard tick % 5 == 0 else { return }
    if !opened { smc = SMCConnection(); opened = true }
    guard let smc else { return }
    if keys == nil { keys = discover(smc) }
    guard let keys else { return }

    var cpuSum: Float = 0, cpuMax: Float = 0, cpuN = 0
    for k in keys.cpu {
      guard let v = smc.readFloat(k), Self.validTemperature.contains(v) else { continue }
      cpuSum += v; cpuN += 1; cpuMax = max(cpuMax, v)
    }
    var gpuSum: Float = 0, gpuN = 0
    for k in keys.gpu {
      guard let v = smc.readFloat(k), Self.validTemperature.contains(v) else { continue }
      gpuSum += v; gpuN += 1
    }
    let fans: [Int] = keys.fans.compactMap { k in
      guard let v = smc.readFloat(k), v.isFinite, v >= 0, v < 20_000 else { return nil }
      return Int(v.rounded())
    }
    var watts: Double?
    if keys.hasPower, let p = smc.readFloat(Self.power), p >= 0, p < 1000 { watts = Double(p) }

    let cpuAvg: Double? = cpuN > 0 ? (Double(cpuSum) / Double(cpuN) * 10).rounded() / 10 : nil
    let cpuHi: Double? = cpuN > 0 ? (Double(cpuMax) * 10).rounded() / 10 : nil
    let gpuAvg: Double? = gpuN > 0 ? (Double(gpuSum) / Double(gpuN) * 10).rounded() / 10 : nil
    let power = watts.map { ($0 * 100).rounded() / 100 }
    let cpuCount = keys.cpu.count, gpuCount = keys.gpu.count
    if let cpuAvg { temperatureHistory.append(cpuAvg) }
    if let power { powerHistory.append(power) }
    let tempHist = temperatureHistory.values, powerHist = powerHistory.values
    let model = self.model
    publishOnMain {
      model.update(\.cpuTemperature, cpuAvg)
      model.update(\.cpuTemperatureMax, cpuHi)
      model.update(\.gpuTemperature, gpuAvg)
      model.update(\.fanRPMs, fans)
      model.update(\.systemPowerWatts, power)
      model.update(\.cpuTemperatureHistory, tempHist)
      model.update(\.powerHistory, powerHist)
      model.update(\.cpuSensorCount, cpuCount)
      model.update(\.gpuSensorCount, gpuCount)
    }
  }

  private func discover(_ smc: SMCConnection) -> Keys {
    let start = DispatchTime.now().uptimeNanoseconds
    defer { discoveryMillis = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
    var result = Keys()
    var fanCandidates: [UInt32] = []
    for key in smc.allKeys() {
      let c0 = UInt8(key >> 24 & 0xff), c1 = UInt8(key >> 16 & 0xff)
      let c2 = UInt8(key >> 8 & 0xff), c3 = UInt8(key & 0xff)
      if c0 == UInt8(ascii: "F"), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c1),
         c2 == UInt8(ascii: "A"), c3 == UInt8(ascii: "c") {
        fanCandidates.append(key)
        continue
      }
      guard c0 == UInt8(ascii: "T") else { continue }
      let isCPU = c1 == UInt8(ascii: "p") || c1 == UInt8(ascii: "e") || c1 == UInt8(ascii: "s")
      let isGPU = c1 == UInt8(ascii: "g")
      guard isCPU || isGPU else { continue }
      // Keep keys that read as floats with a plausible value right now; keys stuck at 0 are unused.
      guard let v = smc.readFloat(key), Self.validTemperature.contains(v) else { continue }
      if isCPU { result.cpu.append(key) } else { result.gpu.append(key) }
    }
    // Fans: trust FNum when present (0 on fanless Macs), else every F<n>Ac that reads as a float.
    if let n = smc.readUInt(SMCConnection.fourCC("FNum")) {
      result.fans = fanCandidates.filter { Int(UInt8($0 >> 16 & 0xff) - UInt8(ascii: "0")) < Int(n) }
    } else {
      result.fans = fanCandidates.filter { smc.readFloat($0) != nil }
    }
    result.fans.sort()
    result.hasPower = smc.readFloat(Self.power) != nil
    return result
  }
}
