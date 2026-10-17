import AppKit
import EdgeCore

/// Delivers touch gestures straight into our own Edge panel through AppKit, so the system cursor
/// never moves and focus is never taken from the app the user is working in.
final class PanelEventSink {
  private weak var window: NSWindow?
  private var eventNumber = 0
  private var scrollTarget: NSView?
  /// Total finger travel of the current scroll, to recognise page swipes on the dashboard.
  private var scrollTravel: (dx: Double, dy: Double) = (0, 0)
  private var scrollStart: CGPoint = .zero

  func handle(_ actions: [GestureAction], in window: NSWindow) {
    self.window = window
    for action in actions {
      switch action {
      case let .touchBegan(p):
        prepareFocus(at: p, in: window)
      case .touchEnded:
        break
      case let .pointerDown(p, count):
        post(.leftMouseDown, at: p, clickCount: count, in: window)
      case let .pointerDrag(p):
        post(.leftMouseDragged, at: p, clickCount: 1, in: window)
      case let .pointerUp(p, count):
        post(.leftMouseUp, at: p, clickCount: count, in: window)
      case let .click(p, count):
        post(.leftMouseDown, at: p, clickCount: count, in: window)
        post(.leftMouseUp, at: p, clickCount: count, in: window)
      case let .rightClick(p):
        post(.rightMouseDown, at: p, clickCount: 1, in: window)
        post(.rightMouseUp, at: p, clickCount: 1, in: window)
      case let .scroll(p, dx, dy, phase):
        if phase == .began {
          scrollTarget = hitView(at: p, in: window)
          scrollTravel = (0, 0)
          scrollStart = p
        }
        scrollTravel.dx += dx
        scrollTravel.dy += dy
        scroll(dx: dx, dy: dy, scrollPhase: phase, momentumPhase: nil, at: p)
        if phase == .ended { detectPageSwipe(in: window) }
      case let .momentum(p, dx, dy, phase):
        scroll(dx: dx, dy: dy, scrollPhase: nil, momentumPhase: phase, at: p)
        if phase == .ended { scrollTarget = nil }
      }
    }
  }

  // MARK: - Helpers

  /// A mostly horizontal swipe outside the terminal turns the dashboard page; an upward one is
  /// offered to the widget it started on.
  private func detectPageSwipe(in window: NSWindow) {
    let (dx, dy) = scrollTravel
    guard !isInsideFocusable(scrollTarget) else { return }
    // SwiftUI's global space in the hosting view has a top-left origin.
    let w = windowPoint(scrollStart, in: window)
    let height = window.contentView?.bounds.height ?? window.frame.height
    if dy < -70, abs(dy) > abs(dx) * 1.5 {
      NotificationCenter.default.post(name: .edgeDashboardSwipeUp, object: CGPoint(x: w.x, y: height - w.y))
      return
    }
    guard abs(dx) > 90, abs(dx) > abs(dy) * 1.5 else { return }
    // Finger moving left reveals the next page, like a phone home screen.
    NotificationCenter.default.post(name: .edgeDashboardSwipe, object: DashboardSwipe(step: dx < 0 ? 1 : -1, start: CGPoint(x: w.x, y: height - w.y)))
  }

  private func isInsideFocusable(_ view: NSView?) -> Bool {
    var v = view
    while let current = v {
      if current is KeyboardFocusable { return true }
      v = current.superview
    }
    return false
  }

  /// Text-input views (the terminal) need the panel to be key; plain buttons do not.
  private func prepareFocus(at p: CGPoint, in window: NSWindow) {
    guard let view = hitView(at: p, in: window) else { return }
    var v: NSView? = view
    while let current = v {
      if current is KeyboardFocusable {
        window.makeKey()
        window.makeFirstResponder(current)
        return
      }
      v = current.superview
    }
  }

  private func post(_ type: NSEvent.EventType, at p: CGPoint, clickCount: Int, in window: NSWindow) {
    eventNumber += 1
    guard let e = NSEvent.mouseEvent(
      with: type,
      location: windowPoint(p, in: window),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: max(clickCount, 1),
      pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1
    ) else { return }
    NSApp.postEvent(e, atStart: false)
  }

  private func scroll(dx: Double, dy: Double, scrollPhase: ScrollPhase?, momentumPhase: ScrollPhase?, at p: CGPoint) {
    guard let target = scrollTarget, let window,
          let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
    // An NSEvent built from a CGEvent has no window, so AppKit reports the location in screen
    // coordinates as `locationInWindow`. Views such as the terminal turn that into a cell position,
    // so encode the point so that the screen-space reading equals the real window-space point.
    let inWindow = windowPoint(p, in: window)
    cg.location = CGPoint(x: inWindow.x, y: primaryScreenHeight - inWindow.y)
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    if let phase = scrollPhase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: EventTag.scrollPhaseValue(phase)) }
    if let phase = momentumPhase { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: EventTag.momentumPhaseValue(phase)) }
    guard let e = NSEvent(cgEvent: cg) else { return }
    target.scrollWheel(with: e)
  }

  private func hitView(at p: CGPoint, in window: NSWindow) -> NSView? {
    guard let content = window.contentView else { return nil }
    let local = content.convert(windowPoint(p, in: window), from: nil)
    return content.hitTest(local)
  }

  private var primaryScreenHeight: CGFloat {
    NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
  }

  /// Global Quartz point (top-left origin) → window base coordinates (bottom-left origin).
  private func windowPoint(_ p: CGPoint, in window: NSWindow) -> NSPoint {
    let screenPoint = NSPoint(x: p.x, y: primaryScreenHeight - p.y)
    return NSPoint(x: screenPoint.x - window.frame.minX, y: screenPoint.y - window.frame.minY)
  }
}

/// Marker for views that should receive keyboard focus when touched (the terminal).
protocol KeyboardFocusable: NSView {}
