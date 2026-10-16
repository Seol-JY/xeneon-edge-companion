import AppKit
import CoreGraphics
import EdgeCore

/// Watches for the Edge appearing, disappearing, sleeping and changing geometry, and reports a
/// debounced, settled state. All callbacks are delivered on the main thread.
final class DisplayMonitor {
  enum State: Equatable {
    case disconnected
    /// Connected and awake. `generation` increments every time the display (re)settles,
    /// so listeners can tell a fresh connection or wake from a no-op.
    case connected(EdgeDisplay, generation: Int)
    /// Connected but the panel, the system or the session is asleep/locked.
    case suspended(EdgeDisplay?)

    var display: EdgeDisplay? {
      switch self {
      case let .connected(d, _): return d
      case let .suspended(d): return d
      case .disconnected: return nil
      }
    }

    var isActive: Bool {
      if case .connected = self { return true }
      return false
    }
  }

  private(set) var state: State = .disconnected {
    didSet {
      guard state != oldValue else { return }
      Log.info(.display, "state → \(describe(state))")
      listeners.forEach { $0(state) }
    }
  }

  private var listeners: [(State) -> Void] = []
  private var pendingWork: DispatchWorkItem?
  private var generation = 0
  private var systemAsleep = false
  private var screensAsleep = false
  private var sessionLocked = false
  private var lastUUID: String?
  private var observers: [NSObjectProtocol] = []
  private var distributedObservers: [NSObjectProtocol] = []
  private var pollTimer: Timer?

  func addListener(_ listener: @escaping (State) -> Void) {
    listeners.append(listener)
    listener(state)
  }

  func start() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)

    let ws = NSWorkspace.shared.notificationCenter
    observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      self?.systemAsleep = true
      self?.reevaluate(after: 0)
    })
    observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.systemAsleep = false
      self?.reevaluate(after: 3.0)
    })
    observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
      self?.screensAsleep = true
      self?.reevaluate(after: 0)
    })
    observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.screensAsleep = false
      self?.reevaluate(after: 2.0)
    })
    observers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.sessionLocked = true
      self?.reevaluate(after: 0)
    })
    observers.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.sessionLocked = false
      self?.reevaluate(after: 1.5)
    })
    let dnc = DistributedNotificationCenter.default()
    distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.sessionLocked = true
      self?.reevaluate(after: 0)
    })
    distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      self?.sessionLocked = false
      self?.reevaluate(after: 1.5)
    })
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      self?.reevaluate(after: 0.5)
    })

    reevaluate(after: 0)
  }

  func stop() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
    distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    observers.removeAll()
    distributedObservers.removeAll()
    pendingWork?.cancel()
    pollTimer?.invalidate()
  }

  /// Forces a fresh look, e.g. after we changed the display mode ourselves.
  func refresh() { reevaluate(after: 0.3) }

  fileprivate func handleReconfiguration(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) {
    // Never touch display state inside the WindowServer transaction; just schedule a settled look.
    if flags.contains(.beginConfigurationFlag) { return }
    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .setModeFlag, .movedFlag, .desktopShapeChangedFlag, .mirrorFlag, .unMirrorFlag]
    guard !flags.intersection(relevant).isEmpty else { return }
    DispatchQueue.main.async { self.reevaluate(after: 1.0) }
  }

  /// Generation-counter debounce (MonitorControl's approach): only the last request in a burst runs.
  private func reevaluate(after delay: TimeInterval) {
    pendingWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.evaluate() }
    pendingWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func evaluate() {
    let found = EdgeLocator.find(preferredUUID: lastUUID)
    if let found { lastUUID = found.uuid }
    updatePolling(connected: found != nil)

    guard let display = found else {
      state = .disconnected
      return
    }
    if systemAsleep || screensAsleep || sessionLocked || display.isAsleep {
      state = .suspended(display)
      return
    }
    if case let .connected(current, gen) = state, current == display {
      state = .connected(display, generation: gen)
      return
    }
    generation += 1
    state = .connected(display, generation: generation)
  }

  /// If the Edge is asleep when we start, no reconfiguration callback may arrive when it wakes,
  /// so poll slowly while it is missing.
  private func updatePolling(connected: Bool) {
    if connected {
      pollTimer?.invalidate()
      pollTimer = nil
    } else if pollTimer == nil {
      let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.reevaluate(after: 0) }
      t.tolerance = 2
      RunLoop.main.add(t, forMode: .common)
      pollTimer = t
    }
  }

  private func describe(_ s: State) -> String {
    switch s {
    case .disconnected: return "disconnected"
    case let .connected(d, g): return "connected #\(g) \(d.summary) serial \(d.serial == nil ? "unknown" : "known")"
    case let .suspended(d): return "suspended (\(d?.summary ?? "no display"))"
    }
  }
}

private func displayReconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
  guard let userInfo else { return }
  let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  monitor.handleReconfiguration(display, flags)
}
