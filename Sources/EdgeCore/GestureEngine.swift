import CoreGraphics
import Foundation

/// What the injector should do in response to touch input.
public enum GestureAction: Equatable, Sendable {
  /// Left button press. `clickCount` follows macOS double-click rules.
  case pointerDown(CGPoint, clickCount: Int)
  case pointerDrag(CGPoint)
  case pointerUp(CGPoint, clickCount: Int)
  /// Press-and-release at one point (a tap).
  case click(CGPoint, clickCount: Int)
  case rightClick(CGPoint)
  /// Continuous pixel scroll at `point`. Positive `dy` moves content down (follows the finger).
  case scroll(at: CGPoint, dx: Double, dy: Double, phase: ScrollPhase)
  case momentum(at: CGPoint, dx: Double, dy: Double, phase: ScrollPhase)
  /// Finger went down; lets the router decide the target before anything is injected.
  case touchBegan(CGPoint)
  case touchEnded
}

public enum ScrollPhase: Equatable, Sendable {
  case began, changed, ended
}

public struct GestureConfig: Equatable, Sendable {
  /// Movement (points) before a touch stops being a tap.
  public var tapSlop: Double = 12
  public var longPressDelay: TimeInterval = 0.55
  /// Holding still this long before moving turns the move into a click-drag instead of a scroll.
  public var holdToDragDelay: TimeInterval = 0.3
  /// A mostly horizontal move becomes a click-drag (sliders) rather than a horizontal scroll.
  /// Off by default: every move scrolls, and holding briefly before moving drags.
  public var horizontalMoveDrags: Bool = false
  public var horizontalDominance: Double = 1.4
  public var doubleClickInterval: TimeInterval = 0.4
  public var doubleClickDistance: Double = 18
  public var longPressRightClick: Bool = true
  public var momentumEnabled: Bool = true
  public var momentumStartSpeed: Double = 200
  public var momentumStopSpeed: Double = 40
  /// Velocity retained per 1/60 s of momentum.
  public var momentumDecay: Double = 0.95
  /// No report for this long while touching is treated as a lift (lost finger-up).
  public var watchdogTimeout: TimeInterval = 0.8
  public var scrollMultiplier: Double = 1.0

  public init() {}
}

/// Single-contact gesture recognizer. Pure: no timers or side effects.
/// Feed it samples with `handle(down:point:time:)` and call `tick(now:)` while `needsTick` is true.
public struct GestureEngine: Sendable {
  public var config: GestureConfig

  private enum State: Equatable {
    case idle
    case pending(start: CGPoint, startTime: TimeInterval)
    case dragging(clickCount: Int)
    case scrolling
    /// Long press already fired; swallow until lift.
    case consumed
  }

  private var state: State = .idle
  private var lastPoint: CGPoint = .zero
  private var lastSampleTime: TimeInterval = 0
  private var velocitySamples: [(t: TimeInterval, dx: Double, dy: Double)] = []
  private var lastTapTime: TimeInterval = -1000
  private var lastTapPoint: CGPoint = .zero
  private var lastClickCount = 0

  private var momentumVelocity: (dx: Double, dy: Double)?
  private var momentumPoint: CGPoint = .zero
  private var momentumLastTick: TimeInterval = 0

  public init(config: GestureConfig = GestureConfig()) {
    self.config = config
  }

  public var isTouching: Bool {
    if case .idle = state { return false }
    return true
  }

  public var needsTick: Bool {
    momentumVelocity != nil || isTouching
  }

  public mutating func handle(down: Bool, point: CGPoint, time: TimeInterval) -> [GestureAction] {
    var out: [GestureAction] = []
    if down {
      lastSampleTime = time
      switch state {
      case .idle:
        out += stopMomentum()
        state = .pending(start: point, startTime: time)
        lastPoint = point
        velocitySamples.removeAll()
        out.append(.touchBegan(point))
      case let .pending(start, startTime):
        let dx = point.x - start.x
        let dy = point.y - start.y
        if hypot(dx, dy) > config.tapSlop {
          let held = time - startTime >= config.holdToDragDelay
          let horizontal = abs(dx) > config.horizontalDominance * abs(dy)
          if held || (config.horizontalMoveDrags && horizontal) {
            let count = nextClickCount(at: start, time: startTime)
            state = .dragging(clickCount: count)
            out.append(.pointerDown(start, clickCount: count))
            out.append(.pointerDrag(point))
          } else {
            state = .scrolling
            out.append(.scroll(at: start, dx: dx * config.scrollMultiplier, dy: dy * config.scrollMultiplier, phase: .began))
            recordVelocity(dx: dx, dy: dy, time: time)
          }
          lastPoint = point
        } else if config.longPressRightClick, time - startTime >= config.longPressDelay {
          state = .consumed
          out.append(.rightClick(start))
        }
      case .dragging:
        if point != lastPoint {
          out.append(.pointerDrag(point))
          lastPoint = point
        }
      case .scrolling:
        let dx = point.x - lastPoint.x
        let dy = point.y - lastPoint.y
        if dx != 0 || dy != 0 {
          out.append(.scroll(at: point, dx: dx * config.scrollMultiplier, dy: dy * config.scrollMultiplier, phase: .changed))
          recordVelocity(dx: dx, dy: dy, time: time)
          lastPoint = point
        }
      case .consumed:
        break
      }
    } else {
      out += lift(at: point, time: time, clean: true)
    }
    return out
  }

