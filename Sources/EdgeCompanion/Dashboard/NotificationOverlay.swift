import AppKit
import SwiftUI

/// A Mac notification shown over the dashboard for a moment: the dashboard blurs behind a card
/// with the app's icon, who it is from and what it says. A tap dismisses it early; a newer one
/// replaces the card's content in place.
struct NotificationOverlay: View {
  @ObservedObject private var watcher = BannerWatcher.shared
  /// Kept after hiding so the card fades out with its content instead of emptying first.
  @State private var alert: BannerAlert?
  @State private var visible = false
  @State private var hideWork: DispatchWorkItem?

  /// How long a notification stays up.
  static let duration: TimeInterval = 2.4

  var body: some View {
    ZStack {
      if let alert {
        // The views stay in place while hidden; only their opacity and scale animate, so nothing
        // is inserted or removed mid-fade.
        BackdropBlur()
          .overlay(Color.black.opacity(0.35))
          .opacity(visible ? 1 : 0)
        AlertCard(alert: alert)
          .opacity(visible ? 1 : 0)
          .offset(y: visible ? 0 : 48)
      }
    }
    .contentShape(Rectangle())
    .allowsHitTesting(visible)
    .onTapGesture { hide() }
    .onChange(of: watcher.latest) { _, latest in
      guard let latest, SettingsStore.shared.settings.notificationsEnabled else { return }
      show(latest)
    }
    .onDisappear { hideWork?.cancel() }
  }

  private func show(_ next: BannerAlert) {
    if visible {
      withAnimation(.easeInOut(duration: 0.2)) { alert = next }
    } else {
      alert = next
      withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { visible = true }
    }
    hideWork?.cancel()
    let work = DispatchWorkItem { hide() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
  }

  private func hide() {
    hideWork?.cancel()
    hideWork = nil
    withAnimation(.easeInOut(duration: 0.32)) { visible = false } completion: {
      // Drop the blur once faded out; a hidden NSVisualEffectView would keep blurring the window.
      if !visible { alert = nil }
    }
  }
}

/// macOS's own blur of whatever the dashboard draws underneath.
private struct BackdropBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.blendingMode = .withinWindow
    v.material = .fullScreenUI
    v.state = .active
    v.appearance = NSAppearance(named: .darkAqua)
    return v
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct AlertCard: View {
  let alert: BannerAlert

  var body: some View {
    // Sits straight on the blur, centred. The text column has a floor so a two-word message
    // still makes a block of about the same weight as a long one.
    HStack(spacing: 46) {
      icon
        .frame(width: 166, height: 166)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
      VStack(alignment: .leading, spacing: 6) {
        Text(alert.appName.isEmpty ? tr("알림", "Notification") : alert.appName)
          .font(Theme.text(26, weight: .medium))
          .foregroundStyle(Theme.textSecondary)
        if !alert.title.isEmpty {
          Text(alert.title)
            .font(Theme.text(57, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
        }
        if !alert.subtitle.isEmpty {
          Text(alert.subtitle)
            .font(Theme.text(34, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
        }
        if !alert.body.isEmpty {
          Text(alert.body)
            .font(Theme.text(39))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .lineLimit(2)
            .padding(.top, 2)
        }
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(minWidth: 620, maxWidth: 1700, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
    .fixedSize(horizontal: true, vertical: false)
    .shadow(color: .black.opacity(0.4), radius: 12)
  }

  @ViewBuilder
  private var icon: some View {
    if let url = alert.appURL {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    } else {
      // No app to take an icon from: a plain bell in a rounded tile.
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(Color.white.opacity(0.08))
        .padding(10)
        .overlay(
          Image(systemName: "bell.fill")
            .font(.system(size: 46, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
        )
    }
  }
}
