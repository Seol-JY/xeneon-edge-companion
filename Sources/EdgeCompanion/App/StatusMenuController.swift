import AppKit
import EdgeCore

/// The menu bar item. The menu is rebuilt only when it opens, so it costs nothing while closed.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
  private let item: NSStatusItem
  private unowned let app: AppDelegate

  init(app: AppDelegate) {
    self.app = app
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    if let button = item.button {
      button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "EdgeCompanion")
      button.image?.isTemplate = true
    }
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    item.menu = menu
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let s = app.store.settings
    let state = app.model.edgeState

    menu.addItem(info(edgeLine(state)))
    menu.addItem(info(touchLine()))
    if !app.model.canListen || !app.model.canPostEvents {
      menu.addItem(action(tr("권한 설정 열기…", "Open permission settings…"), #selector(openPermissions)))
    }
    menu.addItem(.separator())

    menu.addItem(info(tr("Edge 모드", "Edge mode")))
    let dashboard = toggle(tr("대시보드", "Dashboard"), s.dashboardEnabled, #selector(selectDashboardMode))
    dashboard.indentationLevel = 1
    dashboard.toolTip = tr("Edge를 대시보드 전용으로 써요.", "Uses the Edge as a dedicated dashboard.")
    menu.addItem(dashboard)
    let monitor = toggle(tr("일반 모니터", "Regular display"), !s.dashboardEnabled, #selector(selectMonitorMode))
    monitor.indentationLevel = 1
    monitor.toolTip = tr("Edge를 일반 모니터로 써요.", "Uses the Edge as a regular display.")
    menu.addItem(monitor)
    menu.addItem(.separator())
    menu.addItem(toggle(tr("터치", "Touch"), s.touchEnabled, #selector(toggleTouch)))
    menu.addItem(.separator())

    let colorItem = NSMenuItem(title: tr("색 보정", "Color"), action: nil, keyEquivalent: "")
    colorItem.submenu = colorMenu()
    colorItem.isEnabled = state.display != nil
    menu.addItem(colorItem)
    menu.addItem(.separator())

    let settings = action(tr("설정…", "Settings…"), #selector(openSettings))
    settings.keyEquivalent = ","
    menu.addItem(settings)
    menu.addItem(toggle(tr("로그인 시 실행", "Launch at login"), app.launchAtLogin, #selector(toggleLogin)))
    menu.addItem(.separator())
    let quit = action(tr("EdgeCompanion 종료", "Quit EdgeCompanion"), #selector(quit))
    quit.keyEquivalent = "q"
    menu.addItem(quit)
  }

  private func colorMenu() -> NSMenu {
    let m = NSMenu()
    m.autoenablesItems = false
    if let d = app.model.edgeState.display {
      let wb = app.store.profile(for: d.profileKey).whiteBalance
      m.addItem(info(tr("저장된 값", "Saved") + " R\(wb.red) G\(wb.green) B\(wb.blue)"))
      m.addItem(action(tr("저장된 값 다시 적용", "Reapply saved values"), #selector(applySaved)))
      m.addItem(.separator())
    }
    m.addItem(action("D65", #selector(applyD65)))
    m.addItem(action(tr("공장 초기값", "Factory"), #selector(restoreOriginal)))
    m.addItem(.separator())
    m.addItem(action(tr("세부 조절…", "Adjust…"), #selector(openSettings)))
    return m
  }

  // MARK: - Lines

  private func edgeLine(_ state: DisplayMonitor.State) -> String {
    switch state {
    case .disconnected: return tr("XENEON EDGE 연결 안 됨", "XENEON EDGE not connected")
    case let .connected(d, _): return tr("XENEON EDGE 연결됨", "XENEON EDGE connected") + " · \(Int(d.pixelSize.width))×\(Int(d.pixelSize.height))"
    case .suspended: return tr("XENEON EDGE 대기 중 (잠자기/잠금)", "XENEON EDGE idle (asleep/locked)")
    }
  }

  private func touchLine() -> String {
    switch app.touch.availability {
    case .disabled: return tr("터치 꺼짐", "Touch off")
    case .noDisplay: return tr("터치: 디스플레이 없음", "Touch: no display")
    case .needsInputMonitoring: return tr("터치: 입력 모니터링 권한 필요", "Touch: needs Input Monitoring")
    case .needsAccessibility: return tr("터치: 손쉬운 사용 권한 필요 (자체 화면만 동작)", "Touch: needs Accessibility (dashboard only)")
    case .busy: return tr("터치: 다른 앱이 터치 장치를 쓰는 중", "Touch: another app is using the controller")
    case .waiting: return tr("터치: 장치 기다리는 중", "Touch: waiting for the device")
    case .active: return tr("터치 동작 중", "Touch active")
    case let .failed(msg): return tr("터치 오류", "Touch error") + ": \(msg)"
    }
  }

  // MARK: - Builders

  private func info(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
  }

  private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    i.target = self
    return i
  }

  private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
    let i = action(title, selector)
    i.state = on ? .on : .off
    return i
  }

  // MARK: - Actions

  @objc private func selectDashboardMode() { app.store.settings.dashboardEnabled = true }
  @objc private func selectMonitorMode() { app.store.settings.dashboardEnabled = false }
  @objc private func toggleTouch() { app.store.settings.touchEnabled.toggle() }
  @objc private func toggleLogin() { app.launchAtLogin.toggle() }
  @objc private func openSettings() { app.showSettings() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func openPermissions() {
    if !app.model.canListen { Permissions.openInputMonitoringSettings() } else { Permissions.openAccessibilitySettings() }
  }

  @objc private func applySaved() {
    guard let d = app.model.edgeState.display else { return }
    app.color.apply(app.store.profile(for: d.profileKey).whiteBalance)
  }

  @objc private func applyD65() { saveAndApply(.tunedD65) }

  @objc private func restoreOriginal() {
    guard let d = app.model.edgeState.display else { return }
    let original = app.store.profile(for: d.profileKey).originalWhiteBalance ?? .factory
    app.store.updateProfile(for: d.profileKey) { $0.whiteBalance = original }
    app.color.restoreOriginal()
  }

  private func saveAndApply(_ wb: WhiteBalance) {
    guard let d = app.model.edgeState.display else { return }
    app.store.updateProfile(for: d.profileKey) { $0.whiteBalance = wb }
    app.color.apply(wb)
  }
}
