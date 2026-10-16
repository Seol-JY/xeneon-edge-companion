import AppKit
import EdgeCore
import SwiftUI

/// The clock, with the Apple Music player as a second page. While music plays the player comes to
/// the front; it steps back when playback stops or stays paused for a while.
struct ClockWidget: View {
  let id: UUID
  var size: WidgetSize = .small
  @ObservedObject private var music = MusicController.shared

  var body: some View {
    PagedCard(id: id, count: music.isActive ? 2 : 1) { page in
      if page == 1 { NowPlayingBackdrop() }
    } content: { page in
      if page == 1 { NowPlayingView() } else { ClockFace() }
    }
    .onAppear {
      music.start()
      if music.featured { TilePager.shared.show(id, page: 1) }
    }
    .onChange(of: music.featured) { _, featured in TilePager.shared.show(id, page: featured ? 1 : 0) }
    .onChange(of: music.track?.key) { _, _ in
      if music.state == .playing { TilePager.shared.show(id, page: 1) }
    }
  }
}

struct ClockFace: View {
  private static let time: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  private static let seconds: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "ss"
    return f
  }()

  private static let date: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
    return f
  }()

  var body: some View {
    GeometryReader { geo in
      // Largest time that fits: "HH:mm" plus the small seconds is about 3.9 em wide in SF Rounded bold.
      let timeSize = min(geo.size.width / 3.9, geo.size.height * 0.42, 190)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .leading, spacing: 4) {
          Spacer(minLength: 0)
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.time.string(from: context.date))
              .font(Theme.number(timeSize, weight: .bold))
              .foregroundStyle(Theme.textPrimary)
            Text(Self.seconds.string(from: context.date))
              .font(Theme.number(timeSize * 0.34, weight: .medium))
              .foregroundStyle(Theme.textTertiary)
          }
          Text(Self.date.string(from: context.date))
            .font(Theme.text(max(18, timeSize * 0.24), weight: .medium))
            .foregroundStyle(Theme.textSecondary)
          Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
      }
    }
  }
}

struct LauncherWidget: View {
  let items: [LauncherItem]

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let layout = Self.layout(count: items.count, in: geo.size)
        // An eager grid: a lazy one lays tiles out after it appears, which showed as a nudge
        // while the dashboard page slid in.
        let rows = stride(from: 0, to: items.count, by: layout.columns).map { Array(items[$0 ..< min($0 + layout.columns, items.count)]) }
        VStack(spacing: 10) {
          ForEach(rows.indices, id: \.self) { r in
            HStack(spacing: 10) {
              ForEach(rows[r]) { item in tile(item, layout: layout) }
              if rows[r].count < layout.columns {
                ForEach(0 ..< layout.columns - rows[r].count, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
              }
            }
          }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
      }
    }
  }

  private func tile(_ item: LauncherItem, layout: (columns: Int, tileHeight: CGFloat, icon: CGFloat)) -> some View {
    Button {
      Launcher.open(item)
    } label: {
      VStack(spacing: 10) {
        LauncherIcon(target: item.target)
          .frame(width: layout.icon, height: layout.icon)
        Text(item.title)
          .font(Theme.text(14, weight: .medium))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)
      .frame(height: layout.tileHeight)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
  }

  /// Fills the card: as many columns as fit (tiles at least 120 pt wide), rows sharing the height.
  static func layout(count: Int, in size: CGSize) -> (columns: Int, tileHeight: CGFloat, icon: CGFloat) {
    guard count > 0 else { return (1, 0, 0) }
    let maxColumns = max(1, Int((size.width + 10) / 130))
    let columns = min(count, maxColumns)
    let rows = Int((Double(count) / Double(columns)).rounded(.up))
    let tileHeight = max(80, (size.height - CGFloat(rows - 1) * 10) / CGFloat(rows))
    let icon = min(72, max(36, tileHeight * 0.45))
    return (columns, tileHeight, icon)
  }
}

struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.6 : 1)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
  }
}

struct LauncherIcon: View {
  let target: String

  var body: some View {
    if let image = Launcher.icon(for: target) {
      Image(nsImage: image).resizable().interpolation(.high)
    } else {
      Image(systemName: target.hasPrefix("shell:") ? "terminal" : "link")
        .font(Theme.text(26))
        .foregroundStyle(Theme.textSecondary)
    }
  }
}

enum Launcher {
  private static var iconCache: [String: NSImage] = [:]

  static func appURL(for target: String) -> URL? {
    if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
    if target.contains("://") || target.hasPrefix("shell:") { return nil }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
  }

  static func icon(for target: String) -> NSImage? {
    if let cached = iconCache[target] { return cached }
    guard let url = appURL(for: target) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    image.size = NSSize(width: 64, height: 64)
    iconCache[target] = image
    return image
  }

  /// Opens apps on the main display: the app is activated normally and macOS places new windows on
  /// the display with the cursor, which the mouse fence keeps off the Edge.
  static func open(_ item: LauncherItem) {
    let t = item.target
    if t.hasPrefix("shell:") {
      let command = String(t.dropFirst("shell:".count))
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      p.arguments = ["-lc", command]
      try? p.run()
      return
    }
    if t.contains("://"), let url = URL(string: t) {
      NSWorkspace.shared.open(url)
      return
    }
    guard let url = appURL(for: t) else {
      Log.error(.dashboard, "launcher target not found: \(t)")
      return
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: cfg)
  }
}
