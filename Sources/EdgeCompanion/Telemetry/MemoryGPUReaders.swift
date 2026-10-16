import Darwin
import Foundation
import IOKit

// MARK: - Memory
// host_statistics64 + vm.swapusage + kern.memorystatus_vm_pressure_level.
// Field selection follows exelban/stats Modules/RAM/readers.swift (MIT), with the Activity Monitor
// definition of "used" (app + wired + compressed).

final class MemoryReader: TelemetryReader {
  private let model: MemoryModel
  private let total: UInt64 = ProcessInfo.processInfo.physicalMemory
  private let pageSize = UInt64(vm_kernel_page_size)
  private var history = HistoryBuffer()

  init(model: MemoryModel) { self.model = model }

  func reset() {}
  func deactivate() {}

  func sample(tick: Int, now: UInt64) {
    guard tick % 2 == 0 else { return }
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return }

    let ps = pageSize
    let internalPages = UInt64(stats.internal_page_count)
    let purgeable = UInt64(stats.purgeable_count)
    let app = (internalPages > purgeable ? internalPages - purgeable : 0) * ps
    let wired = UInt64(stats.wire_count) * ps
    let compressed = UInt64(stats.compressor_page_count) * ps
    let cached = (UInt64(stats.external_page_count) + purgeable) * ps
    let free = UInt64(stats.free_count) * ps
    let used = min(total, app + wired + compressed)

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

    let pressure: MemoryPressure
    switch Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1 {
    case 4: pressure = .critical
    case 2: pressure = .warning
    default: pressure = .normal
    }

    history.append(total > 0 ? Double(used) / Double(total) : 0)
    let hist = history.values
    let total = self.total
    let model = self.model
    publishOnMain {
      model.update(\.total, total)
      model.update(\.used, used)
      model.update(\.app, app)
      model.update(\.wired, wired)
      model.update(\.compressed, compressed)
      model.update(\.cached, cached)
      model.update(\.free, free)
      if hasSwap {
        model.update(\.swapUsed, swap.xsu_used)
        model.update(\.swapTotal, swap.xsu_total)
      }
      model.update(\.pressure, pressure)
      model.history = hist
    }
  }
}

// MARK: - GPU
// IOAccelerator PerformanceStatistics, as in exelban/stats Modules/GPU/reader.swift (MIT).

final class GPUReader: TelemetryReader {
  private let model: GPUModel
  /// Long-lived accelerator service handle (retained), resolved lazily.
  private var accelerator: io_service_t = 0
  private var history = HistoryBuffer()

  init(model: GPUModel) { self.model = model }

  func reset() {}
  func deactivate() {}

  private func resolve() -> io_service_t {
    if accelerator != 0 { return accelerator }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
    else { return 0 }
    defer { IOObjectRelease(iter) }
    while case let entry = IOIteratorNext(iter), entry != 0 {
      if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any], stats["Device Utilization %"] != nil {
        accelerator = entry
        return entry
      }
      IOObjectRelease(entry)
    }
    return 0
  }

  func sample(tick: Int, now: UInt64) {
    guard tick % 2 == 0 else { return }
    let service = resolve()
    guard service != 0 else { return }
    guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? [String: Any] else {
      // The service went away (should not happen on Apple silicon); resolve again next time.
      IOObjectRelease(accelerator)
      accelerator = 0
      return
    }
    func pct(_ key: String) -> Double? {
      (stats[key] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) }
    }
    let util = pct("Device Utilization %") ?? pct("GPU Activity(%)")
    let renderer = pct("Renderer Utilization %")
    let tiler = pct("Tiler Utilization %")
    if let util { history.append(util) }
    let hist = history.values
    let model = self.model
    publishOnMain {
      model.update(\.utilization, util)
      model.update(\.rendererUtilization, renderer)
      model.update(\.tilerUtilization, tiler)
      if util != nil { model.history = hist }
    }
  }
}
