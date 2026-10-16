import Darwin
import Foundation
import IOKit
import IOKit.storage
import Network

// MARK: - Network
// 64-bit interface counters via sysctl NET_RT_IFLIST2 (if_msghdr2), filtered to the primary
// interface reported by NWPathMonitor. Parsing adapted from exelban/stats Modules/Net/readers.swift (MIT).

final class NetworkReader: TelemetryReader {
  private let model: NetworkModel
  private var monitor: NWPathMonitor?
  private var interfaceName: String?
  private var interfaceIndex: UInt32 = 0
  private var previous: (inBytes: UInt64, outBytes: UInt64, time: UInt64)?
  private var historyIn = HistoryBuffer()
  private var historyOut = HistoryBuffer()
  private var buffer = [UInt8](repeating: 0, count: 512)

  init(model: NetworkModel) { self.model = model }

  func reset() { previous = nil }

  func deactivate() {
    previous = nil
    monitor?.cancel()
    monitor = nil
  }

  private func startMonitor() {
    let m = NWPathMonitor()
    m.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
    m.start(queue: TelemetryEngine.queue)  // callbacks arrive on the engine queue
    monitor = m
  }

  private func pathChanged(_ path: NWPath) {
    let iface = path.status == .satisfied
      ? path.availableInterfaces.first { $0.type != .loopback && $0.type != .other } ?? path.availableInterfaces.first
      : nil
    let name = iface?.name
    if name != interfaceName {
      interfaceName = name
      interfaceIndex = name.map { if_nametoindex($0) } ?? 0
      previous = nil
    }
    let type: NetworkModel.InterfaceType? = iface.map {
      switch $0.type {
      case .wifi: return .wifi
      case .wiredEthernet: return .wired
      case .cellular: return .cellular
      case .loopback: return .loopback
      default: return .other
      }
    }
    let ip = name.flatMap(Self.ipv4(of:))
    let connected = path.status == .satisfied
    let model = self.model
    publishOnMain {
      model.update(\.interfaceName, name)
      model.update(\.interfaceType, type)
      model.update(\.isConnected, connected)
      model.update(\.localIPv4, ip)
      if name == nil {
        model.update(\.bytesInPerSecond, 0)
        model.update(\.bytesOutPerSecond, 0)
      }
    }
  }

  func sample(tick: Int, now: UInt64) {
    if monitor == nil { startMonitor() }
    guard interfaceIndex != 0, let counters = readCounters(index: interfaceIndex) else { return }
    defer { previous = (counters.0, counters.1, now) }
    guard let prev = previous else { return }
    let dt = seconds(from: prev.time, to: now)
    guard dt > 0.2 else { return }
    // Counters can reset when an interface goes down; treat a decrease as a new baseline.
    let rateIn = counters.0 >= prev.inBytes ? Double(counters.0 - prev.inBytes) / dt : 0
    let rateOut = counters.1 >= prev.outBytes ? Double(counters.1 - prev.outBytes) / dt : 0
    historyIn.append(rateIn)
    historyOut.append(rateOut)
    let hIn = historyIn.values, hOut = historyOut.values
    let model = self.model
    let refreshIP = tick % 30 == 0, name = interfaceName
    let ip = refreshIP ? name.flatMap(Self.ipv4(of:)) : nil
    publishOnMain {
      model.update(\.bytesInPerSecond, rateIn)
      model.update(\.bytesOutPerSecond, rateOut)
      model.update(\.totalIn, counters.0)
      model.update(\.totalOut, counters.1)
      model.historyIn = hIn
      model.historyOut = hOut
      if refreshIP { model.update(\.localIPv4, ip) }
    }
  }

  /// (ibytes, obytes) for one interface index.
  private func readCounters(index: UInt32) -> (UInt64, UInt64)? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    if buffer.count < size { buffer = [UInt8](repeating: 0, count: size * 2) }
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBytes { raw -> (UInt64, UInt64)? in
      var offset = 0
      while offset + MemoryLayout<if_msghdr>.size <= size {
        let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
        guard header.ifm_msglen > 0 else { return nil }
        if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
          let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
          if UInt32(h2.ifm_index) == index { return (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes) }
        }
        offset += Int(header.ifm_msglen)
      }
      return nil
    }
  }

  static func ipv4(of name: String) -> String? {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    defer { freeifaddrs(ifap) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let ifa = ptr.pointee
      guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
            String(cString: ifa.ifa_name) == name else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        return String(cString: host)
      }
    }
    return nil
  }
}

