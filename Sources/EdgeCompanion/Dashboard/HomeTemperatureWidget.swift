import EdgeCore
import SwiftUI

struct HomeTemperatureWidget: View {
  @ObservedObject private var model = HomeTemperatureModel.shared
  @ObservedObject private var store = SettingsStore.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let samples = model.samples
        let latest = model.latest
        let stale = latest.map { Date().timeIntervalSince($0.date) > HomeTemperatureModel.interval * 2 } ?? false
        VStack(alignment: .leading, spacing: 0) {
          Text(latest.map { String(format: "%.1f°", $0.celsius) } ?? "—°")
            .font(Theme.number(min(geo.size.width * 0.24, geo.size.height * 0.24, 64), weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          HStack(spacing: 7) {
            Text(store.settings.homeTemperatureLabel.isEmpty ? tr("실내 온도", "Room temperature") : store.settings.homeTemperatureLabel)
              .font(Theme.text(16, weight: .medium))
              .foregroundStyle(Theme.textSecondary)
              .lineLimit(1)
            if latest != nil, model.error != nil || stale {
              Circle().fill(Theme.warning).frame(width: 5, height: 5)
                .help(tr("온도를 갱신하지 못했어요", "Temperature hasn't updated"))
            }
          }
          .padding(.top, 4)
          if let latest {
            TemperatureHistoryChart(samples: samples, end: latest.date)
              .frame(maxHeight: .infinity)
              .padding(.top, 18)
          } else {
            Text(model.error ?? (model.isLoading ? tr("온도를 읽고 있어요", "Reading temperature") :
              model.configured ? tr("첫 측정을 기다리는 중", "Waiting for a reading") :
              tr("설정에서 단축어를 연결해 주세요", "Connect a shortcut in Settings")))
              .font(Theme.text(12.5)).foregroundStyle(Theme.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 20)
          }
        }
        .frame(width: geo.size.width, height: max(0, geo.size.height - 16), alignment: .topLeading)
        .padding(.vertical, 8)
      }
    }
  }
}

/// Same stroke and fill as telemetry sparklines, but positioned by time. Offline gaps stay empty.
private struct TemperatureHistoryChart: View {
  let samples: [HomeTemperatureSample]
  let end: Date
  var body: some View {
    VStack(spacing: 12) {
      if let low = samples.map(\.celsius).min(), let high = samples.map(\.celsius).max() {
        HStack(spacing: 16) {
          extremum(high, symbol: "arrow.up", tint: Theme.heat.opacity(0.85), label: tr("최고", "High"))
          extremum(low, symbol: "arrow.down", tint: Theme.textSecondary, label: tr("최저", "Low"))
          Spacer(minLength: 0)
        }
      }
      Canvas { context, size in
        let firstDate = samples.first?.date ?? end
        let span = min(86400, max(60, end.timeIntervalSince(firstDate)))
        let start = end.addingTimeInterval(-span)
        let values = samples.map(\.celsius)
        let middle = ((values.min() ?? 20) + (values.max() ?? 22)) / 2
        let half = max(1, ((values.max() ?? 22) - (values.min() ?? 20)) / 2 + 0.5)
        let low = floor((middle - half) * 2) / 2
        let high = ceil((middle + half) * 2) / 2
        let plotHeight = max(1, size.height)
        func point(_ sample: HomeTemperatureSample) -> CGPoint {
          CGPoint(x: sample.date.timeIntervalSince(start) / span * size.width,
                  y: 1 + (1 - (sample.celsius - low) / (high - low)) * max(1, plotHeight - 2))
        }
        var groups: [[HomeTemperatureSample]] = []
        for sample in samples where sample.date >= start && sample.date <= end {
          if let previous = groups.last?.last, sample.date.timeIntervalSince(previous.date) <= HomeTemperatureModel.interval * 2 {
            groups[groups.count - 1].append(sample)
          } else { groups.append([sample]) }
        }
        for group in groups {
          let points = group.map(point)
          guard let first = points.first, let last = points.last else { continue }
          if points.count == 1 {
            context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)), with: .color(Theme.heat))
            continue
          }
          let line = smoothPath(points)
          var fill = line
          fill.addLine(to: CGPoint(x: last.x, y: plotHeight)); fill.addLine(to: CGPoint(x: first.x, y: plotHeight)); fill.closeSubpath()
          context.fill(fill, with: .linearGradient(Gradient(colors: [Theme.heat.opacity(0.19), Theme.heat.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: plotHeight)))
          context.stroke(line, with: .color(Theme.heat), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
      }
      .clipped()
    }
  }

  private func extremum(_ value: Double, symbol: String, tint: Color, label: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
      Text(String(format: "%.1f°", value)).font(Theme.number(12.5, weight: .medium))
    }
    .foregroundStyle(tint)
    .accessibilityLabel("\(label) \(String(format: "%.1f", value))°")
  }

  /// Monotone interpolation rounds the minute steps without inventing peaks or overshooting them.
  private func smoothPath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 1 else { return path }
    let slopes = zip(points, points.dropFirst()).map { a, b in
      (b.y - a.y) / max(b.x - a.x, 0.001)
    }
    var tangents = [slopes[0]]
    if points.count > 2 {
      for i in 1..<(points.count - 1) {
        let before = slopes[i - 1], after = slopes[i]
        if before * after <= 0 { tangents.append(0) }
        else {
          let left = max(points[i].x - points[i - 1].x, 0.001)
          let right = max(points[i + 1].x - points[i].x, 0.001)
          let w1 = 2 * right + left, w2 = right + 2 * left
          tangents.append((w1 + w2) / (w1 / before + w2 / after))
        }
      }
    }
    tangents.append(slopes.last!)
    for i in 0..<(points.count - 1) {
      let a = points[i], b = points[i + 1], third = (points[i + 1].x - points[i].x) / 3
      path.addCurve(to: b,
                    control1: CGPoint(x: a.x + third, y: a.y + tangents[i] * third),
                    control2: CGPoint(x: b.x - third, y: b.y - tangents[i + 1] * third))
    }
    return path
  }
}
