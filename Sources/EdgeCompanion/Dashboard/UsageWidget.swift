import AppKit
import SwiftUI

/// Claude Code and Codex usage limits in one card: each service's 5-hour and weekly windows.
/// Each service is named in its top-left corner and its windows use the full width.
struct UsageWidget: View {
  @ObservedObject private var service = UsageService.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let wide = geo.size.width >= 520
        VStack(alignment: .leading, spacing: 0) {
          ServiceUsage(service: .claude, state: service.claude, now: service.now, wide: wide)
            .frame(maxHeight: .infinity)
          Divider().overlay(Theme.cardBorder)
          ServiceUsage(service: .codex, state: service.codex, now: service.now, wide: wide)
            .frame(maxHeight: .infinity)
        }
      }
    }
    .onAppear { service.retain(.aiUsage) }
    .onDisappear { service.release(.aiUsage) }
  }
}

enum AIService {
  case claude, codex

  var name: String { self == .claude ? "Claude Code" : "Codex" }
  var tint: Color { self == .claude ? Color(red: 0.87, green: 0.50, blue: 0.36) : Color(red: 0.55, green: 0.74, blue: 0.99) }
  var fallbackSymbol: String { self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }

  /// Taken at run time from the apps installed on this Mac, so no logo files ship with this project.
  var appPaths: [String] {
    self == .claude
      ? ["/Applications/Claude.app", "\(NSHomeDirectory())/Applications/Claude.app"]
      : ["/Applications/Codex.app", "/Applications/ChatGPT.app", "\(NSHomeDirectory())/Applications/ChatGPT.app"]
  }
}

private enum AppIconCache {
  static var icons: [String: NSImage] = [:]

  static func icon(for service: AIService) -> NSImage? {
    if let cached = icons[service.name] { return cached }
    guard let path = service.appPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: path)
    image.size = NSSize(width: 96, height: 96)
    icons[service.name] = image
    return image
  }
}

/// The service named small in the top-left corner; its two windows share the full width below.
private struct ServiceUsage: View {
  let service: AIService
  let state: UsageState
  let now: Date
  let wide: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: wide ? 12 : 9) {
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        ServiceIcon(service: service).frame(width: 20, height: 20)
        Text(service.name).font(Theme.text(13.5, weight: .semibold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        badges
        Spacer(minLength: 0)
      }
      switch state {
      case .waiting:
        status(tr("확인 중…", "Checking…"))
      case let .unavailable(message):
        status(message)
      case let .ready(snapshot):
        HStack(spacing: wide ? 28 : 16) {
          BarStat(label: tr("5시간", "5 hours"), window: snapshot.fiveHour?.current(at: now), tint: service.tint, now: now, large: wide)
          BarStat(label: tr("주간", "Weekly"), window: snapshot.weekly?.current(at: now), tint: service.tint, now: now, large: wide)
        }
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder private var badges: some View {
    HStack(spacing: 6) {
      if case let .ready(snapshot) = state, let plan = snapshot.plan {
        Text(plan.uppercased())
          .font(Theme.text(10, weight: .bold))
          .foregroundStyle(service.tint)
          .padding(.horizontal, 6).padding(.vertical, 1.5)
          .background(Capsule().fill(service.tint.opacity(0.16)))
      }
      if case let .ready(snapshot) = state, snapshot.fromLog {
        Text(tr("마지막 기록", "Last log")).font(Theme.text(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
      }
    }
  }

  private func status(_ text: String) -> some View {
    Text(text).font(Theme.text(13)).foregroundStyle(Theme.textTertiary).lineLimit(2)
  }
}

private struct ServiceIcon: View {
  let service: AIService

  var body: some View {
    if let image = AppIconCache.icon(for: service) {
      Image(nsImage: image).resizable().interpolation(.high)
    } else {
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(service.tint.opacity(0.18))
        .overlay(Image(systemName: service.fallbackSymbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(service.tint))
    }
  }
}

private struct BarStat: View {
  let label: String
  let window: UsageWindow?
  let tint: Color
  let now: Date
  var large = false

  var body: some View {
    VStack(alignment: .leading, spacing: large ? 7 : 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(label).font(Theme.text(large ? 14 : 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        Spacer(minLength: 4)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text(window.map { "\(Int($0.usedPercent.rounded()))" } ?? "—")
            .font(Theme.number(large ? 28 : 22, weight: .bold))
          Text("%").font(Theme.number(large ? 15 : 13, weight: .semibold)).opacity(0.8)
        }
        .foregroundStyle(UsageColors.color(window, tint))
      }
      UsageBar(value: (window?.usedPercent ?? 0) / 100, tint: UsageColors.color(window, tint), height: large ? 10 : 8)
      Text(UsageColors.resetText(window, now: now)).font(Theme.text(large ? 12.5 : 11.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }
}

private enum UsageColors {
  /// The service's colour, turning amber then red as a window nears its limit.
  static func color(_ window: UsageWindow?, _ tint: Color) -> Color {
    guard let used = window?.usedPercent else { return tint }
    return used >= 90 ? Theme.critical : used >= 75 ? Theme.warning : tint
  }

  static func resetText(_ window: UsageWindow?, now: Date) -> String {
    guard let resets = window?.resetsAt else { return " " }
    let minutes = max(0, Int(resets.timeIntervalSince(now) / 60))
    let span: String
    if minutes < 60 {
      span = tr("\(minutes)분", "\(minutes)m")
    } else if minutes < 1440 {
      span = tr("\(minutes / 60)시간 \(minutes % 60)분", "\(minutes / 60)h \(minutes % 60)m")
    } else {
      span = tr("\(minutes / 1440)일 \((minutes % 1440) / 60)시간", "\(minutes / 1440)d \((minutes % 1440) / 60)h")
    }
    return tr("\(span) 후 초기화", "resets in \(span)")
  }
}
