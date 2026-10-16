import AppKit
import SwiftUI

/// A borderless panel that owns the whole Edge, including the strip where the menu bar would be.
///
/// It sits one level above the status bar, joins every Space, and never activates the app, so
/// touching it does not take focus from the main display. It can become key only so the terminal
/// can receive typing.
final class KioskPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts the first click even though the panel is never the active app's window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class KioskController: ObservableObject {
  @Published private(set) var isVisible = false

  /// Fires when the panel's visibility to the user changes (shown/hidden/occluded).
  var onVisibilityChange: ((Bool) -> Void)?

  private var panel: KioskPanel?
  private let makeContent: () -> AnyView
  private var display: EdgeDisplay?
  private var enabled = false
  private var observers: [NSObjectProtocol] = []
  private var watchdog: Timer?

  init(content: @escaping () -> AnyView) {
    makeContent = content
  }

  func update(state: DisplayMonitor.State, enabled: Bool) {
    self.enabled = enabled
    display = state.display
    refresh()
  }

  /// Global-point hit test used by the touch router (main thread).
  func panelForTouch(at p: CGPoint) -> NSWindow? {
    guard isVisible, let panel, let display, display.bounds.contains(p) else { return nil }
    // Something above us (a menu, an alert) at this point gets the touch instead.
    if let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]] {
      for info in above {
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01 else { continue }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if rect.contains(p) { return nil }
      }
    }
    return panel
  }

  var panelWindowNumber: Int? { isVisible ? panel?.windowNumber : nil }

  private func refresh() {
    guard enabled, let display, let screen = display.screen else {
      hide()
      return
    }
    let panel = self.panel ?? makePanel()
    if panel.frame != screen.frame {
      panel.setFrame(screen.frame, display: true)
    }
    if !panel.isVisible { Log.info(.kiosk, "showing on \(display.summary)") }
    panel.orderFrontRegardless()
    setVisible(true)
    startWatching()
  }

  private func hide() {
    guard let panel, panel.isVisible else {
      setVisible(false)
      return
    }
    Log.info(.kiosk, "hiding")
    panel.orderOut(nil)
    stopWatching()
    setVisible(false)
  }

  private func setVisible(_ v: Bool) {
    guard v != isVisible else { return }
    isVisible = v
    onVisibilityChange?(v)
  }

  private func makePanel() -> KioskPanel {
    let p = KioskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // Above the menu bar (24) and status items (25) so the Edge's menu bar is covered.
    // Do not set isFloatingPanel afterwards: it resets the level to .floating (3).
    p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.isOpaque = true
    p.backgroundColor = .black
    p.hasShadow = false
    p.isMovable = false
    p.isReleasedWhenClosed = false
    p.animationBehavior = .none
    p.acceptsMouseMovedEvents = true
    let host = FirstMouseHostingView(rootView: makeContent())
    host.sizingOptions = []
    p.contentView = host
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main) { [weak self] _ in
      guard let self else { return }
      let visible = p.occlusionState.contains(.visible) && p.isVisible
      self.onVisibilityChange?(visible)
    }
    panel = p
    return p
  }

  /// Space switches and full-screen apps can momentarily put other windows above a
  /// `.canJoinAllSpaces` panel; bring it back without activating.
  private func startWatching() {
    guard observers.isEmpty else { return }
    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.reassertFront() }
      })
    }
    let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.reassertFront() }
    t.tolerance = 2
    RunLoop.main.add(t, forMode: .common)
    watchdog = t
  }

  private func stopWatching() {
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    observers.removeAll()
    watchdog?.invalidate()
    watchdog = nil
  }

  private func reassertFront() {
    guard isVisible, let panel else { return }
    if let screen = display?.screen, panel.frame != screen.frame {
      panel.setFrame(screen.frame, display: true)
    }
    panel.orderFrontRegardless()
  }
}
