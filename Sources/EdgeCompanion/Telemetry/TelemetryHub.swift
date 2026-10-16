import Foundation
import Observation

/// The metric families a widget can subscribe to.
enum MetricKind: Hashable, CaseIterable {
  case cpu, memory, gpu, network, disk, battery, sensors, bluetooth, system
}

/// Entry point of the telemetry module.
///
/// Widgets call `retain(_:)` when they appear and `release(_:)` when they disappear. A reader only
/// runs while its retain count is above zero and the hub is not suspended. All sampling happens on
/// one serial `.utility` queue driven by a single 1 s `DispatchSourceTimer`; models are assigned on
/// the main thread only when a value actually changed.
@MainActor final class TelemetryHub {
  static let shared = TelemetryHub()

  let cpu = CPUModel()
  let memory = MemoryModel()
  let gpu = GPUModel()
  let network = NetworkModel()
  let disk = DiskModel()
  let battery = BatteryModel()
  let sensors = SensorsModel()
  let bluetooth = BluetoothModel()
  let system = SystemModel()

  /// True pauses all sampling (Edge disconnected, display asleep, screen locked).
  /// Resuming discards stale deltas, so the first sample after a resume is only a baseline.
  var isSuspended: Bool = false {
    didSet {
      guard isSuspended != oldValue else { return }
      apply()
      NotificationCenter.default.post(name: .edgeDashboardSuspensionChanged, object: nil)
    }
  }

  private var counts: [MetricKind: Int] = [:]
  private let engine: TelemetryEngine
  /// Readers that also listen to main-run-loop events (IOPS notifications, thermal state).
  private let eventReaders: [MetricKind: MainThreadEventSource]
  private var eventsRunning: Set<MetricKind> = []

  private init() {
    let battery = BatteryReader(model: battery)
    let system = SystemReader(model: system)
    let readers: [MetricKind: TelemetryReader] = [
      .cpu: CPUReader(model: cpu),
      .memory: MemoryReader(model: memory),
      .gpu: GPUReader(model: gpu),
      .network: NetworkReader(model: network),
      .disk: DiskReader(model: disk),
      .battery: battery,
      .sensors: SensorsReader(model: sensors),
      .bluetooth: BluetoothReader(model: bluetooth),
      .system: system,
    ]
    engine = TelemetryEngine(readers: readers)
    eventReaders = [.battery: battery, .system: system]
  }

  func retain(_ kind: MetricKind) {
    counts[kind, default: 0] += 1
    if counts[kind] == 1 { apply() }
  }

  func release(_ kind: MetricKind) {
    guard let n = counts[kind], n > 0 else { return }
    counts[kind] = n - 1
    if n == 1 { apply() }
  }

  /// Kinds whose readers currently run.
  var activeKinds: Set<MetricKind> {
    isSuspended ? [] : Set(counts.filter { $0.value > 0 }.keys)
  }

  private func apply() {
    let active = activeKinds
    for (kind, source) in eventReaders {
      let want = active.contains(kind)
      if want, !eventsRunning.contains(kind) {
        source.startEvents(); eventsRunning.insert(kind)
      } else if !want, eventsRunning.contains(kind) {
        source.stopEvents(); eventsRunning.remove(kind)
      }
    }
    engine.update(active: active, suspended: isSuspended)
  }
}

// MARK: - Engine

/// A sampler for one metric family. Every method is called on the engine queue only.
protocol TelemetryReader: AnyObject {
  /// Called once per 1 s tick while active. `tick` counts from 0 at activation (or resume), so a
  /// reader with a 2 s interval samples when `tick % 2 == 0`. `now` is monotonic nanoseconds;
  /// readers divide deltas by the real elapsed time, never by the nominal interval.
  func sample(tick: Int, now: UInt64)
  /// Drop every previous counter value (called on activation and after a resume).
  func reset()
  /// The reader stopped running; release anything that is only useful while running.
  func deactivate()
}

/// Readers that also need main-run-loop event registrations while active. Called on main.
@MainActor protocol MainThreadEventSource: AnyObject {
  func startEvents()
  func stopEvents()
}

/// Owns the serial queue and the single timer. State is confined to `queue`.
final class TelemetryEngine: @unchecked Sendable {
  static let queue = DispatchQueue(label: "EdgeCompanion.telemetry", qos: .utility)

  private let readers: [MetricKind: TelemetryReader]
  private var queue: DispatchQueue { Self.queue }
  private var timer: DispatchSourceTimer?
  private var active: Set<MetricKind> = []
  private var startTick: [MetricKind: Int] = [:]
  private var tick = 0

  init(readers: [MetricKind: TelemetryReader]) {
    self.readers = readers
  }

  func update(active newActive: Set<MetricKind>, suspended: Bool) {
    queue.async { self.apply(newActive, suspended: suspended) }
  }

  /// Run a closure on the engine queue (used for event-triggered refreshes).
  static func perform(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

  private func apply(_ newActive: Set<MetricKind>, suspended: Bool) {
    let added = newActive.subtracting(active)
    let removed = active.subtracting(newActive)
    for kind in removed {
      readers[kind]?.deactivate()
      startTick[kind] = nil
    }
    // Every newly active reader (including all readers after a resume) starts from a clean baseline.
    for kind in added {
      readers[kind]?.reset()
      startTick[kind] = tick
    }
    active = newActive

    if active.isEmpty || suspended {
      timer?.cancel()
      timer = nil
      return
    }
    if timer == nil {
      let t = DispatchSource.makeTimerSource(flags: [], queue: queue)
      t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(300))
      t.setEventHandler { [unowned self] in self.fire() }
      timer = t
      t.resume()
    } else if !added.isEmpty {
      // Give new readers their first (baseline) sample right away instead of waiting for the tick.
      let now = DispatchTime.now().uptimeNanoseconds
      for kind in added { readers[kind]?.sample(tick: 0, now: now) }
      for kind in added { startTick[kind] = tick - 1 }
    }
  }

  private func fire() {
    let now = DispatchTime.now().uptimeNanoseconds
    for kind in active {
      guard let reader = readers[kind], let start = startTick[kind] else { continue }
      reader.sample(tick: tick - start, now: now)
    }
    tick += 1
  }
}

// MARK: - Helpers shared by readers

/// Hop to the main thread to assign model values.
@inline(__always)
func publishOnMain(_ body: @escaping @MainActor () -> Void) {
  DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

extension Observable where Self: AnyObject {
  /// Assign only when the value differs, so observers are not invalidated by identical values.
  @inline(__always)
  func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, T>, _ value: T) {
    if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
  }
}

/// Fixed-capacity history kept off the main thread and published as a plain array.
struct HistoryBuffer {
  let capacity: Int
  private(set) var values: [Double] = []

  init(capacity: Int = 120) {
    self.capacity = capacity
    values.reserveCapacity(capacity + 1)
  }

  mutating func append(_ v: Double) {
    values.append(v)
    if values.count > capacity { values.removeFirst(values.count - capacity) }
  }
}

/// Seconds between two monotonic nanosecond timestamps.
@inline(__always)
func seconds(from start: UInt64, to end: UInt64) -> Double {
  end > start ? Double(end - start) / 1_000_000_000 : 0
}

enum Sysctl {
  static func int64(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    // Works for 4-byte values too because the buffer is zeroed and little-endian.
    return value
  }

  static func int32(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }

  static func string(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
  }
}
