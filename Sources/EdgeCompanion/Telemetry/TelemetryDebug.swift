import Foundation

/// `swift run EdgeCompanion --telemetry-dump`: retain every metric, sample ~4 s, print all models.
/// `EDGE_TELEMETRY_SECONDS=60` lengthens the window.
enum TelemetryDebug {
  static func run() {
    // Called from top-level code in main.swift, which runs on the main thread.
    MainActor.assumeIsolated { runOnMain() }
  }

  @MainActor private static func runOnMain() {
    let hub = TelemetryHub.shared
    let startCPU = processCPUSeconds()
    let start = Date()
    MetricKind.allCases.forEach(hub.retain)
    // EDGE_TELEMETRY_SECONDS overrides the sampling window (for measuring steady-state overhead).
    let window = ProcessInfo.processInfo.environment["EDGE_TELEMETRY_SECONDS"].flatMap(Double.init) ?? 4.3
    RunLoop.main.run(until: Date(timeIntervalSinceNow: window))
    MetricKind.allCases.forEach(hub.release)
    let wall = Date().timeIntervalSince(start)
    let cpuUsed = processCPUSeconds() - startCPU
    print(dump(hub))
    print(String(format: "[self] %.0f ms CPU over %.1f s wall (%.2f%% of one core, includes one-time SMC key discovery)",
                 cpuUsed * 1000, wall, cpuUsed / wall * 100))
  }

  @MainActor static func dump(_ hub: TelemetryHub) -> String {
    var out: [String] = []
    func line(_ s: String) { out.append(s) }
    func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
    func bytes(_ v: UInt64?) -> String {
      guard let v else { return "n/a" }
      return ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .memory)
    }
    func rate(_ v: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .decimal) + "/s" }
    func temp(_ v: Double?) -> String { v.map { String(format: "%.1f °C", $0) } ?? "n/a" }
    func opt<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "n/a" }

    let c = hub.cpu
    line("== CPU (\(c.chipName))")
    line("  total \(pct(c.usage))  user \(pct(c.userUsage))  system \(pct(c.systemUsage))")
    line("  cores " + c.perCore.map { String(format: "%.0f", $0 * 100) }.joined(separator: " "))
    for cl in c.clusters { line("  \(cl.name) (cpu \(cl.cores.map(String.init).joined(separator: ","))): \(pct(cl.usage))") }
    line(String(format: "  load %.2f %.2f %.2f   history %d samples", c.loadAverage.one, c.loadAverage.five,
                c.loadAverage.fifteen, c.history.count))

    let m = hub.memory
    line("== Memory")
    line("  used \(bytes(m.used)) / \(bytes(m.total)) (\(pct(m.usage)))  app \(bytes(m.app))  wired \(bytes(m.wired))  compressed \(bytes(m.compressed))")
    line("  cached \(bytes(m.cached))  free \(bytes(m.free))  swap \(bytes(m.swapUsed)) / \(bytes(m.swapTotal))  pressure \(m.pressure.rawValue)")

    let g = hub.gpu
    line("== GPU")
    line("  utilization \(pct(g.utilization))  renderer \(pct(g.rendererUtilization))  tiler \(pct(g.tilerUtilization))  history \(g.history.count)")

    let n = hub.network
    line("== Network")
    line("  \(n.interfaceName ?? "offline") (\(n.interfaceType?.rawValue ?? "-"))  IPv4 \(n.localIPv4 ?? "n/a")  connected \(n.isConnected)")
    line("  in \(rate(n.bytesInPerSecond))  out \(rate(n.bytesOutPerSecond))  totals in \(bytes(n.totalIn)) out \(bytes(n.totalOut))  history \(n.historyIn.count)")

    let d = hub.disk
    line("== Disk")
    line("  read \(rate(d.readBytesPerSecond))  write \(rate(d.writeBytesPerSecond))  history \(d.historyRead.count)")
    line("  \(d.volumeName ?? "boot volume"): free \(bytes(d.freeBytes)) / \(bytes(d.totalBytes))")

    let b = hub.battery
    line("== Battery")
    if b.hasBattery {
      line("  \(opt(b.percent))%  charging \(b.isCharging)  plugged \(b.isPluggedIn)  charged \(b.isCharged)  remaining \(b.timeRemaining.map { "\($0) min" } ?? "n/a")")
      line("  cycles \(opt(b.cycleCount))  health \(b.healthPercent.map { "\($0)%" } ?? "n/a")  temp \(temp(b.temperature))  adapter \(b.adapterWatts.map { "\($0) W" } ?? "n/a")")
    } else {
      line("  no battery  plugged \(b.isPluggedIn)")
    }

    let s = hub.sensors
    line("== Sensors (SMC: \(s.cpuSensorCount) CPU keys, \(s.gpuSensorCount) GPU keys)")
    line("  CPU avg \(temp(s.cpuTemperature))  max \(temp(s.cpuTemperatureMax))  GPU \(temp(s.gpuTemperature))")
    line("  fans \(s.fanRPMs.isEmpty ? "none" : s.fanRPMs.map { "\($0) rpm" }.joined(separator: ", "))  system power \(s.systemPowerWatts.map { String(format: "%.2f W", $0) } ?? "n/a")")

    line("== Bluetooth")
    if hub.bluetooth.devices.isEmpty { line("  no connected peripherals reporting battery") }
    for dev in hub.bluetooth.devices { line("  \(dev.name): \(dev.batteryPercent)%") }

    let y = hub.system
    line("== System")
    let up = Int(y.uptime)
    line("  \(y.modelIdentifier)  \(y.osVersion)  uptime \(up / 86400)d \(up % 86400 / 3600)h \(up % 3600 / 60)m  thermal \(thermalName(y.thermalState))")
    for p in y.topProcesses { line(String(format: "  %6.1f%%  %-28@ pid %d", p.cpu * 100, p.name as NSString, p.pid)) }
    if y.topProcesses.isEmpty { line("  (no process sample yet)") }
    return out.joined(separator: "\n")
  }

  private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private static func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
  }
}
