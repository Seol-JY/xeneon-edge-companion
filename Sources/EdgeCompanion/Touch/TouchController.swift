import AppKit
import Combine
import EdgeCore

/// Glues the HID device, the gesture engine and the two event sinks together.
///
/// Reports are parsed, mapped and recognised on the HID thread. Each gesture is routed once, at
/// touch-down: onto our own panel (AppKit events, cursor untouched) or to whatever app window is
/// under the finger (CGEvents with a borrowed cursor).
final class TouchController: ObservableObject {
  enum Availability: Equatable {
    case disabled
    case noDisplay
    case needsInputMonitoring
    case needsAccessibility
    case busy
    case waiting
    case active
    case failed(String)
  }

  @Published private(set) var availability: Availability = .disabled
  @Published private(set) var lastTouchPoint: CGPoint?
  @Published private(set) var reportRate: Double = 0

  /// Returns our panel if it should receive a touch at this global point. Called on the main thread.
  var panelProvider: ((CGPoint) -> NSWindow?)?
  /// Every mapped sample, for the touch test screen. Main thread; costs nothing while nil.
  var probe: ((TouchProbe) -> Void)? {
    didSet {
      stateLock.lock()
      probing = probe != nil
      stateLock.unlock()
    }
  }
  /// Every batch of recognised gestures, for the touch test screen. Main thread.
  var gestureProbe: (([GestureAction]) -> Void)?

  private let hid = TouchHIDDevice()
  private let systemSink = SystemEventInjector()
  private let panelSink = PanelEventSink()

  // HID-thread state
  private var engine = GestureEngine()
  private let stateLock = NSLock()
  private var mapper: CoordinateMapper?
  private var pendingConfig: GestureConfig?
  private var reportCount = 0
  private var rateWindowStart: TimeInterval = 0
  private var probing = false

  // Main-thread state
  private enum Target { case panel(NSWindow), system }
  private var currentTarget: Target?
  private var momentumTarget: Target?
  private var enabled = false
  private var hidStatus: TouchHIDDevice.Status = .stopped
  private var hasDisplay = false

  init() {
    hid.onReport = { [weak self] report, maxX, maxY, time in
      self?.hidReport(report, maxX: maxX, maxY: maxY, time: time)
    }
    hid.onTick = { [weak self] time in self?.hidTick(time) }
    hid.onDeviceLost = { [weak self] in self?.hidReset() }
    hid.onStatus = { [weak self] status in
      self?.hidStatus = status
      self?.updateAvailability()
    }
  }

  // MARK: - Configuration (main thread)

  func setEnabled(_ on: Bool) {
    guard on != enabled else { return }
    enabled = on
    if on {
      hid.start()
    } else {
      hidResetFromMain()
      hid.stop()
    }
    updateAvailability()
  }

  func apply(settings: AppSettings) {
    var cfg = GestureConfig()
    cfg.longPressRightClick = settings.longPressRightClick
    cfg.horizontalMoveDrags = settings.horizontalMoveDrags
    cfg.scrollMultiplier = settings.scrollSpeed
    cfg.momentumEnabled = settings.momentumScrolling
    systemSink.restoreCursor = settings.restoreCursorAfterTouch
    stateLock.lock()
    pendingConfig = cfg
    stateLock.unlock()
    setEnabled(settings.touchEnabled)
  }

  func edgeChanged(_ state: DisplayMonitor.State, calibration: TouchCalibration) {
    stateLock.lock()
    if let d = state.display {
      mapper = CoordinateMapper(displayBounds: d.bounds, rotation: d.rotation, calibration: calibration)
    } else {
      mapper = nil
    }
    stateLock.unlock()
    hasDisplay = state.display != nil

    switch state {
    case let .connected(_, generation) where enabled:
      // The touch USB device disappears while the panel has no picture; reopen after each settle.
      if generation > 1 || hidStatus != .running { hid.reacquire() }
    case .disconnected:
      hidResetFromMain()
    default:
      break
    }
    updateAvailability()
  }