// MARK: - Disk
// Boot disk throughput from IOBlockStorageDriver "Statistics" (same source as exelban/stats
// Modules/Disk/readers.swift, MIT) and boot volume capacity from URL resource values.

final class DiskReader: TelemetryReader {
  private let model: DiskModel
  /// Retained IOBlockStorageDriver objects backing the boot volume (usually exactly one).
  private var drivers: [io_registry_entry_t] = []
  private var resolved = false
  private var previous: (read: UInt64, write: UInt64, time: UInt64)?
  private var historyRead = HistoryBuffer()
  private var historyWrite = HistoryBuffer()

  init(model: DiskModel) { self.model = model }

  func reset() { previous = nil }
  func deactivate() { previous = nil }

  func sample(tick: Int, now: UInt64) {
    if tick % 60 == 0 { sampleCapacity() }
    guard tick % 2 == 0 else { return }
    if !resolved { resolveDrivers(); resolved = true }
    guard !drivers.isEmpty else { return }

    var read: UInt64 = 0, write: UInt64 = 0
    for d in drivers {
      guard let stats = IORegistryEntryCreateCFProperty(d, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any] else { continue }
      read &+= (stats[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value ?? 0
      write &+= (stats[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value ?? 0
    }
    defer { previous = (read, write, now) }
    guard let prev = previous else { return }
    let dt = seconds(from: prev.time, to: now)
    guard dt > 0.2 else { return }
    let r = read >= prev.read ? Double(read - prev.read) / dt : 0
    let w = write >= prev.write ? Double(write - prev.write) / dt : 0
    historyRead.append(r)
    historyWrite.append(w)
    let hr = historyRead.values, hw = historyWrite.values
    let model = self.model
    publishOnMain {
      model.update(\.readBytesPerSecond, r)
      model.update(\.writeBytesPerSecond, w)
      model.historyRead = hr
      model.historyWrite = hw
    }
  }

  private func sampleCapacity() {
    let url = URL(fileURLWithPath: "/")
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey,
    ])
    let free = values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    let total = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
    let name = values?.volumeLocalizedName
    let model = self.model
    publishOnMain {
      model.update(\.freeBytes, free)
      model.update(\.totalBytes, total)
      model.update(\.volumeName, name)
    }
  }

  /// Walk from the boot volume's IOMedia (statfs "/" → /dev/diskXsYsZ) up the service plane to the
  /// IOBlockStorageDriver of the physical disk. APFS containers sit on a physical store partition,
  /// so the first driver found going up is the internal SSD. Falls back to all drivers.
  private func resolveDrivers() {
    var fs = statfs()
    if statfs("/", &fs) == 0 {
      let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      let bsd = from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : from
      if let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, match)
        if media != 0, let driver = Self.driverAbove(media) {
          drivers = [driver]
        }
        if media != 0 { IOObjectRelease(media) }
      }
    }
    if drivers.isEmpty {
      var iter: io_iterator_t = 0
      if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass), &iter) == KERN_SUCCESS {
        while case let e = IOIteratorNext(iter), e != 0 { drivers.append(e) }
        IOObjectRelease(iter)
      }
    }
  }

  /// Breadth-first walk over parents (an APFS container may have several, take the first driver).
  private static func driverAbove(_ start: io_registry_entry_t) -> io_registry_entry_t? {
    var queue: [io_registry_entry_t] = [start]
    IOObjectRetain(start)
    defer { queue.forEach { IOObjectRelease($0) } }
    var i = 0
    while i < queue.count, i < 64 {
      let entry = queue[i]; i += 1
      if IOObjectConformsTo(entry, kIOBlockStorageDriverClass) != 0 {
        IOObjectRetain(entry)
        return entry
      }
      var iter: io_iterator_t = 0
      guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iter) == KERN_SUCCESS else { continue }
      while case let p = IOIteratorNext(iter), p != 0 { queue.append(p) }
      IOObjectRelease(iter)
    }
    return nil
  }
}
