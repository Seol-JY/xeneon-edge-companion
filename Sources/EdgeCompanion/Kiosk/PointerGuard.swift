import AppKit
import CoreGraphics
import EdgeCore

/// Shapes where the real mouse pointer may go, with one event tap at the HID level:
///
/// - **Fence:** keeps the pointer off the Edge while the dashboard owns it. Entering with Option
///   held (optional) lets the pointer roam the Edge until it leaves again.
/// - **Dock lock:** keeps the pointer a few points away from the Edge's Dock edge, so the Dock never
///   lands on the Edge. The main and built-in displays work as usual.
///
/// macOS keeps two cursor positions: the HID system's (which the visible cursor follows) and the
/// WindowServer's (where clicks land). Rewriting the event location at the HID tap only moves the
/// second, so every clamp also warps the cursor, which resets both. Doing it at the HID tap, before
/// the event spreads, avoids the bounce of correcting an already-moved cursor.
/// Events we synthesise for touch carry `EventTag` and pass untouched.
/// Runs on its own thread so a busy main thread can never stall the system pointer.
final class PointerGuard {
  enum Status: Equatable { case off, active, needsAccessibility }

  /// Set by the touch injector while it deliberately parks the cursor on the Edge.
  static let borrow = CursorBorrow()

  private(set) var status: Status = .off
  var onStatus: ((Status) -> Void)?

  // Shared with the tap thread, guarded by `lock`.
  private let lock = NSLock()
  private var fenced: CGRect?
  private var edgeBounds: CGRect?
  private var allowOptionEntry = true
  private var dockLock = false
  private var wasDockLock = false
  private var displays: [CGRect] = []
  private var mainDisplay: CGRect = .zero
  private var dockEdge: PointerMath.DockEdge = .bottom

  // Tap-thread state.
  private var lastOutside: CGPoint?
  private var roamingWithOption = false
  /// When the current push down against the fence (from the main display) started.
  private var pushDownSince: TimeInterval?
  private var lastPushDown: TimeInterval = 0

  private var thread: Thread?
  private var runLoop: CFRunLoop?
  private var tap: CFMachPort?
  private var retryTimer: Timer?
  private var screenObserver: NSObjectProtocol?
  /// A warp normally makes macOS ignore real mouse input for 0.25 s, which felt like the cursor
  /// sticking at the fence. Zeroing the interval on these states (kept alive here) removes that.
  private let suppressionSources: [CGEventSource] = [CGEventSourceStateID.combinedSessionState, .hidSystemState].compactMap {
    let s = CGEventSource(stateID: $0)
    s?.localEventsSuppressionInterval = 0
    return s
  }
  /// Moves the Dock off the Edge when the Dock lock is on.
  let dockRelocator = DockRelocator()

