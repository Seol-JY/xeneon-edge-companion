import Darwin
import Foundation

// Uptime, thermal state (event-driven) and top processes by CPU from proc_pid_rusage deltas.
// No `ps`/`top`: processes owned by other users return EPERM and are skipped.

final class SystemReader: TelemetryReader {
  private let model: SystemModel
  private var thermalObserver: NSObjectProtocol?
  private var previous: [Int32: UInt64] = [:]  // pid -> cpu time (ns)
  private var previousTime: UInt64 = 0
  private var names: [Int32: String] = [:]
  private var pids = [Int32](repeating: 0, count: 2048)
  private let timebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
  }()

  init(model: SystemModel) { self.model = model }

  func reset() { previous = [:]; previousTime = 0 }
  func deactivate() { previous = [:]; previousTime = 0; names = [:] }

  @MainActor func startEvents() {
    guard thermalObserver == nil else { return }
    let model = self.model
    model.update(\.thermalState, ProcessInfo.processInfo.thermalState)
    thermalObserver = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { model.update(\.thermalState, ProcessInfo.processInfo.thermalState) }
    }
  }

  @MainActor func stopEvents() {
    if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
    thermalObserver = nil
  }

  func sample(tick: Int, now: UInt64) {
    // Baseline at activation, a first result 2 s later, then every 5 s.
    guard tick % 5 == 0 || tick == 2 else { return }
    let uptime = ProcessInfo.processInfo.systemUptime.rounded()
    let top = sampleProcesses(now: now)
    let model = self.model
    publishOnMain {
      model.update(\.uptime, uptime)
      if let top { model.update(\.topProcesses, top) }
    }
  }

  private func sampleProcesses(now: UInt64) -> [ProcessUsage]? {
    var count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
    if count >= pids.count {  // grow and retry once
      pids = [Int32](repeating: 0, count: count * 2)
      count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
    }
    guard count > 0 else { return nil }

    var current: [Int32: UInt64] = [:]
    current.reserveCapacity(count)
    var info = rusage_info_v4()
    for i in 0..<min(count, pids.count) {
      let pid = pids[i]
      guard pid > 0 else { continue }
      let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
      }
      guard rc == 0 else { continue }  // EPERM (other users) or the process exited
      // ri_*_time is in mach absolute time units on Apple silicon.
      current[pid] = (info.ri_user_time &+ info.ri_system_time) &* timebase.numer / timebase.denom
    }

    defer { previous = current; previousTime = now }
    guard previousTime != 0, now > previousTime else { return nil }
    let dt = Double(now - previousTime)
    var usage: [(Int32, Double)] = []
    for (pid, t) in current {
      guard let p = previous[pid], t > p else { continue }
      usage.append((pid, Double(t - p) / dt))
    }
    usage.sort { $0.1 > $1.1 }
    let top = usage.prefix(5).map { pid, cpu in
      ProcessUsage(pid: pid, name: name(of: pid), cpu: (cpu * 1000).rounded() / 1000)
    }
    names = names.filter { current[$0.key] != nil }
    return top
  }

  private func name(of pid: Int32) -> String {
    if let n = names[pid] { return n }
    var buf = [CChar](repeating: 0, count: 256)
    var n = proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    if n.isEmpty {
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
        n = (String(cString: path) as NSString).lastPathComponent
      }
    }
    if n.isEmpty { n = "pid \(pid)" }
    names[pid] = n
    return n
  }
}

extension SystemReader: MainThreadEventSource {}
