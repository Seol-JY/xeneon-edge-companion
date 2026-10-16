import AppKit
import EdgeCore
import SwiftUI

/// Full-Edge screen for checking touch accuracy and gesture recognition.
/// Draws where each finger went and names every gesture as it is recognised.
final class TouchTestController {
  private var panel: KioskPanel?
  private let model = TouchTestModel()
  private weak var touch: TouchController?
  private var bounds: CGRect = .zero

  var isOpen: Bool { panel?.isVisible ?? false }

  /// The test panel, if it is open and covers `p` (global point). Used by the touch router.
  func windowForTouch(at p: CGPoint) -> NSWindow? {
    guard isOpen, bounds.contains(p) else { return nil }
    return panel
  }

  func open(on display: EdgeDisplay, touch: TouchController) {
    guard let screen = display.screen else { return }
    self.touch = touch
    bounds = display.bounds
    model.reset(origin: display.bounds.origin)
    let p = panel ?? makePanel()
    p.setFrame(screen.frame, display: true)
    p.orderFrontRegardless()
    touch.probe = { [weak self] sample in self?.model.add(sample) }
    touch.gestureProbe = { [weak self] actions in self?.model.describe(actions) }
    Log.info(.touch, "touch test opened")
  }

  func close() {
    touch?.probe = nil
    touch?.gestureProbe = nil
    panel?.orderOut(nil)
    Log.info(.touch, "touch test closed")
  }

  private func makePanel() -> KioskPanel {
    let p = KioskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // One level above the dashboard so it also covers it.
    p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.isOpaque = true
    p.backgroundColor = .black
    p.hasShadow = false
    p.isReleasedWhenClosed = false
    p.animationBehavior = .none
    let host = FirstMouseHostingView(rootView: TouchTestView(model: model, close: { [weak self] in self?.close() }))
    host.sizingOptions = []
    p.contentView = host
    panel = p
    return p
  }
}

final class TouchTestModel: ObservableObject {
  struct Stroke {
    var points: [CGPoint]
  }

  @Published private(set) var strokes: [Stroke] = []
  @Published private(set) var current: CGPoint?
  @Published private(set) var raw: (x: UInt16, y: UInt16) = (0, 0)
  @Published private(set) var headline = ""
  @Published private(set) var history: [String] = []
  @Published private(set) var sampleRate = 0

  private var origin: CGPoint = .zero
  private var down = false
  private var sampleCount = 0
  private var rateStart = Date()
  private var scrollTotal: (dx: Double, dy: Double) = (0, 0)
  private var dragStart: CGPoint?

  func reset(origin: CGPoint) {
    self.origin = origin
    strokes = []
    current = nil
    headline = tr("Edge를 터치해 보세요", "Touch the Edge")
    history = []
  }

  func clear() {
    strokes = []
    history = []
    headline = ""
  }

  func add(_ sample: TouchProbe) {
    let local = CGPoint(x: sample.point.x - origin.x, y: sample.point.y - origin.y)
    raw = (sample.rawX, sample.rawY)
    sampleCount += 1
    let elapsed = Date().timeIntervalSince(rateStart)
    if elapsed >= 1 {
      sampleRate = Int(Double(sampleCount) / elapsed)
      sampleCount = 0
      rateStart = Date()
    }
    if sample.isDown {
      if !down {
        strokes.append(Stroke(points: []))
        if strokes.count > 40 { strokes.removeFirst(strokes.count - 40) }
      }
      if var last = strokes.popLast() {
        if last.points.count < 2000 { last.points.append(local) }
        strokes.append(last)
      }
      current = local
    } else {
      current = nil
    }
    down = sample.isDown
  }

  func describe(_ actions: [GestureAction]) {
    for action in actions {
      switch action {
      case let .click(_, count):
        log(count >= 3 ? tr("트리플 탭", "Triple tap") : count == 2 ? tr("더블 탭", "Double tap") : tr("탭", "Tap"))
      case .rightClick:
        log(tr("길게 누르기 → 우클릭", "Long press → right-click"))
      case let .pointerDown(p, _):
        dragStart = p
        log(tr("드래그 시작", "Drag started"))
      case let .pointerUp(p, _):
        let distance = dragStart.map { Int(hypot(p.x - $0.x, p.y - $0.y)) } ?? 0
        log(tr("드래그 끝", "Drag ended") + " · \(distance) pt")
        dragStart = nil
      case let .scroll(_, dx, dy, phase):
        switch phase {
        case .began:
          scrollTotal = (dx, dy)
        case .changed:
          scrollTotal.dx += dx
          scrollTotal.dy += dy
        case .ended:
          log(scrollText())
        }
      case let .momentum(_, _, _, phase):
        if phase == .began { log(tr("관성 스크롤 시작", "Momentum started")) }
      case .pointerDrag, .touchBegan, .touchEnded:
        break
      }
    }
  }

