import AppKit
import CoreGraphics
import EdgeCore

/// Moves the Dock to the main display by replaying what a user does: a short push against a free
/// stretch of the main display's Dock edge. Used when the Dock has ended up on the Edge (e.g. after
/// wake), and when the user pushes down against the fenced bottom of the main display, where most
/// of the edge borders the Edge and macOS itself would not summon the Dock.
/// Approach adapted from DockAnchor (MIT, bwya77).
final class DockRelocator {
  private let queue = DispatchQueue(label: "pro.seol.EdgeCompanion.dock", qos: .userInitiated)
  private var pending: DispatchWorkItem?
  private var running = false
  private var lastSummon: TimeInterval = 0

  /// Checks after `delay` and relocates if needed. Repeated calls collapse into one check.
  func check(after delay: TimeInterval = 1.5, ifOn edge: CGRect) {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.moveToMain(attempt: 1, reason: "the Dock landed on the Edge") { $0.equalTo(edge) }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// The user is pushing down at the bottom of the main display: bring the Dock if it is elsewhere.
  func summonToMain() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSummon > 3 else { return }
    lastSummon = now
    let main = CGDisplayBounds(CGMainDisplayID())
    moveToMain(attempt: 1, reason: "pushed down at the bottom of the main display") { !$0.equalTo(main) }
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }

  /// The display rect the Dock window currently occupies, if the Dock is visible.
  static func currentDockDisplay() -> CGRect? {
    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list where (info[kCGWindowOwnerName as String] as? String) == "Dock" && (info[kCGWindowLayer as String] as? Int) == dockLevel {
      guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
      let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      let centre = CGPoint(x: rect.midX, y: rect.midY)
      return EdgeLocator.allBounds().first { $0.contains(centre) }
    }
    return nil
  }

  /// Moves the Dock to the main display if `shouldMove(dockDisplay)` holds. Main thread.
  private func moveToMain(attempt: Int, reason: String, shouldMove: @escaping (CGRect) -> Bool) {
    guard !running, Permissions.canPostEvents else { return }
    let main = CGDisplayBounds(CGMainDisplayID())
    guard let dockDisplay = Self.currentDockDisplay(), !dockDisplay.equalTo(main), shouldMove(dockDisplay) else { return }
    // Never fight the user mid-drag.
    guard NSEvent.pressedMouseButtons == 0 else { return }
    let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
    let edge = PointerMath.DockEdge(rawValue: orientation ?? "bottom") ?? .bottom
    guard let trigger = PointerMath.dockTriggerPoint(on: main, edge: edge, displays: EdgeLocator.allBounds()) else {
      Log.info(.pointer, "dock is on another display but the main display has no free \(edge.rawValue) edge")
      return
    }
    running = true
    Log.info(.pointer, "moving the Dock from \(dockDisplay) to the main display via \(trigger): \(reason) (attempt \(attempt))")
    queue.async { [weak self] in
      CursorHider.whileHidden { Self.push(toward: trigger, edge: edge) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        guard let self else { return }
        self.running = false
        let now = Self.currentDockDisplay()
        if let now, !now.equalTo(main), shouldMove(now), attempt < 2 {
          self.moveToMain(attempt: attempt + 1, reason: reason, shouldMove: shouldMove)
        } else {
          Log.info(.pointer, now.map { $0.equalTo(main) ? "Dock is on the main display" : "Dock did not move (\($0))" } ?? "Dock not visible")
        }
      }
    }
  }

  /// Approaches the edge, holds against it briefly, then puts the cursor back.
  private static func push(toward edgePoint: CGPoint, edge: PointerMath.DockEdge) {
    let original = CGEvent(source: nil)?.location ?? edgePoint
    PointerGuard.borrow.begin(for: 2)
    defer {
      CGWarpMouseCursorPosition(original)
      CGAssociateMouseAndMouseCursorPosition(1)
      PointerGuard.borrow.end()
    }
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    source?.userData = EventTag.value
    let approach: CGPoint
    switch edge {
    case .bottom: approach = CGPoint(x: edgePoint.x, y: edgePoint.y - 50)
    case .left: approach = CGPoint(x: edgePoint.x + 50, y: edgePoint.y)
    case .right: approach = CGPoint(x: edgePoint.x - 50, y: edgePoint.y)
    }
    func move(_ p: CGPoint) {
      CGWarpMouseCursorPosition(p)
      guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
      e.setIntegerValueField(.eventSourceUserData, value: EventTag.value)
      e.post(tap: .cghidEventTap)
    }
    move(approach)
    usleep(30000)
    for i in 1 ... 8 {
      let t = CGFloat(i) / 8
      move(CGPoint(x: approach.x + (edgePoint.x - approach.x) * t, y: approach.y + (edgePoint.y - approach.y) * t))
      usleep(15000)
    }
    for _ in 0 ..< 12 {
      move(edgePoint)
      usleep(25000)
    }
  }
}
