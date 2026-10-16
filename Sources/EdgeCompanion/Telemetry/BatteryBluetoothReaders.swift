import Foundation
import IOKit
import IOKit.ps

// MARK: - Battery
// IOPS power source APIs (event-driven via IOPSNotificationCreateRunLoopSource, polled every 30 s as
// a safety net) plus AppleSmartBattery details every 60 s. Keys as used by exelban/stats
// Modules/Battery/readers.swift (MIT).

final class BatteryReader: TelemetryReader {
  private let model: BatteryModel
  private var runLoopSource: CFRunLoopSource?
  private var smartBattery: io_service_t = 0
  private var smartBatteryResolved = false

  init(model: BatteryModel) { self.model = model }

  func reset() {}
  func deactivate() {}

  func sample(tick: Int, now: UInt64) {
    if tick % 30 == 0 { readPowerSource() }
    if tick % 60 == 0 { readDetails() }
  }

  /// Main thread: register for power source change notifications while active.
  @MainActor func startEvents() {
    guard runLoopSource == nil else { return }
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
      guard let ctx else { return }
      let reader = Unmanaged<BatteryReader>.fromOpaque(ctx).takeUnretainedValue()
      TelemetryEngine.perform { reader.readPowerSource(); reader.readDetails() }
    }, context)?.takeRetainedValue() else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    runLoopSource = src
  }

  @MainActor func stopEvents() {
    guard let src = runLoopSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
    CFRunLoopSourceInvalidate(src)
    runLoopSource = nil
  }

  /// Percent, charging state and time remaining (cheap).
  fileprivate func readPowerSource() {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
    var desc: [String: Any]?
    for ps in list {
      guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
      if d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { desc = d; break }
    }
    let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
    let plugged = providing == kIOPSACPowerValue

    let model = self.model
    guard let d = desc else {
      publishOnMain {
        model.update(\.hasBattery, false)
        model.update(\.isPluggedIn, plugged)
      }
      return
    }
    let current = d[kIOPSCurrentCapacityKey] as? Int
    let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
    let percent = current.map { max > 0 ? Int((Double($0) / Double(max) * 100).rounded()) : $0 }
    let charging = d[kIOPSIsChargingKey] as? Bool ?? false
    let charged = d[kIOPSIsChargedKey] as? Bool ?? false
    let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue || plugged
    var remaining: Int?
    if charging, let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { remaining = t }
    if !onAC, let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { remaining = t }
    publishOnMain {
      model.update(\.hasBattery, true)
      model.update(\.percent, percent)
      model.update(\.isCharging, charging)
      model.update(\.isCharged, charged)
      model.update(\.isPluggedIn, onAC)
      model.update(\.timeRemaining, remaining)
    }
  }

  /// Cycle count, health, temperature (AppleSmartBattery) and adapter rating.
  fileprivate func readDetails() {
    if !smartBatteryResolved {
      smartBattery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
      smartBatteryResolved = true
    }
    var cycles: Int?, health: Int?, temperature: Double?
    if smartBattery != 0 {
      func int(_ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(smartBattery, key as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? NSNumber)?.intValue
      }
      cycles = int("CycleCount")
      if let design = int("DesignCapacity"), design > 0,
         let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") {
        health = min(100, Int((Double(full) / Double(design) * 100).rounded()))
      }
      // Hundredths of °C.
      if let t = int("Temperature"), t > 0 { temperature = (Double(t) / 10).rounded() / 10 }
    }
    var watts: Int?
    if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
       let w = adapter[kIOPSPowerAdapterWattsKey] as? Int, w > 0 {
      watts = w
    }
    let model = self.model
    publishOnMain {
      model.update(\.cycleCount, cycles)
      model.update(\.healthPercent, health)
      model.update(\.temperature, temperature)
      model.update(\.adapterWatts, watts)
    }
  }
}

extension BatteryReader: MainThreadEventSource {}

// MARK: - Bluetooth
// Battery levels of connected Bluetooth HID peripherals from IORegistry, as in exelban/stats
// Modules/Bluetooth/readers.swift `HIDDevices()` (MIT). No CoreBluetooth, no TCC prompt.

final class BluetoothReader: TelemetryReader {
  private let model: BluetoothModel

  init(model: BluetoothModel) { self.model = model }

  func reset() {}
  func deactivate() {}

  func sample(tick: Int, now: UInt64) {
    guard tick % 30 == 0 else { return }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iter)
      == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }
    var devices: [String: BluetoothPeripheral] = [:]
    while case let entry = IOIteratorNext(iter), entry != 0 {
      defer { IOObjectRelease(entry) }
      func prop(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      }
      guard (prop("BluetoothDevice") as? Bool) == true,
            let name = prop("Product") as? String,
            let level = (prop("BatteryPercent") as? NSNumber)?.intValue else { continue }
      let address = (prop("DeviceAddress") as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (prop("SerialNumber") as? String) ?? name
      let id = address.replacingOccurrences(of: ":", with: "-").lowercased()
      devices[id] = BluetoothPeripheral(id: id, name: name, batteryPercent: min(100, max(0, level)))
    }
    for device in Self.audioDevices() where devices[device.id] == nil {
      devices[device.id] = device
    }
    let list = devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    let model = self.model
    publishOnMain { model.update(\.devices, list) }
  }

  /// AirPods and other headphones report their battery only through bluetoothd, which
  /// `system_profiler` exposes (about 0.1 s, run at most every 30 s while the widget is visible).
  /// IOBluetooth's private battery keys miss the case level, so this public tool is used instead.
  private static func audioDevices() -> [BluetoothPeripheral] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPBluetoothDataType", "-json"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

    func level(_ value: Any?) -> Int? {
      guard let text = value as? String else { return nil }
      return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
    var result: [BluetoothPeripheral] = []
    for controller in controllers {
      for entry in (controller["device_connected"] as? [[String: Any]]) ?? [] {
        for (name, value) in entry {
          guard let info = value as? [String: Any] else { continue }
          let left = level(info["device_batteryLevelLeft"])
          let right = level(info["device_batteryLevelRight"])
          let caseLevel = level(info["device_batteryLevelCase"])
          let main = level(info["device_batteryLevelMain"])
          let buds = [left, right].compactMap { $0 }
          guard let percent = buds.min() ?? main else { continue }
          var parts: [String] = []
          if let left { parts.append("L \(left)") }
          if let right { parts.append("R \(right)") }
          if let caseLevel { parts.append(tr("케이스", "Case") + " \(caseLevel)") }
          let address = (info["device_address"] as? String) ?? name
          let id = address.replacingOccurrences(of: ":", with: "-").lowercased()
          result.append(BluetoothPeripheral(id: id, name: name, batteryPercent: percent, detail: parts.isEmpty ? nil : parts.joined(separator: " · ")))
        }
      }
    }
    return result
  }
}
