import CoreGraphics
import EdgeCore
import Foundation

/// Injects touch gestures as real mouse events for other apps' windows on the Edge.
///
/// The system cursor is borrowed for the duration of a gesture and put back afterwards.
/// Every event carries `EventTag.value` so our pointer guard lets it through.
final class SystemEventInjector {
  private let queue = DispatchQueue(label: "pro.seol.EdgeCompanion.inject", qos: .userInteractive)
  private let source: CGEventSource?
  private var savedCursor: CGPoint?
  private var scrollRemainder = (x: 0.0, y: 0.0)
  private var buttonDown: CGMouseButton?

  var restoreCursor = true

  init() {
    source = CGEventSource(stateID: .hidSystemState)
    // Without this, events posted right after a warp are swallowed for ~250 ms.
    source?.localEventsSuppressionInterval = 0
    source?.userData = EventTag.value
  }

  func handle(_ actions: [GestureAction]) {
    queue.async { self.run(actions) }
  }

  private func run(_ actions: [GestureAction]) {
    for (index, action) in actions.enumerated() {
      switch action {
      case .touchBegan, .touchEnded:
        break
      case let .pointerDown(p, count):
        borrowCursor(to: p)
        post(.leftMouseDown, at: p, button: .left, clickCount: count)
        buttonDown = .left
      case let .pointerDrag(p):
        PointerGuard.borrow.begin()
        post(.leftMouseDragged, at: p, button: .left, clickCount: 1)
      case let .pointerUp(p, count):
        post(.leftMouseUp, at: p, button: .left, clickCount: count)
        buttonDown = nil
        returnCursor()
      case let .click(p, count):
        borrowCursor(to: p)
        usleep(8000)
        post(.leftMouseDown, at: p, button: .left, clickCount: count)
        usleep(35000)
        post(.leftMouseUp, at: p, button: .left, clickCount: count)
        usleep(10000)
        returnCursor()
      case let .rightClick(p):
        borrowCursor(to: p)
        usleep(8000)
        post(.rightMouseDown, at: p, button: .right, clickCount: 1)
        usleep(35000)
        post(.rightMouseUp, at: p, button: .right, clickCount: 1)
        usleep(10000)
        returnCursor()
      case let .scroll(p, dx, dy, phase):
        PointerGuard.borrow.begin()
        if phase == .began {
          scrollRemainder = (0, 0)
          borrowCursor(to: p)
        }
        postScroll(dx: dx, dy: dy, scrollPhase: phase, momentumPhase: nil)
        if phase == .ended {
          let momentumFollows = actions[(index + 1)...].contains {
            if case .momentum(_, _, _, .began) = $0 { return true }
            return false
          }
          if !momentumFollows { returnCursor() }
        }
      case let .momentum(_, dx, dy, phase):
        PointerGuard.borrow.begin()
        postScroll(dx: dx, dy: dy, scrollPhase: nil, momentumPhase: phase)
        if phase == .ended { returnCursor() }
      }
    }
  }

  /// Releases anything still held (device lost, app quitting).
  func cancel() {
    queue.async {
      if let button = self.buttonDown {
        let p = CGEvent(source: nil)?.location ?? .zero
        self.post(button == .left ? .leftMouseUp : .rightMouseUp, at: p, button: button, clickCount: 1)
        self.buttonDown = nil
      }
      self.returnCursor()
    }
  }

  // MARK: - Primitives

  private func borrowCursor(to p: CGPoint) {
    PointerGuard.borrow.begin()
    if savedCursor == nil, restoreCursor {
      savedCursor = CGEvent(source: nil)?.location
    }
    CGWarpMouseCursorPosition(p)
    // A warp otherwise freezes the cursor briefly and detaches it from the mouse.
    CGAssociateMouseAndMouseCursorPosition(1)
    post(.mouseMoved, at: p, button: .left, clickCount: 0)
  }

  private func returnCursor() {
    defer { PointerGuard.borrow.end() }
    guard let saved = savedCursor else { return }
    savedCursor = nil
    CGWarpMouseCursorPosition(saved)
    CGAssociateMouseAndMouseCursorPosition(1)
    // Warping posts no event; a move clears hover state left on the Edge.
    post(.mouseMoved, at: saved, button: .left, clickCount: 0)
  }

  private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clickCount: Int) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if clickCount > 0 { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
    e.setIntegerValueField(.eventSourceUserData, value: EventTag.value)
    e.post(tap: .cghidEventTap)
  }

  private func postScroll(dx: Double, dy: Double, scrollPhase: ScrollPhase?, momentumPhase: ScrollPhase?) {
    // Accumulate sub-pixel deltas so slow drags still scroll.
    scrollRemainder.x += dx
    scrollRemainder.y += dy
    let ix = scrollRemainder.x.rounded(.towardZero)
    let iy = scrollRemainder.y.rounded(.towardZero)
    scrollRemainder.x -= ix
    scrollRemainder.y -= iy
    guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    if let phase = scrollPhase {
      e.setIntegerValueField(.scrollWheelEventScrollPhase, value: EventTag.scrollPhaseValue(phase))
    }
    if let phase = momentumPhase {
      e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: EventTag.momentumPhaseValue(phase))
    }
    e.setIntegerValueField(.eventSourceUserData, value: EventTag.value)
    e.post(tap: .cghidEventTap)
  }
}

enum EventTag {
  /// "EDGE" — marks events this app synthesised.
  static let value: Int64 = 0x4544_4745

  static func isOurs(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == value
  }

  /// NSEvent.Phase raw values used by kCGScrollWheelEventScrollPhase.
  static func scrollPhaseValue(_ p: ScrollPhase) -> Int64 {
    switch p {
    case .began: return 1
    case .changed: return 2
    case .ended: return 4
    }
  }

  /// kCGMomentumScrollPhase: begin 1, continue 2, end 3.
  static func momentumPhaseValue(_ p: ScrollPhase) -> Int64 {
    switch p {
    case .began: return 1
    case .changed: return 2
    case .ended: return 3
    }
  }
}
