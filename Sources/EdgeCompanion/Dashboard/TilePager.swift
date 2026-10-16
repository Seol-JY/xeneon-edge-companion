import SwiftUI

/// Pages inside widgets. A horizontal swipe that starts on a widget with several pages turns that
/// widget's page; anywhere else it turns the dashboard page.
final class TilePager: ObservableObject {
  static let shared = TilePager()

  @Published private(set) var pages: [UUID: Int] = [:]
  private var counts: [UUID: Int] = [:]
  /// Tile frames in the dashboard's top-left window coordinates.
  private var frames: [UUID: CGRect] = [:]

  func page(of id: UUID) -> Int { pages[id] ?? 0 }

  func register(_ id: UUID, count: Int, frame: CGRect) {
    counts[id] = count
    frames[id] = frame
    if let p = pages[id], p >= count { pages[id] = max(0, count - 1) }
  }

  func setCount(_ id: UUID, count: Int) {
    counts[id] = count
    if let p = pages[id], p >= count { pages[id] = max(0, count - 1) }
  }

  /// Turns to `page` without a swipe, even before the widget has registered (it clamps then).
  func show(_ id: UUID, page: Int) {
    guard page != self.page(of: id) else { return }
    withAnimation(.easeInOut(duration: 0.35)) { pages[id] = max(page, 0) }
  }

  func unregister(_ id: UUID) {
    counts[id] = nil
    frames[id] = nil
  }

  func select(_ id: UUID, page: Int) {
    let count = counts[id] ?? 1
    let next = min(max(page, 0), count - 1)
    guard next != self.page(of: id) else { return }
    withAnimation(.easeInOut(duration: 0.25)) { pages[id] = next }
  }

  /// Returns true if a multi-page widget under `point` took the swipe.
  func handleSwipe(step: Int, at point: CGPoint) -> Bool {
    guard let (id, _) = frames.first(where: { $0.value.contains(point) }), (counts[id] ?? 1) > 1 else { return false }
    select(id, page: page(of: id) + step)
    return true
  }
}

/// A widget card whose content has several pages, with dots along the bottom.
struct PagedCard<Content: View, Backdrop: View>: View {
  let id: UUID
  let count: Int
  @ViewBuilder var content: (Int) -> Content
  @ViewBuilder var backdrop: (Int) -> Backdrop
  @ObservedObject private var pager = TilePager.shared

  init(id: UUID, count: Int, @ViewBuilder content: @escaping (Int) -> Content) where Backdrop == EmptyView {
    self.init(id: id, count: count, backdrop: { _ in EmptyView() }, content: content)
  }

  /// `backdrop` fills the whole card behind a page and fades with it.
  init(id: UUID, count: Int, @ViewBuilder backdrop: @escaping (Int) -> Backdrop, @ViewBuilder content: @escaping (Int) -> Content) {
    self.id = id
    self.count = count
    self.content = content
    self.backdrop = backdrop
  }

  var body: some View {
    let current = min(pager.page(of: id), count - 1)
    WidgetCard {
      ZStack {
        backdrop(current)
          .id(current)
          .transition(.opacity)
      }
    } content: {
      ZStack {
        content(current)
          .id(current)
          .transition(.opacity)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .padding(.bottom, count > 1 ? 14 : 0)
      .overlay(alignment: .bottom) {
        if count > 1 {
          HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { i in
              Capsule()
                .fill(i == current ? Theme.textSecondary : Theme.track)
                .frame(width: i == current ? 14 : 6, height: 6)
                .contentShape(Rectangle().inset(by: -8))
                .onTapGesture { pager.select(id, page: i) }
            }
          }
        }
      }
    }
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { pager.register(id, count: count, frame: geo.frame(in: .global)) }
          .onChange(of: geo.frame(in: .global)) { _, frame in pager.register(id, count: count, frame: frame) }
      }
    )
    .onChange(of: count) { _, c in pager.setCount(id, count: c) }
    .onDisappear { pager.unregister(id) }
  }
}
