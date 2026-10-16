import Darwin
import Foundation
import IOKit

// CPU usage from host_processor_info tick deltas.
// Adapted from exelban/stats Modules/CPU/readers.swift (MIT, Serhiy Mytrovtsiy).

final class CPUReader: TelemetryReader {
  private let model: CPUModel
  private var previous: [UInt32] = []  // flat [user, system, idle, nice] per core
  private var history = HistoryBuffer()
  private let layout: [(name: String, kind: CPUCluster.Kind, cores: [Int])]

  init(model: CPUModel) {
    self.model = model
    self.layout = CPUReader.clusterLayout()
  }

  func reset() { previous = [] }
  func deactivate() { previous = [] }

  func sample(tick: Int, now: UInt64) {
    var count: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
          let info else { return }
    defer {
      vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                    vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }

    let n = Int(count)
    let stride = Int(CPU_STATE_MAX)
    var current = [UInt32](repeating: 0, count: n * 4)
    for i in 0..<n {
      let base = i * stride
      current[i * 4 + 0] = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
      current[i * 4 + 1] = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
      current[i * 4 + 2] = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
      current[i * 4 + 3] = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
    }
    defer { previous = current }
    guard previous.count == current.count else { return }  // baseline only

    var perCore = [Double](repeating: 0, count: n)
    var sumUser = 0.0, sumSystem = 0.0, sumAll = 0.0
    for i in 0..<n {
      // Counters are 32-bit and wrap; wrapping subtraction keeps the delta right.
      let user = Double(current[i * 4] &- previous[i * 4])
      let system = Double(current[i * 4 + 1] &- previous[i * 4 + 1])
      let idle = Double(current[i * 4 + 2] &- previous[i * 4 + 2])
      let nice = Double(current[i * 4 + 3] &- previous[i * 4 + 3])
      let total = user + system + idle + nice
      perCore[i] = total > 0 ? min(1, (user + system + nice) / total) : 0
      sumUser += user + nice
      sumSystem += system
      sumAll += total
    }
    let usage = sumAll > 0 ? min(1, (sumUser + sumSystem) / sumAll) : 0
    let userUsage = sumAll > 0 ? sumUser / sumAll : 0
    let systemUsage = sumAll > 0 ? sumSystem / sumAll : 0
    history.append(usage)

    let clusters: [CPUCluster] = layout.compactMap { c in
      let cores = c.cores.filter { $0 < n }
      guard !cores.isEmpty else { return nil }
      let avg = cores.reduce(0) { $0 + perCore[$1] } / Double(cores.count)
      return CPUCluster(name: c.name, kind: c.kind, cores: cores, usage: avg)
    }

    var loads = [Double](repeating: 0, count: 3)
    let load = getloadavg(&loads, 3) == 3
      ? LoadAverage(one: loads[0], five: loads[1], fifteen: loads[2]) : nil

    let hist = history.values
    let model = self.model
    publishOnMain {
      model.update(\.usage, usage)
      model.update(\.userUsage, userUsage)
      model.update(\.systemUsage, systemUsage)
      model.update(\.perCore, perCore)
      model.update(\.clusters, clusters)
      model.history = hist
      if let load { model.update(\.loadAverage, load) }
    }
  }

  // MARK: Cluster layout

  /// Which logical CPUs belong to which cluster. Reads `cluster-type` from the device tree
  /// (IODeviceTree:/cpus/cpuN), falling back to hw.perflevelN with efficiency cores numbered first.
  private static func clusterLayout() -> [(name: String, kind: CPUCluster.Kind, cores: [Int])] {
    func kind(_ letter: String) -> CPUCluster.Kind {
      switch letter {
      case "E": return .efficiency
      case "P": return .performance
      case "S": return .superCore
      default: return .unknown
      }
    }
    // perflevel names keyed by kind, e.g. "Performance", "Efficiency".
    let levels = Int(Sysctl.int32("hw.nperflevels") ?? 0)
    var names: [CPUCluster.Kind: String] = [:]
    var levelCounts: [(CPUCluster.Kind, String, Int)] = []
    for i in 0..<levels {
      let name = Sysctl.string("hw.perflevel\(i).name") ?? "Level \(i)"
      let k: CPUCluster.Kind = name.hasPrefix("Eff") ? .efficiency : name.hasPrefix("Perf") ? .performance
        : name.hasPrefix("Super") ? .superCore : .unknown
      names[k] = name
      levelCounts.append((k, name, Int(Sysctl.int32("hw.perflevel\(i).logicalcpu") ?? 0)))
    }

    var byKind: [(CPUCluster.Kind, [Int])] = []
    let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
    if cpus != 0 {
      defer { IOObjectRelease(cpus) }
      var iter: io_iterator_t = 0
      if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iter) == KERN_SUCCESS {
        defer { IOObjectRelease(iter) }
        while case let entry = IOIteratorNext(iter), entry != 0 {
          defer { IOObjectRelease(entry) }
          guard let typeData = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? Data,
                let idNum = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? NSNumber else { continue }
          let letter = String(decoding: typeData.prefix { $0 != 0 }, as: UTF8.self)
          let k = kind(letter)
          if let idx = byKind.firstIndex(where: { $0.0 == k }) {
            byKind[idx].1.append(idNum.intValue)
          } else {
            byKind.append((k, [idNum.intValue]))
          }
        }
      }
    }

    if !byKind.isEmpty {
      return byKind
        .map { (k, cores) in (names[k] ?? k.rawValue.capitalized, k, cores.sorted()) }
        .sorted { ($0.cores.first ?? 0) < ($1.cores.first ?? 0) }
    }
    // Fallback: perflevel0 is the fastest; Apple numbers the slowest cores first.
    var result: [(String, CPUCluster.Kind, [Int])] = []
    var next = 0
    for (k, name, count) in levelCounts.reversed() where count > 0 {
      result.append((name, k, Array(next..<(next + count))))
      next += count
    }
    return result
  }
}
