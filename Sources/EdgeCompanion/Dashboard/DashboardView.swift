import EdgeCore
import SwiftUI

extension Notification.Name {
  /// Posted with a `DashboardSwipe` when a horizontal swipe lands on the dashboard.
  static let edgeDashboardSwipe = Notification.Name("EdgeDashboardSwipe")
  /// Posted with the start point (dashboard top-left coordinates) of an upward swipe.
  static let edgeDashboardSwipeUp = Notification.Name("EdgeDashboardSwipeUp")
}

struct DashboardSwipe {
  /// +1 next page, -1 previous.
  var step: Int
  /// Where the swipe started, in the dashboard's top-left coordinates.
  var start: CGPoint
}

/// Swipeable dashboard pages, including an optional full-height terminal widget.
struct DashboardView: View {
  @ObservedObject var store: SettingsStore
  @ObservedObject var terminal: TerminalSession
  @State private var page = 0
  @State private var forward = true
  /// The page dots appear only briefly after a page change, so they never sit over content.
  @State private var showDots = false
  @State private var hideDots: DispatchWorkItem?

  var body: some View {
    let s = store.settings
    GeometryReader { geo in
      pages(s, width: geo.size.width)
    }
    .overlay { NotificationOverlay() }
    .background(Theme.background)
    .preferredColorScheme(.dark)
    .onAppear { terminal.configure(fontSize: s.terminalFontSize, useTmux: s.terminalUseTmux) }
    .onChange(of: s.terminalFontSize) { _, size in terminal.configure(fontSize: size, useTmux: s.terminalUseTmux) }
    .onReceive(NotificationCenter.default.publisher(for: .edgeDashboardSwipe)) { note in
      guard let swipe = note.object as? DashboardSwipe else { return }
      // A widget with its own pages takes the swipe; otherwise turn the dashboard page.
      if !TilePager.shared.handleSwipe(step: swipe.step, at: swipe.start) {
        go(to: page + swipe.step, count: s.pages.count)
      }
    }
  }

  @ViewBuilder
  private func pages(_ s: AppSettings, width: CGFloat) -> some View {
    let count = s.pages.count
    let current = min(page, max(count - 1, 0))
    ZStack {
      if count > 0 {
        PageGrid(page: s.pages[current], terminalWidth: s.terminalWidth)
          .padding(Theme.padding)
          .frame(width: width)
          .compositingGroup()
          .id(s.pages[current].id)
          .transition(.asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)))
      }
    }
    // Clip only the sliding pages; the dots sit in the padding below them.
    .clipped()
    .overlay(alignment: .bottom) {
      if count > 1, showDots {
        PageDots(count: count, current: current) { go(to: $0, count: count) }
          .padding(.horizontal, 10).padding(.vertical, 3)
          .background(Capsule().fill(Color.black.opacity(0.55)))
          .padding(.bottom, 1)
          .transition(.opacity)
      }
    }
  }

  private func go(to target: Int, count: Int) {
    guard count > 0 else { return }
    let next = min(max(target, 0), count - 1)
    guard next != page else { return }
    forward = next > page
    // Commit the new direction before removing the old page, which owns its previous transition.
    DispatchQueue.main.async {
      withAnimation(.easeInOut(duration: 0.28)) {
        page = next
        showDots = true
      }
    }
    hideDots?.cancel()
    let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.3)) { showDots = false } }
    hideDots = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

}

/// One page: widgets packed into two rows. Every cell gets an exact frame, so a value changing
/// inside a widget never makes the rest of the page lay out again.
struct PageGrid: View {
  let page: DashboardPage
  var terminalWidth: CGFloat = SettingsStore.shared.settings.terminalWidth

  var body: some View {
    GeometryReader { geo in
      let layout = GridLayout.pack(page.slots.map { $0.kind == .terminal ? .tall : $0.size })
      let terminalColumn = layout.placements.first { page.slots[$0.index].kind == .terminal }?.column
      let metrics = GridLayout.columnMetrics(count: layout.columnCount, width: geo.size.width,
                                            gap: Theme.gap, fixedColumn: terminalColumn, fixedWidth: terminalWidth)
      let cellH = (geo.size.height - Theme.gap) / 2
      ZStack(alignment: .topLeading) {
        ForEach(layout.placements, id: \.index) { p in
          let slot = page.slots[p.index]
          let w = metrics.widths[p.column ..< p.column + p.columns].reduce(0, +) + Theme.gap * CGFloat(p.columns - 1)
          let h = cellH * CGFloat(p.rows) + Theme.gap * CGFloat(p.rows - 1)
          WidgetHost(slot: slot)
            .frame(width: floor(w), height: floor(h))
            .clipped()
            .offset(x: floor(metrics.origins[p.column]), y: floor((cellH + Theme.gap) * CGFloat(p.row)))
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }
  }
}

struct PageDots: View {
  let count: Int
  let current: Int
  let select: (Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(0 ..< count, id: \.self) { i in
        Capsule()
          .fill(i == current ? Theme.textSecondary : Theme.track)
          .frame(width: i == current ? 18 : 7, height: 7)
          .contentShape(Rectangle().inset(by: -8))
          .onTapGesture { select(i) }
      }
    }
  }
}

struct WidgetHost: View {
  let slot: WidgetSlot

  var body: some View {
    switch slot.kind {
    case .terminal: TerminalCard(session: TerminalSession.shared)
    case .clock: ClockWidget(id: slot.id, size: slot.size)
    case .launcher: LauncherWidget(items: SettingsStore.shared.settings.launcherItems)
    case .aiUsage: UsageWidget()
    case .timer: TimerWidget()
    case .volume: VolumeWidget(id: slot.id)
    case .sleep: SleepWidget()
    case .discord: DiscordWidget(id: slot.id)
    case .homeTemperature: HomeTemperatureWidget()
    case .web: WebWidget()
    case .media: MediaWidget(slotID: slot.id)
    case .spacer: Color.clear
    default: TelemetryWidget(kind: slot.kind, slotID: slot.id)
    }
  }
}
