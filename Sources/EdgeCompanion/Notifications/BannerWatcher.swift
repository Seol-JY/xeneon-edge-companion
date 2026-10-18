import AppKit
import ApplicationServices

/// One macOS notification banner as it appeared on screen.
struct BannerAlert: Identifiable, Equatable {
  let id = UUID()
  var appName: String
  var appURL: URL?
  var title: String
  var subtitle: String
  var body: String
}

/// Watches Notification Center's banners through the Accessibility API and publishes each new one.
/// There is no public API for other apps' notifications; banners are read the way a screen reader
/// reads them, so only what the banner shows is seen (macOS's "Show previews" applies) and nothing
/// is seen while Focus holds banners back.
final class BannerWatcher: ObservableObject {
  static let shared = BannerWatcher()

  /// The latest banner; the dashboard shows it briefly.
  @Published private(set) var latest: BannerAlert?

  private static let bundleID = "com.apple.notificationcenterui"
  private var observer: AXObserver?
  private var app: AXUIElement?
  private var pid: pid_t = 0
  /// Banner identifiers already handled (also those on screen when watching started).
  private var seen = Set<String>()
  private var scanWork: DispatchWorkItem?
  private var launchObserver: NSObjectProtocol?
  private var enabled = false

  /// Starts or stops watching. Needs Accessibility, which the app already holds for touch.
  func setEnabled(_ on: Bool) {
    guard on != enabled || (on && observer == nil) else { return }
    enabled = on
    if on { attach() } else { detach() }
  }

  private func attach() {
    detach()
    if launchObserver == nil {
      // Notification Center restarts now and then; follow it to its new process.
      launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let self, self.enabled,
              (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.attach() }
      }
    }
    guard AXIsProcessTrusted(),
          let nc = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
    pid = nc.processIdentifier
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.5)
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      Unmanaged<BannerWatcher>.fromOpaque(refcon).takeUnretainedValue().scheduleScan()
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
      AXObserverAddNotification(created, element, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    observer = created
    app = element
    // Whatever is already on screen is old news.
    seen = Set(banners().map(\.id))
    Log.info(.dashboard, "notifications: watching pid \(pid)")
  }

  private func detach() {
    scanWork?.cancel()
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    observer = nil
    app = nil
    if !enabled, let launchObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
      self.launchObserver = nil
    }
  }

  /// One banner appearing fires several events; read the tree once they settle.
  private func scheduleScan() {
    scanWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.scan() }
    scanWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  private func scan() {
    let current = banners()
    let fresh = current.filter { !seen.contains($0.id) }
    seen.formUnion(current.map(\.id))
    // Keep the set from growing forever: anything no longer on screen can be forgotten.
    if seen.count > 200 { seen = Set(current.map(\.id)) }
    guard let banner = fresh.last else { return }
    latest = alert(from: banner)
  }

  // MARK: Reading banners

  private struct Banner {
    var id: String
    var description: String
    var title: String
    var subtitle: String
    var body: String
  }

  /// Banners floating on screen. The Notification Center list (opened from the menu bar clock)
  /// holds old notifications and is skipped.
  private func banners() -> [Banner] {
    guard let app else { return [] }
    var found: [Banner] = []
    for window in Self.children(app, kAXWindowsAttribute) {
      collect(window, depth: 0, into: &found)
    }
    return found
  }

  private func collect(_ e: AXUIElement, depth: Int, into found: inout [Banner]) {
    guard depth < 12 else { return }
    if Self.string(e, kAXIdentifierAttribute) == "AXNotificationListItems" { return }
    let subrole = Self.string(e, kAXSubroleAttribute) ?? ""
    if subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterBannerStack" {
      guard let id = Self.string(e, kAXIdentifierAttribute) else { return }
      var b = Banner(id: id, description: Self.string(e, kAXDescriptionAttribute) ?? "", title: "", subtitle: "", body: "")
      for child in Self.children(e, kAXChildrenAttribute) {
        let value = Self.clean(Self.string(child, kAXValueAttribute) ?? "")
        switch Self.string(child, kAXIdentifierAttribute) {
        case "title": b.title = value
        case "subtitle": b.subtitle = value
        case "body": b.body = value
        default: break
        }
      }
      found.append(b)
      return
    }
    for child in Self.children(e, kAXChildrenAttribute) { collect(child, depth: depth + 1, into: &found) }
  }

  /// The banner's description starts with the sending app's name ("Mail sender, subject…"); the
  /// fields themselves are what the banner shows, so a hidden preview stays hidden here too.
  private func alert(from b: Banner) -> BannerAlert {
    let description = Self.clean(b.description)
    let app = AppDirectory.shared.app(prefixing: description)
    var name = app?.name ?? ""
    if name.isEmpty, !b.title.isEmpty, let r = description.range(of: b.title) {
      name = String(description[..<r.lowerBound]).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }
    return BannerAlert(appName: name, appURL: app?.url, title: b.title, subtitle: b.subtitle, body: b.body)
  }

  // MARK: AX helpers

  private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func children(_ e: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }

  /// Drops the invisible bidi isolates some apps (Discord) wrap names in.
  private static func clean(_ s: String) -> String {
    s.unicodeScalars.filter { !(0x2066 ... 0x2069).contains($0.value) }.map(String.init).joined()
  }
}

/// Installed apps by the name macOS shows for them, to put an icon on a banner that only names
/// its app. Built from what is installed, never from a hand-kept list.
final class AppDirectory {
  static let shared = AppDirectory()

  private var byName: [String: URL] = [:]
  private var builtAt: Date?

  /// The app whose shown name begins `text`, preferring the longest match.
  func app(prefixing text: String) -> (name: String, url: URL)? {
    if let hit = match(text) { return hit }
    // A newly installed app: rebuild, but not more than once a minute.
    if builtAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
      rebuild()
      return match(text)
    }
    return nil
  }

  private func match(_ text: String) -> (name: String, url: URL)? {
    if builtAt == nil { rebuild() }
    var best: (name: String, url: URL)?
    for (name, url) in byName where text.hasPrefix(name + " ") || text.hasPrefix(name + ",") || text == name {
      if name.count > (best?.name.count ?? 0) { best = (name, url) }
    }
    return best
  }

  private func rebuild() {
    var map: [String: URL] = [:]
    let fm = FileManager.default
    let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]
    for dir in dirs {
      for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".app") {
        let path = dir + "/" + file
        map[(fm.displayName(atPath: path) as NSString).deletingPathExtension] = URL(fileURLWithPath: path)
      }
    }
    // Running apps win: they include apps installed elsewhere and name clashes resolve to them.
    for app in NSWorkspace.shared.runningApplications {
      if let name = app.localizedName, let url = app.bundleURL { map[name] = url }
    }
    byName = map
    builtAt = Date()
  }
}
