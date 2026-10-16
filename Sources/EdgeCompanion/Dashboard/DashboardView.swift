import EdgeCore
import SwiftUI

extension Notification.Name {
  /// Posted with a `DashboardSwipe` when a horizontal swipe lands on the dashboard.
  static let edgeDashboardSwipe = Notification.Name("EdgeDashboardSwipe")
}

struct DashboardSwipe {
  /// +1 next page, -1 previous.
  var step: Int
  /// Where the swipe started, in the dashboard's top-left coordinates.
  var start: CGPoint
}

/// Root of the Edge panel: an optional terminal on one side and swipeable pages of widgets.
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
      HStack(spacing: Theme.gap) {
        if s.terminalEnabled, s.terminalSide == .left { terminalCard(s, total: geo.size.width) }
        pages(s)
        if s.terminalEnabled, s.terminalSide == .right { terminalCard(s, total: geo.size.width) }
      }
      .padding(Theme.padding)
      .frame(width: geo.size.width, height: geo.size.height)
    }
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
  private func pages(_ s: AppSettings) -> some View {
    let count = s.pages.count
    let current = min(page, max(count - 1, 0))
    ZStack {
      if count > 0 {
        PageGrid(page: s.pages[current])
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
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(Capsule().fill(Color.black.opacity(0.55)))
          .padding(.bottom, 10)
          .transition(.opacity)
      }
    }
  }

  private func go(to target: Int, count: Int) {
    guard count > 0 else { return }
    let next = min(max(target, 0), count - 1)
    guard next != page else { return }
    forward = next > page
    withAnimation(.easeInOut(duration: 0.28)) {
      page = next
      showDots = true
    }
    hideDots?.cancel()
    let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.3)) { showDots = false } }
    hideDots = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func terminalCard(_ s: AppSettings, total: CGFloat) -> some View {
    TerminalCard(session: terminal)
      .frame(width: min(max(s.terminalWidth, 480), total - 360))
  }
}

/// One page: widgets packed into two rows. Every cell gets an exact frame, so a value changing
/// inside a widget never makes the rest of the page lay out again.
struct PageGrid: View {
  let page: DashboardPage

  var body: some View {
    GeometryReader { geo in
      let layout = GridLayout.pack(page.slots.map(\.size))
      let columns = CGFloat(max(layout.columnCount, 1))
      let cellW = (geo.size.width - Theme.gap * (columns - 1)) / columns
      let cellH = (geo.size.height - Theme.gap) / 2
      ZStack(alignment: .topLeading) {
        ForEach(layout.placements, id: \.index) { p in
          let slot = page.slots[p.index]
          let w = cellW * CGFloat(p.columns) + Theme.gap * CGFloat(p.columns - 1)
          let h = cellH * CGFloat(p.rows) + Theme.gap * CGFloat(p.rows - 1)
          WidgetHost(slot: slot)
            .frame(width: floor(w), height: floor(h))
            .clipped()
            .offset(x: floor((cellW + Theme.gap) * CGFloat(p.column)), y: floor((cellH + Theme.gap) * CGFloat(p.row)))
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
    case .clock: ClockWidget(id: slot.id, size: slot.size)
    case .launcher: LauncherWidget(items: SettingsStore.shared.settings.launcherItems)
    case .aiUsage: UsageWidget()
    case .timer: TimerWidget()
    case .volume: VolumeWidget(id: slot.id)
    case .web: WebWidget()
    case .media: MediaWidget(slotID: slot.id)
    case .spacer: Color.clear
    default: TelemetryWidget(kind: slot.kind, slotID: slot.id)
    }
  }
}
