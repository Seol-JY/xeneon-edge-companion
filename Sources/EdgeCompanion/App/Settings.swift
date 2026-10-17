import Combine
import EdgeCore
import Foundation

/// Settings that belong to one physical panel, keyed by its real serial number.
struct EdgeProfile: Codable, Equatable {
  var whiteBalance: WhiteBalance = .tunedD65
  /// Gains read from the panel the first time we saw it, so "restore" can put them back.
  var originalWhiteBalance: WhiteBalance?
  var originalColorPreset: UInt16?
  var applyColorOnConnect = true
  var touchCalibration: TouchCalibration = .identity
}

enum TerminalSide: String, Codable, CaseIterable {
  case left, right
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
  /// `network` also pages to disk activity; `system` pages to top processes.
  case clock, cpu, gpu, memory, network, sensors, battery, launcher, system, aiUsage, timer, volume
  /// Keep-awake durations and a sleep button.
  case sleep
  /// A web page (address in `AppSettings.webURL`).
  case web
  /// A photo, GIF or video on loop (file in `AppSettings.mediaItems`); any number may be placed.
  case media
  /// An empty cell for spacing; any number of them may be placed.
  case spacer
  var id: String { rawValue }

  var allowsMultiple: Bool { self == .spacer || self == .media }

  /// Kinds from earlier versions, folded into the current ones (nil: dropped).
  static func migrating(_ raw: String) -> WidgetKind? {
    if let kind = WidgetKind(rawValue: raw) { return kind }
    switch raw {
    case "disk": return .network
    case "processes": return .system
    case "claudeUsage", "codexUsage": return .aiUsage
    default: return nil   // bluetooth: shown in the power widget now
    }
  }
}

/// One widget on a dashboard page.
struct WidgetSlot: Codable, Equatable, Identifiable {
  var id = UUID()
  var kind: WidgetKind
  var size: WidgetSize = .small

  init(id: UUID = UUID(), kind: WidgetKind, size: WidgetSize = .small) {
    self.id = id
    self.kind = kind
    self.size = size
  }

  private enum CodingKeys: String, CodingKey { case id, kind, size }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try c.decode(String.self, forKey: .kind)
    guard let kind = WidgetKind.migrating(raw) else {
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "retired widget \(raw)")
    }
    self.kind = kind
    id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    size = (try? c.decodeIfPresent(WidgetSize.self, forKey: .size)) ?? .small
  }
}

/// A swipeable dashboard page; widgets pack into its two rows in order.
struct DashboardPage: Codable, Equatable, Identifiable {
  var id = UUID()
  var slots: [WidgetSlot]

  init(id: UUID = UUID(), slots: [WidgetSlot]) {
    self.id = id
    self.slots = slots
  }

  private enum CodingKeys: String, CodingKey { case id, slots }
  private struct LenientSlot: Decodable {
    let slot: WidgetSlot?
    init(from decoder: Decoder) throws { slot = try? WidgetSlot(from: decoder) }
  }

  /// Skips retired widget kinds and duplicates instead of failing the whole layout.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    var seen = Set<WidgetKind>()
    slots = ((try? c.decode([LenientSlot].self, forKey: .slots)) ?? []).compactMap(\.slot).filter { $0.kind.allowsMultiple || seen.insert($0.kind).inserted }
  }

  static let defaultPages: [DashboardPage] = [
    DashboardPage(slots: [
      WidgetSlot(kind: .clock, size: .tall),
      WidgetSlot(kind: .network), WidgetSlot(kind: .cpu),
      WidgetSlot(kind: .sensors), WidgetSlot(kind: .gpu),
      WidgetSlot(kind: .battery), WidgetSlot(kind: .memory),
      WidgetSlot(kind: .system), WidgetSlot(kind: .aiUsage),
    ]),
    DashboardPage(slots: [
      WidgetSlot(kind: .launcher, size: .large),
    ]),
  ]
}

struct LauncherItem: Codable, Equatable, Identifiable {
  var id = UUID()
  var title: String
  /// Bundle identifier, absolute app path, URL ("https://…"), or "shell:<command>".
  var target: String
}

/// The file shown by one media widget.
struct MediaItem: Codable, Equatable {
  /// Name of the copy in `MediaLibrary.folder`.
  var file: String
  /// Name of the file the user picked, for display.
  var originalName: String
  /// Fill the card (cropping) rather than fit inside it.
  var fill = true
}

struct AppSettings: Codable, Equatable {
  var language: AppLanguage = .system

  // Touch
  var touchEnabled = true
  var longPressRightClick = true
  var horizontalMoveDrags = false
  var scrollSpeed = 1.0
  var momentumScrolling = true
  var restoreCursorAfterTouch = true

  // Edge as a dedicated surface
  var dashboardEnabled = true
  var mouseFenceEnabled = true
  /// Entering the Edge with Option held lets the pointer roam it until it leaves.
  var fenceBypassWithOption = true
  /// Keep the Dock off the Edge.
  var dockLockEnabled = true
  var evictWindows = true
  var ensureNativeResolution = true

