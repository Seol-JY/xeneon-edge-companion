import EdgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Visual editor for dashboard pages: a scaled preview of the Edge where widgets can be dragged to
/// reorder, tapped to resize or move between pages, and added or removed.
struct LayoutEditor: View {
  @ObservedObject var store: SettingsStore
  @State private var pageIndex = 0
  @State private var selected: UUID?

  private var pages: [DashboardPage] { store.settings.pages }
  private var page: DashboardPage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker(tr("페이지", "Page"), selection: $pageIndex) {
          ForEach(pages.indices, id: \.self) { i in Text(tr("\(i + 1)페이지", "Page \(i + 1)")).tag(i) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Button { addPage() } label: { Image(systemName: "plus") }
          .help(tr("페이지 추가", "Add page"))
        Button { removePage() } label: { Image(systemName: "trash") }
          .disabled(pages.count <= 1)
          .help(tr("이 페이지 삭제", "Delete this page"))
      }

      preview
        .frame(height: 158)

      if let slot = selectedSlot {
        selectionControls(slot)
      } else {
        Text(tr("위젯을 끌어서 순서를 바꾸고, 눌러서 크기를 고를 수 있어요.", "Drag widgets to reorder; click one to resize or move it."))
          .font(.caption).foregroundStyle(.secondary)
      }

      Menu(tr("위젯 추가", "Add widget")) {
        ForEach(availableKinds) { kind in
          Button(kind.title) { add(kind) }
        }
      }
      .disabled(availableKinds.isEmpty)
      .fixedSize()
    }
    .onChange(of: pages.count) { _, count in pageIndex = min(pageIndex, max(count - 1, 0)) }
    // Removing a media widget frees its copied file.
    .onChange(of: pages) { _, _ in MediaLibrary.prune() }
  }

  // MARK: Preview

  private var preview: some View {
    GeometryReader { geo in
      let s = store.settings
      let gap: CGFloat = 4
      // The preview spans the landscape Edge (2560 pt); in split mode the dashboard takes its share.
      let edgeLength: CGFloat = 2560
      let dashLength = s.edgeMode == .split ? SplitLayout.clampedLength(s.splitLength, in: CGRect(x: 0, y: 0, width: edgeLength, height: 720)) : edgeLength
      let scale = geo.size.width / edgeLength
      let dashW = dashLength * scale
      let dashX: CGFloat = s.edgeMode == .split && s.splitSide == .right ? geo.size.width - dashW : 0
      let showTerminal = s.terminalEnabled && dashLength >= DashboardView.minimumWidthForTerminal
      let terminalW = showTerminal ? min(max(CGFloat(s.terminalWidth), 480), dashLength - 360) * scale : 0
      let areaX: CGFloat = dashX + (showTerminal && s.terminalSide == .left ? terminalW + gap : 0)
      let areaW = dashW - (showTerminal ? terminalW + gap : 0)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
        if s.edgeMode == .split {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .overlay(Label(tr("일반 모니터", "Regular display"), systemImage: "macwindow").font(.caption).foregroundStyle(.secondary))
            .frame(width: geo.size.width - dashW - 6, height: geo.size.height - 6)
            .offset(x: s.splitSide == .right ? 3 : dashW + 3, y: 3)
        }
        if showTerminal {
          RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
            .overlay(Image(systemName: "terminal").foregroundStyle(.secondary))
            .frame(width: terminalW - 6, height: geo.size.height - 6)
            .offset(x: s.terminalSide == .left ? dashX + 3 : dashX + dashW - terminalW + 3, y: 3)
        }
        if let page {
          let layout = GridLayout.pack(page.slots.map(\.size))
          let columns = CGFloat(max(layout.columnCount, 1))
          let cellW = (areaW - 6 - gap * (columns - 1)) / columns
          let cellH = (geo.size.height - 6 - gap) / 2
          ForEach(layout.placements, id: \.index) { p in
            let slot = page.slots[p.index]
            tile(slot)
              .frame(width: cellW * CGFloat(p.columns) + gap * CGFloat(p.columns - 1), height: cellH * CGFloat(p.rows) + gap * CGFloat(p.rows - 1))
              .offset(x: areaX + 3 + (cellW + gap) * CGFloat(p.column), y: 3 + (cellH + gap) * CGFloat(p.row))
          }
        }
      }
    }
  }

  private func tile(_ slot: WidgetSlot) -> some View {
    let isSelected = slot.id == selected
    return VStack(spacing: 4) {
      Image(systemName: slot.kind.symbol).font(.system(size: 14, weight: .semibold))
      Text(slot.kind.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
    }
    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.8))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.55) : Color.white.opacity(slot.kind == .spacer ? 0.03 : 0.12)))
    .overlay(slot.kind == .spacer && !isSelected ? RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) : nil)
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
    .contentShape(Rectangle())
    .onTapGesture { selected = isSelected ? nil : slot.id }
    .onDrag { NSItemProvider(object: slot.id.uuidString as NSString) }
    .onDrop(of: [.text], isTargeted: nil) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let text = object as? String, let dragged = UUID(uuidString: text) else { return }
        DispatchQueue.main.async { move(dragged, before: slot.id) }
      }
      return true
    }
  }

  // MARK: Selection

  private var selectedSlot: WidgetSlot? {
    guard let selected, let page else { return nil }
    return page.slots.first { $0.id == selected }
  }

  private func selectionControls(_ slot: WidgetSlot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      sizeControls(slot)
      if slot.kind == .media { mediaControls(slot) }
    }
  }

  private func mediaControls(_ slot: WidgetSlot) -> some View {
    let key = slot.id.uuidString
    let item = store.settings.mediaItems[key]
    return HStack(spacing: 10) {
      Image(systemName: "photo").foregroundStyle(.secondary)
      Text(item?.originalName ?? tr("파일 없음", "No file")).lineLimit(1).truncationMode(.middle)
      Button(tr("파일 선택…", "Choose file…")) { MediaLibrary.choose(for: slot.id) }
      if item != nil {
        Picker(tr("맞춤", "Fit"), selection: Binding(
          get: { store.settings.mediaItems[key]?.fill ?? true },
          set: { store.settings.mediaItems[key]?.fill = $0 })) {
          Text(tr("채우기", "Fill")).tag(true)
          Text(tr("맞추기", "Fit")).tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 140)
      }
      Spacer()
    }
  }

  private func sizeControls(_ slot: WidgetSlot) -> some View {
    HStack(spacing: 10) {
      Text(slot.kind.title).font(.headline)
      Picker(tr("크기", "Size"), selection: Binding(get: { slot.size }, set: { resize(slot.id, $0) })) {
        Text("1×1").tag(WidgetSize.small)
        Text("2×1").tag(WidgetSize.wide)
        Text("1×2").tag(WidgetSize.tall)
        Text("2×2").tag(WidgetSize.large)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 200)
      Button { shift(slot.id, by: -1) } label: { Image(systemName: "arrow.left") }.help(tr("앞으로", "Move earlier"))
      Button { shift(slot.id, by: 1) } label: { Image(systemName: "arrow.right") }.help(tr("뒤로", "Move later"))
      if pages.count > 1 {
        Menu {
          ForEach(pages.indices, id: \.self) { i in
            if i != pageIndex { Button(tr("\(i + 1)페이지로", "To page \(i + 1)")) { moveToPage(slot.id, i) } }
          }
        } label: { Image(systemName: "rectangle.portrait.and.arrow.right") }
          .fixedSize()
          .help(tr("다른 페이지로", "Move to another page"))
      }
      Spacer()
      Button(role: .destructive) { remove(slot.id) } label: { Image(systemName: "trash") }.help(tr("삭제", "Remove"))
    }
  }

  // MARK: Edits

  private var availableKinds: [WidgetKind] {
    let used = Set(pages.flatMap { $0.slots.map(\.kind) })
    return WidgetKind.allCases.filter { $0.allowsMultiple || !used.contains($0) }
  }

  private func updatePage(_ change: (inout DashboardPage) -> Void) {
    guard pages.indices.contains(pageIndex) else { return }
    var all = store.settings.pages
    change(&all[pageIndex])
    store.settings.pages = all
  }

  private func add(_ kind: WidgetKind) {
    let slot = WidgetSlot(kind: kind)
    updatePage { $0.slots.append(slot) }
    selected = slot.id
  }

  private func remove(_ id: UUID) {
    updatePage { $0.slots.removeAll { $0.id == id } }
    selected = nil
  }

  private func resize(_ id: UUID, _ size: WidgetSize) {
    updatePage { page in
      if let i = page.slots.firstIndex(where: { $0.id == id }) { page.slots[i].size = size }
    }
  }

  private func shift(_ id: UUID, by delta: Int) {
    updatePage { page in
      guard let i = page.slots.firstIndex(where: { $0.id == id }) else { return }
      let j = min(max(i + delta, 0), page.slots.count - 1)
      page.slots.swapAt(i, j)
    }
  }

  private func move(_ dragged: UUID, before target: UUID) {
    guard dragged != target else { return }
    updatePage { page in
      guard let from = page.slots.firstIndex(where: { $0.id == dragged }) else { return }
      let slot = page.slots.remove(at: from)
      let to = page.slots.firstIndex(where: { $0.id == target }) ?? page.slots.count
      page.slots.insert(slot, at: to)
    }
  }

  private func moveToPage(_ id: UUID, _ target: Int) {
    var all = store.settings.pages
    guard all.indices.contains(pageIndex), all.indices.contains(target),
          let i = all[pageIndex].slots.firstIndex(where: { $0.id == id }) else { return }
    let slot = all[pageIndex].slots.remove(at: i)
    all[target].slots.append(slot)
    store.settings.pages = all
    selected = nil
  }

  private func addPage() {
    store.settings.pages.append(DashboardPage(slots: []))
    pageIndex = store.settings.pages.count - 1
  }

  private func removePage() {
    guard pages.count > 1 else { return }
    var all = store.settings.pages
    all.remove(at: pageIndex)
    store.settings.pages = all
    pageIndex = max(0, pageIndex - 1)
    selected = nil
  }
}

extension WidgetKind {
  var symbol: String {
    switch self {
    case .clock: return "clock"
    case .cpu: return "cpu"
    case .gpu: return "square.stack.3d.up"
    case .memory: return "memorychip"
    case .network: return "arrow.up.arrow.down"
    case .sensors: return "thermometer.medium"
    case .battery: return "bolt.fill"
    case .launcher: return "square.grid.2x2"
    case .system: return "laptopcomputer"
    case .aiUsage: return "sparkle"
    case .timer: return "timer"
    case .volume: return "speaker.wave.2.fill"
    case .sleep: return "moon.fill"
    case .discord: return "headphones"
    case .web: return "globe"
    case .media: return "photo.on.rectangle.angled"
    case .spacer: return "square.dashed"
    }
  }
}
