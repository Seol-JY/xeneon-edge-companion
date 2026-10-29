import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Shared state the menu and settings window observe.
final class AppModel: ObservableObject {
  @Published var edgeState: DisplayMonitor.State = .disconnected
  @Published var pointerStatus: PointerGuard.Status = .off
  @Published var canListen = Permissions.canListen
  @Published var canPostEvents = Permissions.canPostEvents
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = SettingsStore.shared
  let model = AppModel()
  let monitor = DisplayMonitor()
  let touch = TouchController()
  let pointerGuard = PointerGuard()
  let evictor = WindowEvictor()
  let touchTest = TouchTestController()
  lazy var color = ColorService(settings: store)
  lazy var kiosk = KioskController {
    AnyView(DashboardView(store: SettingsStore.shared, terminal: TerminalSession.shared))
  }

  private var statusMenu: StatusMenuController?
  private var settingsWindow: NSWindow?
  private var cancellables = Set<AnyCancellable>()
  private var permissionTimer: Timer?
  private var lastSettledGeneration = 0
  private var panelOnScreen = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    Log.info(.app, "launch \(Bundle.main.bundleIdentifier ?? "(unbundled)")")
    installMainMenu()

    touch.panelProvider = { [weak self] p in
      self?.touchTest.windowForTouch(at: p) ?? self?.kiosk.panelForTouch(at: p)
    }
    kiosk.onVisibilityChange = { [weak self] visible in
      self?.panelOnScreen = visible
      self?.updateSuspension()
      self?.reconfigureInputGuards()
    }
    pointerGuard.onStatus = { [weak self] s in self?.model.pointerStatus = s }

    store.$settings
      .removeDuplicates()
      .sink { [weak self] s in self?.apply(settings: s) }
      .store(in: &cancellables)

    monitor.addListener { [weak self] state in self?.edgeStateChanged(state) }
    monitor.start()

    statusMenu = StatusMenuController(app: self)
    requestPermissionsIfNeeded()
  }

  func applicationWillTerminate(_ notification: Notification) {
    touch.setEnabled(false)
    pointerGuard.configure(edgeBounds: nil, fenceEnabled: false, allowOptionEntry: false, dockLock: false)
    monitor.stop()
  }

  // MARK: - State fan-out

  private func edgeStateChanged(_ state: DisplayMonitor.State) {
    model.edgeState = state
    let s = store.settings
    if case let .connected(display, generation) = state, generation != lastSettledGeneration {
      lastSettledGeneration = generation
      if s.ensureNativeResolution, ResolutionService.ensureNative(display) {
        monitor.refresh()
      }
    }
    color.edgeChanged(state)
    if state.display == nil, touchTest.isOpen { touchTest.close() }
    // Wake and unlock show up as state changes; the Dock may have moved meanwhile.
    if state.isActive { pointerGuard.checkDock(after: 3) }
    let calibration = state.display.map { store.profile(for: $0.profileKey).touchCalibration } ?? .identity
    touch.edgeChanged(state, calibration: calibration)
    kiosk.update(state: state, enabled: s.dashboardEnabled)
    reconfigureInputGuards()
    updateSuspension()
  }

  private func apply(settings s: AppSettings) {
    touch.apply(settings: s)
    if let d = monitor.state.display {
      touch.edgeChanged(monitor.state, calibration: store.profile(for: d.profileKey).touchCalibration)
    }
    kiosk.update(state: monitor.state, enabled: s.dashboardEnabled)
    TerminalSession.shared.configure(fontSize: s.terminalFontSize, useTmux: s.terminalUseTmux)
    settingsWindow?.title = tr("EdgeCompanion 설정", "EdgeCompanion Settings")
    reconfigureInputGuards()
    HomeTemperatureModel.shared.configure(shortcut: s.homeTemperatureShortcut, enabled: s.dashboardEnabled && s.pages.contains { $0.slots.contains { $0.kind == .homeTemperature } })
    BannerWatcher.shared.setEnabled(s.notificationsEnabled && s.dashboardEnabled && Permissions.canPostEvents)
  }

  /// The fence and the evictor only make sense while the dashboard owns the Edge; the Dock lock applies always.
  private func reconfigureInputGuards() {
    let s = store.settings
    let bounds = monitor.state.display?.bounds
    let owning = kiosk.isVisible
    pointerGuard.configure(edgeBounds: bounds, fenceEnabled: s.mouseFenceEnabled && owning, allowOptionEntry: s.fenceBypassWithOption, dockLock: s.dockLockEnabled)
    evictor.configure(edgeBounds: bounds, active: s.evictWindows && owning)
  }

  private func updateSuspension() {
    TelemetryHub.shared.isSuspended = !(monitor.state.isActive && kiosk.isVisible && panelOnScreen)
  }

  // MARK: - Permissions

  private func requestPermissionsIfNeeded() {
    let s = store.settings
    if s.touchEnabled, !Permissions.canListen { Permissions.requestListen() }
    if (s.touchEnabled || s.mouseFenceEnabled || s.evictWindows || s.dockLockEnabled), !Permissions.canPostEvents { Permissions.requestAccessibility() }
    startPermissionPolling()
  }

  /// TCC has no change notification; poll gently until everything is granted.
  private func startPermissionPolling() {
    guard permissionTimer == nil else { return }
    let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkPermissions() }
    }
    t.tolerance = 1
    RunLoop.main.add(t, forMode: .common)
    permissionTimer = t
  }

  private func checkPermissions() {
    let listen = Permissions.canListen
    let post = Permissions.canPostEvents
    if listen != model.canListen || post != model.canPostEvents {
      model.canListen = listen
      model.canPostEvents = post
      Log.info(.app, "permissions: inputMonitoring=\(listen) accessibility=\(post)")
      touch.permissionsChanged()
      reconfigureInputGuards()
      let s = store.settings
      BannerWatcher.shared.setEnabled(s.notificationsEnabled && s.dashboardEnabled && post)
    }
    if listen, post {
      permissionTimer?.invalidate()
      permissionTimer = nil
    }
  }

  // MARK: - Actions used by the menu and settings

  func showSettings() {
    if settingsWindow == nil {
      let view = SettingsView(app: self, store: store, model: model, touch: touch, color: color, kiosk: kiosk)
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      w.title = tr("EdgeCompanion 설정", "EdgeCompanion Settings")
      w.contentView = NSHostingView(rootView: view)
      w.isReleasedWhenClosed = false
      w.center()
      settingsWindow = w
    }
    // Open on the main display, never on the Edge.
    if let w = settingsWindow, let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main {
      if monitor.state.display.map({ $0.bounds.intersects(cgRect(of: w)) }) ?? false || w.screen == nil {
        w.setFrameOrigin(NSPoint(x: main.visibleFrame.midX - w.frame.width / 2, y: main.visibleFrame.midY - w.frame.height / 2))
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  var launchAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      do {
        if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {
        Log.error(.app, "login item: \(error.localizedDescription)")
      }
    }
  }

  func openTouchTest() {
    guard let display = monitor.state.display else { return }
    touchTest.open(on: display, touch: touch)
  }

  func reacquireTouch() {
    touch.setEnabled(false)
    touch.setEnabled(store.settings.touchEnabled)
    touch.permissionsChanged()
  }

  private func cgRect(of window: NSWindow) -> CGRect {
    let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
    let f = window.frame
    return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
  }

  /// Without a main menu, standard shortcuts (copy/paste in the terminal) have nothing to dispatch to.
  private func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: tr("EdgeCompanion 숨기기", "Hide EdgeCompanion"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.mainMenu = main
  }
}
