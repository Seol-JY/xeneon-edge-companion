import Foundation
import Observation

// Observable models consumed by widgets. All properties are assigned on the main thread, and only
// when the value changed. "Unavailable" is always `nil`, never 0.

// MARK: CPU

struct CPUCluster: Equatable, Identifiable {
  enum Kind: String { case efficiency, performance, superCore = "super", unknown }
  var id: String { name }
  /// "Efficiency", "Performance", ... (from hw.perflevelN.name when available).
  var name: String
  var kind: Kind
  /// Indices into `CPUModel.perCore`.
  var cores: [Int]
  /// Average usage of the cluster's cores, 0...1.
  var usage: Double
}

struct LoadAverage: Equatable {
  var one: Double, five: Double, fifteen: Double
}

@MainActor @Observable final class CPUModel {
  /// Total usage across all cores, 0...1.
  var usage: Double = 0
  /// User and system share of `usage`, 0...1.
  var userUsage: Double = 0
  var systemUsage: Double = 0
  /// Per logical core usage, 0...1, in cpuN order.
  var perCore: [Double] = []
  /// Per cluster averages (efficiency / performance ...).
  var clusters: [CPUCluster] = []
  /// Last 120 `usage` samples (1 s apart), oldest first.
  var history: [Double] = []
  var loadAverage = LoadAverage(one: 0, five: 0, fifteen: 0)
  /// e.g. "Apple M5". Static.
  var chipName: String = Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon"

  var efficiencyUsage: Double? { clusters.first { $0.kind == .efficiency }?.usage }
  var performanceUsage: Double? { clusters.first { $0.kind == .performance }?.usage }
}

// MARK: Memory

enum MemoryPressure: String, Equatable { case normal, warning, critical }

@MainActor @Observable final class MemoryModel {
  /// Bytes. `used = app + wired + compressed` (Activity Monitor definition).
  var total: UInt64 = 0
  var used: UInt64 = 0
  var app: UInt64 = 0
  var wired: UInt64 = 0
  var compressed: UInt64 = 0
  /// File-backed cache (reclaimable), bytes.
  var cached: UInt64 = 0
  var free: UInt64 = 0
  var swapUsed: UInt64 = 0
  var swapTotal: UInt64 = 0
  var pressure: MemoryPressure = .normal
  /// `used / total`, 0...1.
  var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
  /// Last 120 used fractions (2 s apart).
  var history: [Double] = []
}

// MARK: GPU

@MainActor @Observable final class GPUModel {
  /// IOAccelerator "Device Utilization %", 0...1. nil when the driver does not report it.
  var utilization: Double?
  var rendererUtilization: Double?
  var tilerUtilization: Double?
  /// Last 120 utilization samples (2 s apart).
  var history: [Double] = []
}

// MARK: Network

@MainActor @Observable final class NetworkModel {
  enum InterfaceType: String { case wifi, wired, cellular, loopback, other }
  /// BSD name of the primary interface ("en0"), nil when offline.
  var interfaceName: String?
  var interfaceType: InterfaceType?
  var isConnected: Bool = false
  var localIPv4: String?
  /// Bytes per second.
  var bytesInPerSecond: Double = 0
  var bytesOutPerSecond: Double = 0
  /// 64-bit interface counters since boot (bytes) for the primary interface.
  var totalIn: UInt64 = 0
  var totalOut: UInt64 = 0
  /// Last 120 rates (bytes/s, 1 s apart).
  var historyIn: [Double] = []
  var historyOut: [Double] = []
}

// MARK: Disk

@MainActor @Observable final class DiskModel {
  /// Boot disk throughput, bytes per second.
  var readBytesPerSecond: Double = 0
  var writeBytesPerSecond: Double = 0
  /// Last 120 rates (bytes/s, 2 s apart).
  var historyRead: [Double] = []
  var historyWrite: [Double] = []
  /// Boot volume name and capacity in bytes ("free" = available for important usage, i.e. what
  /// Finder shows, including purgeable space).
  var volumeName: String?
  var freeBytes: UInt64?
  var totalBytes: UInt64?
}

// MARK: Battery

@MainActor @Observable final class BatteryModel {
  var hasBattery: Bool = false
  /// 0...100.
  var percent: Int?
  var isCharging: Bool = false
  var isPluggedIn: Bool = false
  var isCharged: Bool = false
  /// Minutes to empty (on battery) or to full (charging). nil while macOS is still estimating.
  var timeRemaining: Int?
  var cycleCount: Int?
  /// Full charge capacity / design capacity, percent.
  var healthPercent: Int?
  /// Battery temperature, °C.
  var temperature: Double?
  /// Connected power adapter rating, watts.
  var adapterWatts: Int?
}

// MARK: Sensors

@MainActor @Observable final class SensorsModel {
  /// SoC CPU die sensors (SMC Tp*/Te*/Ts*), °C.
  var cpuTemperature: Double?
  var cpuTemperatureMax: Double?
  /// GPU sensors (SMC Tg*), °C.
  var gpuTemperature: Double?
  /// Current fan speeds, RPM. Empty on fanless Macs.
  var fanRPMs: [Int] = []
  /// SMC PSTR (system total power), watts.
  var systemPowerWatts: Double?
  /// Last samples (one per sensor read, ~5 s) of the CPU average temperature and system power.
  var cpuTemperatureHistory: [Double] = []
  var powerHistory: [Double] = []
  /// Number of temperature keys discovered (diagnostics).
  var cpuSensorCount: Int = 0
  var gpuSensorCount: Int = 0
}

// MARK: Bluetooth

struct BluetoothPeripheral: Equatable, Identifiable {
  var id: String
  var name: String
  /// 0...100. For earbuds, the lower of the two buds.
  var batteryPercent: Int
  /// Per-part levels for earbuds, e.g. "L 100 · R 100 · Case 89".
  var detail: String? = nil
}

@MainActor @Observable final class BluetoothModel {
  /// Connected Bluetooth HID peripherals that report a battery level, sorted by name.
  var devices: [BluetoothPeripheral] = []
}

// MARK: System

struct ProcessUsage: Equatable, Identifiable {
  var id: Int32 { pid }
  var pid: Int32
  var name: String
  /// CPU time share over the last interval; 1.0 == one fully busy core.
  var cpu: Double
}

@MainActor @Observable final class SystemModel {
  /// Seconds since boot (refreshed every 5 s; derive finer values from `bootDate`).
  var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  var bootDate: Date = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
  var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
  /// e.g. "macOS 26.3.1 (25D...)".
  var osVersion: String = SystemModel.makeOSVersion()
  /// e.g. "Mac17,4".
  var modelIdentifier: String = Sysctl.string("hw.model") ?? "Mac"
  /// Top 5 processes by CPU (only processes of the current user are visible), refreshed every 5 s.
  var topProcesses: [ProcessUsage] = []

  nonisolated static func makeOSVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    var s = "macOS \(v.majorVersion).\(v.minorVersion)"
    if v.patchVersion > 0 { s += ".\(v.patchVersion)" }
    if let build = Sysctl.string("kern.osversion") { s += " (\(build))" }
    return s
  }
}