  // Dashboard
  var terminalEnabled = true
  var terminalSide: TerminalSide = .left
  var terminalWidth = 1120.0
  var terminalFontSize = 14.0
  var terminalUseTmux = true
  var pages: [DashboardPage] = DashboardPage.defaultPages
  var launcherItems: [LauncherItem] = [
    LauncherItem(title: "Finder", target: "com.apple.finder"),
    LauncherItem(title: "Safari", target: "com.apple.Safari"),
    LauncherItem(title: "Activity Monitor", target: "com.apple.ActivityMonitor"),
    LauncherItem(title: "System Settings", target: "com.apple.systempreferences"),
  ]
  /// Page shown by the web widget; a bare host gets https://.
  var webURL = ""
  var webZoom = 1.0
  /// Media widget files by slot id (uuidString).
  var mediaItems: [String: MediaItem] = [:]

  var profiles: [String: EdgeProfile] = [:]

  init() {}

  // Decode leniently so adding a field never wipes existing settings.
  init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? current }
    language = v(.language, language)
    touchEnabled = v(.touchEnabled, touchEnabled)
    longPressRightClick = v(.longPressRightClick, longPressRightClick)
    horizontalMoveDrags = v(.horizontalMoveDrags, horizontalMoveDrags)
    scrollSpeed = v(.scrollSpeed, scrollSpeed)
    momentumScrolling = v(.momentumScrolling, momentumScrolling)
    restoreCursorAfterTouch = v(.restoreCursorAfterTouch, restoreCursorAfterTouch)
    dashboardEnabled = v(.dashboardEnabled, dashboardEnabled)
    mouseFenceEnabled = v(.mouseFenceEnabled, mouseFenceEnabled)
    fenceBypassWithOption = v(.fenceBypassWithOption, fenceBypassWithOption)
    dockLockEnabled = v(.dockLockEnabled, dockLockEnabled)
    evictWindows = v(.evictWindows, evictWindows)
    ensureNativeResolution = v(.ensureNativeResolution, ensureNativeResolution)
    terminalEnabled = v(.terminalEnabled, terminalEnabled)
    terminalSide = v(.terminalSide, terminalSide)
    terminalWidth = v(.terminalWidth, terminalWidth)
    terminalFontSize = v(.terminalFontSize, terminalFontSize)
    terminalUseTmux = v(.terminalUseTmux, terminalUseTmux)
    pages = v(.pages, pages)
    // Retired kinds can map onto a widget that already exists (e.g. processes → system):
    // keep the first occurrence across all pages, then drop pages left empty.
    var seen = Set<WidgetKind>()
    pages = pages.map { page in
      var p = page
      p.slots = page.slots.filter { $0.kind.allowsMultiple || seen.insert($0.kind).inserted }
      return p
    }.filter { !$0.slots.isEmpty }
    if pages.isEmpty { pages = DashboardPage.defaultPages }
    // Settings from before pages existed: keep the user's widgets on page 1 in column order.
    if (try? c.decodeIfPresent([DashboardPage].self, forKey: .pages)) == nil,
       let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent([String].self, forKey: .widgets) {
      pages = Self.migratedPages(from: legacy)
    }
    launcherItems = v(.launcherItems, launcherItems)
    webURL = v(.webURL, webURL)
    webZoom = v(.webZoom, webZoom)
    mediaItems = v(.mediaItems, mediaItems)
    profiles = v(.profiles, profiles)
  }
}

extension AppSettings {
  private enum LegacyKeys: String, CodingKey { case widgets }

  /// Settings from before pages: start from the default layout, keeping only the widget kinds the
  /// user had (mapped onto today's kinds) plus anything new.
  static func migratedPages(from legacy: [String]) -> [DashboardPage] {
    let had = Set(legacy.compactMap(WidgetKind.migrating))
    let keep: Set<WidgetKind> = [.aiUsage]
    return DashboardPage.defaultPages.map { page in
      DashboardPage(slots: page.slots.filter { had.contains($0.kind) || keep.contains($0.kind) })
    }.filter { !$0.slots.isEmpty }
  }
}

/// Observable settings store persisted to UserDefaults as JSON.
final class SettingsStore: ObservableObject {
  static let shared = SettingsStore()
  private static let key = "settings.v1"

  @Published var settings: AppSettings {
    didSet {
      guard settings != oldValue else { return }
      save()
    }
  }

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
       let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
      settings = decoded
    } else {
      settings = AppSettings()
    }
  }

  func profile(for key: String) -> EdgeProfile {
    settings.profiles[key] ?? EdgeProfile()
  }

  func updateProfile(for key: String, _ change: (inout EdgeProfile) -> Void) {
    var p = profile(for: key)
    change(&p)
    settings.profiles[key] = p
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    UserDefaults.standard.set(data, forKey: Self.key)
  }
}
