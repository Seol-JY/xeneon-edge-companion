import SwiftUI

/// Visual tokens for the Edge dashboard. The panel is 1x, so strokes and type are sized in whole points.
enum Theme {
  static let background = Color(red: 0.035, green: 0.039, blue: 0.051)
  static let card = Color(red: 0.075, green: 0.083, blue: 0.102)
  static let cardBorder = Color.white.opacity(0.06)
  static let track = Color.white.opacity(0.08)
  static let textPrimary = Color.white.opacity(0.93)
  static let textSecondary = Color.white.opacity(0.55)
  static let textTertiary = Color.white.opacity(0.45)

  static let cpu = Color(red: 0.20, green: 0.82, blue: 0.75)
  static let cpuEfficiency = Color(red: 0.36, green: 0.70, blue: 0.95)
  static let gpu = Color(red: 0.65, green: 0.55, blue: 0.98)
  static let memory = Color(red: 0.96, green: 0.72, blue: 0.29)
  static let netIn = Color(red: 0.38, green: 0.65, blue: 0.98)
  static let netOut = Color(red: 0.98, green: 0.45, blue: 0.55)
  static let disk = Color(red: 0.55, green: 0.85, blue: 0.45)
  static let heat = Color(red: 0.99, green: 0.50, blue: 0.30)
  static let battery = Color(red: 0.40, green: 0.87, blue: 0.50)
  static let warning = Color(red: 0.99, green: 0.75, blue: 0.25)
  static let critical = Color(red: 0.98, green: 0.35, blue: 0.35)

  static let cornerRadius: CGFloat = 18
  static let gap: CGFloat = 12
  static let padding: CGFloat = 14

  /// Figures with fixed-width digits so changing values don't shift the layout.
  static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .rounded).monospacedDigit()
  }

  /// Labels and other text.
  static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
}

/// Card chrome shared by every widget. No title: each widget's content says what it is.
struct WidgetCard<Content: View, Backdrop: View>: View {
  private let content: Content
  private let backdrop: Backdrop

  init(@ViewBuilder content: () -> Content) where Backdrop == EmptyView {
    self.content = content()
    self.backdrop = EmptyView()
  }

  /// `backdrop` fills the card behind the content, clipped to its rounded shape.
  init(@ViewBuilder backdrop: () -> Backdrop, @ViewBuilder content: () -> Content) {
    self.content = content()
    self.backdrop = backdrop()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(18)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(
        ZStack {
          Theme.card
          backdrop
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .strokeBorder(Theme.cardBorder, lineWidth: 1)
      )
  }
}

/// Horizontal usage bar.
struct UsageBar: View {
  var value: Double
  var tint: Color
  var height: CGFloat = 8

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Theme.track)
        Capsule().fill(tint)
          .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
          .opacity(value > 0.001 ? 1 : 0)
      }
    }
    .frame(height: height)
    .transaction { $0.animation = nil }
  }
}

/// Circular gauge drawn with a single trimmed stroke.
struct RingGauge: View {
  var value: Double
  var tint: Color
  var lineWidth: CGFloat = 12
  /// Colours laid around the full circle from the top; the filled arc shows as much as it reaches.
  var gradient: [Color]? = nil

  var body: some View {
    ZStack {
      Circle().stroke(Theme.track, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: min(max(value, 0), 1))
        .stroke(style, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(lineWidth / 2)
    .transaction { $0.animation = nil }
  }

  private var style: AnyShapeStyle {
    guard let gradient else { return AnyShapeStyle(tint) }
    // The circle is rotated -90°, so the gradient's 0° is already at the top. Starting it a little
    // before 0° keeps the rounded start cap on the first colour instead of wrapping to the last.
    return AnyShapeStyle(AngularGradient(colors: gradient, center: .center, startAngle: .degrees(-14), endAngle: .degrees(346)))
  }
}

/// Filled sparkline drawn in a Canvas (cheap to redraw once a second).
struct Sparkline: View {
  var values: [Double]
  var tint: Color
  /// Fixed upper bound; nil scales to the data.
  var maxValue: Double?
  /// Dashed reference lines as fractions of the height (1 = top), so a quiet graph still reads as a chart.
  var guides: [Double] = []
  /// Small label at the top-right, naming what the top line stands for.
  var topLabel: String?

  var body: some View {
    Canvas { ctx, size in
      for g in guides {
        let y = size.height - CGFloat(g) * (size.height - 2) - 1
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(line, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
      }
      if let topLabel {
        ctx.draw(Text(topLabel).font(Theme.number(10.5, weight: .medium)).foregroundColor(.white.opacity(0.35)),
                 at: CGPoint(x: size.width - 2, y: 2), anchor: .topTrailing)
      }
      guard values.count > 1 else { return }
      let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
      let step = size.width / CGFloat(values.count - 1)
      var line = Path()
      for (i, v) in values.enumerated() {
        let p = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(min(v / top, 1)) * (size.height - 2) - 1)
        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
      }
      var fill = line
      fill.addLine(to: CGPoint(x: size.width, y: size.height))
      fill.addLine(to: CGPoint(x: 0, y: size.height))
      fill.closeSubpath()
      ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      ctx.stroke(line, with: .color(tint), lineWidth: 1.5)
    }
  }
}

enum Format {
  static func bytes(_ v: Double, perSecond: Bool = false) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = max(v, 0)
    var i = 0
    while value >= 1000, i < units.count - 1 {
      value /= 1000
      i += 1
    }
    let s = value >= 100 || i == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return "\(s) \(units[i])\(perSecond ? "/s" : "")"
  }

  static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

  static func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let d = s / 86400
    let h = (s % 86400) / 3600
    let m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
  }
}
