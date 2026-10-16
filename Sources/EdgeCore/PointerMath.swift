import CoreGraphics
import Foundation

/// Geometry for the pointer guard: keeping the cursor off the Edge and away from the edges that
/// would pull the Dock onto another display. All rects are global Quartz points (top-left origin).
public enum PointerMath {
  /// Where to put a pointer that tried to enter `fenced`.
  ///
  /// Prefers 1 pt outside the nearest edge of `fenced` (pushing against the border then feels
  /// like a wall), keeping it only if that lands on another display. Otherwise uses the last
  /// position outside the fence, then the centre of `fallback`.
  public static func fenceClamp(_ point: CGPoint, fenced: CGRect, lastOutside: CGPoint?, displays: [CGRect], fallback: CGRect) -> CGPoint {
    let others = displays.filter { !$0.equalTo(fenced) }
    let candidates = [
      CGPoint(x: point.x, y: fenced.minY - 1),
      CGPoint(x: point.x, y: fenced.maxY + 1),
      CGPoint(x: fenced.minX - 1, y: point.y),
      CGPoint(x: fenced.maxX + 1, y: point.y),
    ]
    if let p = candidates
      .filter({ c in others.contains { $0.contains(c) } })
      .min(by: { distance($0, point) < distance($1, point) }) {
      return p
    }
    if let last = lastOutside, !fenced.contains(last), others.contains(where: { $0.contains(last) }) {
      return last
    }
    return CGPoint(x: fallback.midX, y: fallback.midY)
  }

  public enum DockEdge: String, Sendable {
    case bottom, left, right
  }

  /// Keeps the pointer `margin` points away from the Dock edge of each `blocked` display, so
  /// pushing against that edge can never move the Dock there. An edge segment shared with
  /// another display is left alone so the pointer can still cross between displays.
  /// Returns nil when no change is needed.
  public static func dockClamp(_ point: CGPoint, displays: [CGRect], blocked: [CGRect], edge: DockEdge, margin: CGFloat = 3) -> CGPoint? {
    guard let display = displays.first(where: { $0.contains(point) }), blocked.contains(where: { $0.equalTo(display) }) else { return nil }
    func onAnyDisplay(_ p: CGPoint) -> Bool { displays.contains { $0.contains(p) } }
    switch edge {
    case .bottom:
      let limit = display.maxY - 1 - margin
      guard point.y > limit, !onAnyDisplay(CGPoint(x: point.x, y: display.maxY + 1)) else { return nil }
      return CGPoint(x: point.x, y: limit)
    case .left:
      let limit = display.minX + margin
      guard point.x < limit, !onAnyDisplay(CGPoint(x: display.minX - 1, y: point.y)) else { return nil }
      return CGPoint(x: limit, y: point.y)
    case .right:
      let limit = display.maxX - 1 - margin
      guard point.x > limit, !onAnyDisplay(CGPoint(x: display.maxX + 1, y: point.y)) else { return nil }
      return CGPoint(x: limit, y: point.y)
    }
  }

  /// The point on `display`'s Dock edge where pushing moves the Dock there: the middle of the
  /// longest stretch of that edge not shared with another display. Nil if the whole edge is shared.
  public static func dockTriggerPoint(on display: CGRect, edge: DockEdge, displays: [CGRect], step: CGFloat = 4) -> CGPoint? {
    let others = displays.filter { !$0.equalTo(display) }
    func free(_ p: CGPoint) -> Bool { !others.contains { $0.contains(p) } }
    let horizontal = edge == .bottom
    let start = horizontal ? display.minX : display.minY
    let end = horizontal ? display.maxX : display.maxY
    var best: (lo: CGFloat, hi: CGFloat)?
    var runStart: CGFloat?
    var t = start
    while t < end {
      let probe: CGPoint
      switch edge {
      case .bottom: probe = CGPoint(x: t, y: display.maxY + 1)
      case .left: probe = CGPoint(x: display.minX - 1, y: t)
      case .right: probe = CGPoint(x: display.maxX + 1, y: t)
      }
      if free(probe) {
        if runStart == nil { runStart = t }
      } else if let rs = runStart {
        if best == nil || t - rs > best!.hi - best!.lo { best = (rs, t) }
        runStart = nil
      }
      t += step
    }
    if let rs = runStart, best == nil || end - rs > best!.hi - best!.lo { best = (rs, end) }
    guard let run = best, run.hi - run.lo >= 8 else { return nil }
    let mid = ((run.lo + run.hi) / 2).rounded()
    switch edge {
    case .bottom: return CGPoint(x: mid, y: display.maxY - 1)
    case .left: return CGPoint(x: display.minX, y: mid)
    case .right: return CGPoint(x: display.maxX - 1, y: mid)
    }
  }

  static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}