  /// Drives long-press detection, the lost-lift watchdog and scroll momentum.
  public mutating func tick(now: TimeInterval) -> [GestureAction] {
    var out: [GestureAction] = []
    switch state {
    case let .pending(start, startTime):
      if now - lastSampleTime > config.watchdogTimeout {
        out += lift(at: start, time: now, clean: false)
      } else if config.longPressRightClick, now - startTime >= config.longPressDelay {
        state = .consumed
        out.append(.rightClick(start))
      }
    case .dragging, .scrolling, .consumed:
      if now - lastSampleTime > config.watchdogTimeout {
        out += lift(at: lastPoint, time: now, clean: false)
      }
    case .idle:
      break
    }

    if var v = momentumVelocity {
      let dt = max(now - momentumLastTick, 1.0 / 240)
      momentumLastTick = now
      let decay = pow(config.momentumDecay, dt * 60)
      v.dx *= decay
      v.dy *= decay
      if hypot(v.dx, v.dy) < config.momentumStopSpeed {
        out += stopMomentum()
      } else {
        momentumVelocity = v
        out.append(.momentum(at: momentumPoint, dx: v.dx * dt, dy: v.dy * dt, phase: .changed))
      }
    }
    return out
  }

  /// Cancels everything in flight (device removed, display changed, app quitting).
  public mutating func reset() -> [GestureAction] {
    var out = lift(at: lastPoint, time: lastSampleTime, clean: false)
    out += stopMomentum()
    return out
  }

  // MARK: - Internals

  /// `clean` is false when the lift was inferred (watchdog/reset): never turn that into a click.
  private mutating func lift(at point: CGPoint, time: TimeInterval, clean: Bool) -> [GestureAction] {
    var out: [GestureAction] = []
    switch state {
    case .idle:
      return out
    case let .pending(start, startTime):
      if clean {
        let count = nextClickCount(at: start, time: startTime)
        out.append(.click(start, clickCount: count))
        lastTapTime = time
        lastTapPoint = start
        lastClickCount = count
      }
    case let .dragging(count):
      out.append(.pointerUp(clean ? point : lastPoint, clickCount: count))
    case .scrolling:
      out.append(.scroll(at: lastPoint, dx: 0, dy: 0, phase: .ended))
      if clean, config.momentumEnabled, let v = releaseVelocity(at: time), hypot(v.dx, v.dy) >= config.momentumStartSpeed {
        momentumVelocity = v
        momentumPoint = lastPoint
        momentumLastTick = time
        out.append(.momentum(at: lastPoint, dx: 0, dy: 0, phase: .began))
      }
    case .consumed:
      break
    }
    state = .idle
    out.append(.touchEnded)
    return out
  }

  private mutating func stopMomentum() -> [GestureAction] {
    guard momentumVelocity != nil else { return [] }
    momentumVelocity = nil
    return [.momentum(at: momentumPoint, dx: 0, dy: 0, phase: .ended)]
  }

  private mutating func nextClickCount(at point: CGPoint, time: TimeInterval) -> Int {
    let close = hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y) <= config.doubleClickDistance
    if close, time - lastTapTime <= config.doubleClickInterval {
      return min(lastClickCount + 1, 3)
    }
    return 1
  }

  private mutating func recordVelocity(dx: Double, dy: Double, time: TimeInterval) {
    velocitySamples.append((time, dx * config.scrollMultiplier, dy * config.scrollMultiplier))
    velocitySamples.removeAll { time - $0.t > 0.1 }
  }

  /// Average velocity (points/second) over the last ~100 ms, or nil if the finger paused before lifting.
  private func releaseVelocity(at time: TimeInterval) -> (dx: Double, dy: Double)? {
    let recent = velocitySamples.filter { time - $0.t <= 0.1 }
    guard recent.count >= 2, let first = recent.first else { return nil }
    let span = max(time - first.t, 1.0 / 120)
    let sx = recent.reduce(0) { $0 + $1.dx }
    let sy = recent.reduce(0) { $0 + $1.dy }
    return (sx / span, sy / span)
  }
}