  /// Called when permissions may have changed.
  func permissionsChanged() {
    if enabled, hidStatus == .notPermitted || hidStatus == .waitingForDevice { hid.reacquire() }
    updateAvailability()
  }

  private func updateAvailability() {
    let next: Availability
    if !enabled {
      next = .disabled
    } else {
      switch hidStatus {
      case .notPermitted: next = .needsInputMonitoring
      case .busy: next = .busy
      case let .failed(msg): next = .failed(msg)
      case .stopped, .waitingForDevice: next = .waiting
      case .running:
        if !hasDisplay { next = .noDisplay } else if !Permissions.canPostEvents { next = .needsAccessibility } else { next = .active }
      }
    }
    if next != availability { availability = next }
  }

  // MARK: - HID thread

  private func hidReport(_ report: TouchReport, maxX: Double, maxY: Double, time: TimeInterval) {
    stateLock.lock()
    if let cfg = pendingConfig {
      engine.config = cfg
      pendingConfig = nil
    }
    guard var m = mapper else {
      stateLock.unlock()
      return
    }
    let probing = self.probing
    stateLock.unlock()
    m.maxX = maxX
    m.maxY = maxY
    let point = m.map(x: report.x, y: report.y)

    countRate(time)
    if probing {
      let sample = TouchProbe(point: point, rawX: report.x, rawY: report.y, isDown: report.isDown)
      DispatchQueue.main.async { self.probe?(sample) }
    }

    let actions = engine.handle(down: report.isDown, point: point, time: time)
    hid.setTicking(engine.needsTick)
    dispatch(actions)
  }

  private func hidTick(_ time: TimeInterval) {
    let actions = engine.tick(now: time)
    if !engine.needsTick { hid.setTicking(false) }
    dispatch(actions)
  }

  private func hidReset() {
    let actions = engine.reset()
    hid.setTicking(false)
    dispatch(actions)
    systemSink.cancel()
  }

  private func hidResetFromMain() {
    hid.perform { [weak self] in self?.hidReset() }
  }

  private func countRate(_ time: TimeInterval) {
    reportCount += 1
    if time - rateWindowStart >= 1 {
      let rate = Double(reportCount) / (time - rateWindowStart)
      reportCount = 0
      rateWindowStart = time
      DispatchQueue.main.async { self.reportRate = rate }
    }
  }

  private func dispatch(_ actions: [GestureAction]) {
    guard !actions.isEmpty else { return }
    DispatchQueue.main.async { self.route(actions) }
  }

  // MARK: - Routing (main thread)

  private func route(_ actions: [GestureAction]) {
    gestureProbe?(actions)
    var batch: [GestureAction] = []
    func flush(to target: Target?) {
      guard !batch.isEmpty, let target else {
        batch.removeAll()
        return
      }
      switch target {
      case let .panel(window): panelSink.handle(batch, in: window)
      case .system: systemSink.handle(batch)
      }
      batch.removeAll()
    }

    for action in actions {
      switch action {
      case let .touchBegan(p):
        flush(to: currentTarget)
        lastTouchPoint = p
        if let window = panelProvider?(p) {
          currentTarget = .panel(window)
        } else {
          currentTarget = Permissions.canPostEvents ? .system : nil
        }
        batch.append(action)
      case let .momentum(_, _, _, phase):
        if phase == .began || currentTarget != nil {
          // Momentum starts in the same batch as the scroll end, while the finger's target is still current.
          if phase == .began { momentumTarget = currentTarget }
          batch.append(action)
        } else {
          // Later momentum frames arrive from ticks after the lift.
          flush(to: currentTarget)
          batch.append(action)
          flush(to: momentumTarget)
          if phase == .ended { momentumTarget = nil }
        }
      case .touchEnded:
        batch.append(action)
        let target = currentTarget
        flush(to: target)
        currentTarget = nil
      default:
        batch.append(action)
      }
    }
    flush(to: currentTarget)
  }
}

struct TouchProbe {
  /// Global Quartz point on the Edge.
  var point: CGPoint
  var rawX: UInt16
  var rawY: UInt16
  var isDown: Bool
}