  private func scrollText() -> String {
    let (dx, dy) = scrollTotal
    if abs(dy) >= abs(dx) {
      return tr("스크롤", "Scroll") + " \(dy > 0 ? "↓" : "↑") \(Int(abs(dy))) pt"
    }
    return tr("스크롤", "Scroll") + " \(dx > 0 ? "→" : "←") \(Int(abs(dx))) pt"
  }

  private func log(_ text: String) {
    headline = text
    history.insert(text, at: 0)
    if history.count > 10 { history.removeLast(history.count - 10) }
  }
}

struct TouchTestView: View {
  @ObservedObject var model: TouchTestModel
  let close: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      Canvas { ctx, size in
        drawGrid(ctx, size)
        drawTargets(ctx, size)
        for (i, stroke) in model.strokes.enumerated() {
          let age = Double(model.strokes.count - 1 - i)
          let opacity = max(0.15, 1 - age * 0.08)
          var path = Path()
          path.addLines(stroke.points)
          ctx.stroke(path, with: .color(Theme.cpu.opacity(opacity)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
          if let first = stroke.points.first {
            ctx.fill(Path(ellipseIn: CGRect(x: first.x - 5, y: first.y - 5, width: 10, height: 10)), with: .color(Theme.memory.opacity(opacity)))
          }
        }
        if let c = model.current {
          ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 28, y: c.y - 28, width: 56, height: 56)), with: .color(.white), lineWidth: 2)
          ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.white))
        }
      }

      VStack(spacing: 10) {
        Spacer()
        Text(model.headline)
          .font(Theme.text(44, weight: .bold))
          .foregroundStyle(Theme.textPrimary)
        Text(model.history.dropFirst().prefix(6).joined(separator: "   ·   "))
          .font(Theme.text(15, weight: .medium))
          .foregroundStyle(Theme.textTertiary)
          .lineLimit(1)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .allowsHitTesting(false)

      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(tr("터치 테스트", "Touch test")).font(Theme.text(18, weight: .bold)).foregroundStyle(Theme.textPrimary)
          Text(positionText).font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.textSecondary)
          Text("\(model.sampleRate) Hz").font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.textTertiary)
        }
        Spacer()
        Button(tr("지우기", "Clear")) { model.clear() }
          .buttonStyle(TestButtonStyle(tint: Theme.textSecondary))
        Button(tr("테스트 종료", "Close test")) { close() }
          .buttonStyle(TestButtonStyle(tint: Theme.critical))
      }
      .padding(24)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
  }

  private var positionText: String {
    guard let c = model.current else { return tr("손가락 없음", "No finger") }
    return "x \(Int(c.x))  y \(Int(c.y))   ·   raw \(model.raw.x), \(model.raw.y)"
  }

  private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
    var grid = Path()
    stride(from: 0, through: size.width, by: 160).forEach { x in
      grid.move(to: CGPoint(x: x, y: 0))
      grid.addLine(to: CGPoint(x: x, y: size.height))
    }
    stride(from: 0, through: size.height, by: 120).forEach { y in
      grid.move(to: CGPoint(x: 0, y: y))
      grid.addLine(to: CGPoint(x: size.width, y: y))
    }
    ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)
  }

  /// Targets near the corners and centre: touch them to check the mapping at the extremes.
  private func drawTargets(_ ctx: GraphicsContext, _ size: CGSize) {
    let inset: CGFloat = 40
    let points = [
      CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset, y: inset),
      CGPoint(x: inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset),
      CGPoint(x: size.width / 2, y: size.height / 2),
    ]
    for p in points {
      ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)), with: .color(.white.opacity(0.25)), lineWidth: 1.5)
      var cross = Path()
      cross.move(to: CGPoint(x: p.x - 8, y: p.y))
      cross.addLine(to: CGPoint(x: p.x + 8, y: p.y))
      cross.move(to: CGPoint(x: p.x, y: p.y - 8))
      cross.addLine(to: CGPoint(x: p.x, y: p.y + 8))
      ctx.stroke(cross, with: .color(.white.opacity(0.35)), lineWidth: 1.5)
    }
  }
}

private struct TestButtonStyle: ButtonStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.text(16, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 22)
      .frame(height: 48)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
  }
}
