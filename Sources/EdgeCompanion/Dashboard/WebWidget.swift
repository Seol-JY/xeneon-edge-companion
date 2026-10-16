import AppKit
import SwiftUI
import WebKit

/// A web view that takes the first touch: the kiosk panel is never the key window, and WebKit
/// would otherwise spend that click on focusing the window.
final class EdgeWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The web page widget's single web view, kept alive across dashboard pages so the page is not
/// reloaded every time it comes back into view. Cookies and storage live in WebKit's default
/// persistent store, so logins survive restarts (as long as the site's cookies last).
final class WebWidgetModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  static let shared = WebWidgetModel()

  @Published private(set) var isLoading = false
  @Published private(set) var failure: String?
  /// True once the user follows a link away from the configured page.
  @Published private(set) var awayFromHome = false

  private(set) var home: URL?

  lazy var webView: EdgeWebView = {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let view = EdgeWebView(frame: .zero, configuration: config)
    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsMagnification = false
    view.allowsBackForwardNavigationGestures = false
    return view
  }()

  /// "example.com" → "https://example.com"; nil for an empty or unusable address.
  static func url(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let url = URL(string: withScheme), url.host != nil else { return nil }
    return url
  }

  /// Loads `text` if it differs from the page already set up (or if forced).
  func show(_ text: String, force: Bool = false) {
    let url = Self.url(from: text)
    guard force || url != home else { return }
    home = url
    awayFromHome = false
    failure = nil
    if let url { webView.load(URLRequest(url: url)) }
  }

  func goHome() {
    guard let home else { return }
    failure = nil
    webView.load(URLRequest(url: home))
  }

  func reload() {
    failure = nil
    if webView.url == nil { goHome() } else { webView.reload() }
  }

  func setZoom(_ zoom: Double) {
    let z = CGFloat(min(max(zoom, 0.3), 3))
    if webView.pageZoom != z { webView.pageZoom = z }
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    isLoading = true
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoading = false
    failure = nil
    awayFromHome = !Self.samePage(webView.url, home)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    fail(error)
  }

  /// The web content process can be killed under memory pressure; bring the page back.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    Log.info(.dashboard, "web widget content process ended, reloading")
    reload()
  }

  private func fail(_ error: Error) {
    isLoading = false
    let ns = error as NSError
    // A newer navigation replacing this one is not a failure.
    guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
    failure = ns.localizedDescription
    Log.info(.dashboard, "web widget load failed: \(ns.domain) \(ns.code)")
  }

  // MARK: WKUIDelegate

  /// Links that open a new window (target="_blank") open in the widget instead.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
    return nil
  }

  private static func samePage(_ a: URL?, _ b: URL?) -> Bool {
    guard let a, let b else { return a == b }
    func key(_ u: URL) -> String {
      var path = u.path
      while path.hasSuffix("/") { path.removeLast() }
      return "\(u.host?.lowercased() ?? "")\(path)?\(u.query ?? "")"
    }
    return key(a) == key(b)
  }
}

/// The web page widget: the configured page filling the card.
struct WebWidget: View {
  @ObservedObject private var store = SettingsStore.shared
  @ObservedObject private var web = WebWidgetModel.shared

  var body: some View {
    let address = store.settings.webURL
    let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
    Group {
      if WebWidgetModel.url(from: address) == nil {
        WidgetCard {
          VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "globe").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(tr("설정 > 대시보드에서 띄울 웹페이지 주소를 넣어 주세요", "Set the page to show in Settings > Dashboard"))
              .font(Theme.text(15, weight: .medium))
              .foregroundStyle(Theme.textSecondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      } else {
        WebViewHost(webView: web.webView)
          .background(Theme.card)
          .clipShape(shape)
          .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: 1))
          .overlay {
            if let failure = web.failure { failureView(failure) }
          }
          .overlay(alignment: .topTrailing) {
            if web.awayFromHome { homeButton }
          }
      }
    }
    .onAppear {
      web.setZoom(store.settings.webZoom)
      web.show(address)
    }
    .onChange(of: address) { _, new in web.show(new) }
    .onChange(of: store.settings.webZoom) { _, z in web.setZoom(z) }
  }

  private var homeButton: some View {
    Button { web.goHome() } label: {
      Image(systemName: "house.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.92))
        .frame(width: 40, height: 40)
        .background(Circle().fill(Color.black.opacity(0.55)))
        .contentShape(Circle())
    }
    .buttonStyle(PressableStyle())
    .padding(10)
  }

  private func failureView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "wifi.exclamationmark").font(.system(size: 26, weight: .semibold))
      Text(message).font(Theme.text(14, weight: .medium)).multilineTextAlignment(.center).lineLimit(3)
      Button { web.reload() } label: {
        Text(tr("다시 시도", "Try again"))
          .font(Theme.text(14, weight: .semibold))
          .padding(.horizontal, 16)
          .frame(height: 36)
          .background(Capsule().fill(Color.white.opacity(0.12)))
          .contentShape(Capsule())
      }
      .buttonStyle(PressableStyle())
    }
    .foregroundStyle(Theme.textSecondary)
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.card)
  }
}

/// Hosts the shared web view in a plain container, so SwiftUI rebuilding this view never tears
/// the page down.
private struct WebViewHost: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    // Round the corners in AppKit: the web view is a native view SwiftUI's clip may not reach.
    container.wantsLayer = true
    container.layer?.cornerRadius = Theme.cornerRadius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    attach(to: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    if webView.superview !== container { attach(to: container) }
  }

  private func attach(to container: NSView) {
    webView.removeFromSuperview()
    webView.frame = container.bounds
    webView.autoresizingMask = [.width, .height]
    container.addSubview(webView)
  }
}

/// A normal window on the main display sharing the widget's cookies and storage, for signing in
/// with a keyboard. Closing it reloads the widget so it picks up the new session.
final class WebLoginWindow: NSObject, NSWindowDelegate {
  static let shared = WebLoginWindow()
  private var window: NSWindow?

  func show(_ address: String) {
    guard let url = WebWidgetModel.url(from: address) else { return }
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
    web.load(URLRequest(url: url))
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = tr("웹페이지 위젯", "Web page widget") + " · " + (url.host ?? "")
    window.contentView = web
    window.isReleasedWhenClosed = false
    window.delegate = self
    // Open on the main display, never on the Edge.
    if let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      let f = main.visibleFrame
      window.setFrameOrigin(NSPoint(x: f.midX - web.frame.width / 2, y: f.midY - web.frame.height / 2))
    }
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
    WebWidgetModel.shared.reload()
  }
}