  init() {
    screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      self?.refreshGeometry()
      self?.checkDock()
    }
  }

  /// Wake, unlock and display changes can leave the Dock on the wrong display.
  func checkDock(after delay: TimeInterval = 1.5) {
    lock.lock()
    let on = dockLock
    let edge = edgeBounds
    lock.unlock()
    if on, let edge { dockRelocator.check(after: delay, ifOn: edge) } else { dockRelocator.cancel() }
  }

  /// `edgeBounds` nil or `fenceEnabled` false turns the fence off; the tap keeps running while the Dock lock is on.
  func configure(edgeBounds: CGRect?, fenceEnabled: Bool, allowOptionEntry: Bool, dockLock: Bool) {
    lock.lock()
    fenced = fenceEnabled ? edgeBounds : nil
    self.edgeBounds = edgeBounds
    self.allowOptionEntry = allowOptionEntry
    self.dockLock = dockLock
    let wanted = fenced != nil || dockLock
    let dockLockTurnedOn = dockLock && !wasDockLock
    wasDockLock = dockLock
    lock.unlock()
    refreshGeometry()
    if dockLockTurnedOn { checkDock(after: 0.5) }
    if wanted { start() } else { stop() }
  }

  private func refreshGeometry() {
    let all = EdgeLocator.allBounds()
    let main = CGDisplayBounds(CGMainDisplayID())
    let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
    lock.lock()
    displays = all
    mainDisplay = main
    dockEdge = PointerMath.DockEdge(rawValue: orientation ?? "bottom") ?? .bottom
    lock.unlock()
  }

  // MARK: - Lifecycle

  private func start() {
    guard thread == nil else { return }
    guard Permissions.canPostEvents else {
      setStatus(.needsAccessibility)
      scheduleRetry()
      return
    }
    let ready = DispatchSemaphore(value: 0)
    let t = Thread { [weak self] in
      guard let self else { return }
      self.runLoop = CFRunLoopGetCurrent()
      let ok = self.installTap()
      ready.signal()
      if ok { CFRunLoopRun() }
    }
    t.name = "EdgeCompanion.PointerGuard"
    t.qualityOfService = .userInteractive
    thread = t
    t.start()
    ready.wait()
    if tap == nil {
      thread = nil
      setStatus(.needsAccessibility)
      scheduleRetry()
    } else {
      setStatus(.active)
      Log.info(.pointer, "active")
    }
  }

  private func stop() {
    retryTimer?.invalidate()
    retryTimer = nil
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    tap = nil
    if let rl = runLoop { CFRunLoopStop(rl) }
    runLoop = nil
    thread = nil
    if status == .active { Log.info(.pointer, "off") }
    setStatus(.off)
  }

  private func scheduleRetry() {
    guard retryTimer == nil else { return }
    let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      guard let self, Permissions.canPostEvents else { return }
      self.retryTimer?.invalidate()
      self.retryTimer = nil
      self.lock.lock()
      let wanted = self.fenced != nil || self.dockLock
      self.lock.unlock()
      if wanted { self.start() }
    }
    RunLoop.main.add(t, forMode: .common)
    retryTimer = t
  }

  private func setStatus(_ s: Status) {
    guard s != status else { return }
    status = s
    DispatchQueue.main.async { self.onStatus?(s) }
  }

  private func installTap() -> Bool {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, ctx in
      guard let ctx else { return Unmanaged.passUnretained(event) }
      return Unmanaged<PointerGuard>.fromOpaque(ctx).takeUnretainedValue().handle(type: type, event: event)
    }, userInfo: ctx) else { return false }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    tap = port
    return true
  }

  // MARK: - Tap callback (tap thread; keep it fast or macOS disables the tap)

  /// Pushing down against the fence for a moment means "bring the Dock here", like a free bottom edge.
  private func notePushDown() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastPushDown > 0.15 { pushDownSince = now }
    lastPushDown = now
    if let since = pushDownSince, now - since >= 0.35 {
      pushDownSince = nil
      DispatchQueue.main.async { [weak self] in self?.dockRelocator.summonToMain() }
    }
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      Log.info(.pointer, "tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
      return Unmanaged.passUnretained(event)
    }
    if EventTag.isOurs(event) { return Unmanaged.passUnretained(event) }

    lock.lock()
    let fenced = self.fenced
    let allowOption = allowOptionEntry
    let dockLock = self.dockLock
    let edgeBounds = self.edgeBounds
    let displays = self.displays
    let mainDisplay = self.mainDisplay
    let dockEdge = self.dockEdge
    lock.unlock()

    let original = event.location
    var target = original

    if let fenced {
      if !fenced.contains(original) {
        roamingWithOption = false
        lastOutside = original
      } else if roamingWithOption || Self.borrow.isActive {
        // Free to move on the Edge until the pointer leaves it.
      } else if allowOption, event.flags.contains(.maskAlternate) {
        roamingWithOption = true
      } else {
        target = PointerMath.fenceClamp(original, fenced: fenced, lastOutside: lastOutside, displays: displays, fallback: mainDisplay)
        if dockLock, dockEdge == .bottom, target.y == fenced.minY - 1, mainDisplay.contains(target),
           event.getIntegerValueField(.mouseEventDeltaY) > 0 {
          notePushDown()
        }
      }
    }

    if dockLock, let edgeBounds, let clamped = PointerMath.dockClamp(target, displays: displays, blocked: [edgeBounds], edge: dockEdge) {
      target = clamped
    }

    if target != original {
      event.location = target
      // Reset the HID-side position too; re-associating cancels the input suppression a warp starts.
      CGWarpMouseCursorPosition(target)
      CGAssociateMouseAndMouseCursorPosition(1)
    }
    return Unmanaged.passUnretained(event)
  }

}

/// Thread-safe "the touch injector is using the cursor" window, so the guard does not fight it.
final class CursorBorrow {
  private let lock = NSLock()
  private var until: TimeInterval = 0

  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return ProcessInfo.processInfo.systemUptime < until
  }

  /// Marks the cursor as borrowed for up to `seconds` (renewed while a gesture continues).
  func begin(for seconds: TimeInterval = 1.0) {
    lock.lock()
    until = ProcessInfo.processInfo.systemUptime + seconds
    lock.unlock()
  }

  func end() {
    lock.lock()
    until = 0
    lock.unlock()
  }
}
