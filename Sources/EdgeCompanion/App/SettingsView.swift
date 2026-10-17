import AppKit
import EdgeCore
import SwiftUI

struct SettingsView: View {
  let app: AppDelegate
  @ObservedObject var store: SettingsStore
  @ObservedObject var model: AppModel
  @ObservedObject var touch: TouchController
  @ObservedObject var color: ColorService
  @ObservedObject var kiosk: KioskController

  var body: some View {
    TabView {
      GeneralTab(app: app, store: store, model: model)
        .tabItem { Label(tr("일반", "General"), systemImage: "gearshape") }
      TouchTab(app: app, store: store, touch: touch)
        .tabItem { Label(tr("터치", "Touch"), systemImage: "hand.point.up.left") }
      ColorTab(store: store, model: model, color: color)
        .tabItem { Label(tr("색상", "Color"), systemImage: "paintpalette") }
      DashboardTab(store: store)
        .tabItem { Label(tr("대시보드", "Dashboard"), systemImage: "rectangle.split.3x1") }
      DiagnosticsTab(model: model, touch: touch)
        .tabItem { Label(tr("진단", "Diagnostics"), systemImage: "stethoscope") }
    }
    .padding(20)
    .frame(width: 720, height: 720)
  }
}

// MARK: - General

private struct GeneralTab: View {
  let app: AppDelegate
  @ObservedObject var store: SettingsStore
  @ObservedObject var model: AppModel
  @State private var launchAtLogin = false

  var body: some View {
    Form {
      Section("XENEON EDGE") {
        LabeledContent(tr("상태", "Status"), value: edgeStatus)
        if let d = model.edgeState.display {
          LabeledContent(tr("시리얼", "Serial"), value: d.serial ?? tr("알 수 없음", "Unknown"))
          LabeledContent(tr("배치", "Arrangement"), value: "\(Int(d.bounds.minX)), \(Int(d.bounds.minY))  ·  \(Int(d.bounds.width))×\(Int(d.bounds.height)) pt")
        }
      }
      Section {
        Picker(tr("Edge 모드", "Edge mode"), selection: $store.settings.dashboardEnabled) {
          Text(tr("대시보드", "Dashboard")).tag(true)
          Text(tr("일반 모니터", "Regular display")).tag(false)
        }
        .pickerStyle(.segmented)
        Text(store.settings.dashboardEnabled
          ? tr("Edge를 대시보드 전용으로 써요.", "Uses the Edge as a dedicated dashboard.")
          : tr("Edge를 일반 모니터로 써요.", "Uses the Edge as a regular display."))
          .font(.caption).foregroundStyle(.secondary)
        if store.settings.dashboardEnabled {
          Toggle(tr("마우스 커서가 Edge로 못 들어가게", "Keep the mouse pointer off the Edge"), isOn: $store.settings.mouseFenceEnabled)
          Toggle(tr("Option 키를 누른 채 들어가면 나올 때까지 자유롭게", "Entering with Option held lets the pointer roam until it leaves"), isOn: $store.settings.fenceBypassWithOption)
            .disabled(!store.settings.mouseFenceEnabled)
            .padding(.leading, 18)
          Toggle(tr("Edge로 간 다른 앱 창을 메인 화면으로 옮기기", "Move other apps' windows off the Edge"), isOn: $store.settings.evictWindows)
        }
      }
      Section {
        Toggle(tr("Dock이 Edge로 가지 않게", "Keep the Dock off the Edge"), isOn: $store.settings.dockLockEnabled)
        Toggle(tr("연결될 때 2560×720 기본 해상도 유지", "Keep the native 2560×720 resolution on connect"), isOn: $store.settings.ensureNativeResolution)
      }
      Section(tr("권한", "Permissions")) {
        PermissionRow(title: tr("입력 모니터링", "Input Monitoring"), detail: tr("터치 장치를 읽는 데 필요해요", "Needed to read the touch controller"), granted: model.canListen) {
          Permissions.requestListen()
          Permissions.openInputMonitoringSettings()
        }
        PermissionRow(title: tr("손쉬운 사용", "Accessibility"), detail: tr("다른 앱 터치, 마우스 차단, 창 이동에 필요해요", "Needed for touching other apps, the pointer guard and moving windows"), granted: model.canPostEvents) {
          Permissions.requestAccessibility()
          Permissions.openAccessibilitySettings()
        }
      }
      Section {
        Toggle(tr("로그인 시 실행", "Launch at login"), isOn: Binding(get: { launchAtLogin }, set: { app.launchAtLogin = $0; launchAtLogin = app.launchAtLogin }))
        Picker(tr("언어", "Language"), selection: $store.settings.language) {
          Text(tr("시스템 설정", "System")).tag(AppLanguage.system)
          Text("English").tag(AppLanguage.en)
          Text("한국어").tag(AppLanguage.ko)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { launchAtLogin = app.launchAtLogin }
  }

  private var edgeStatus: String {
    switch model.edgeState {
    case .disconnected: return tr("연결 안 됨", "Not connected")
    case let .connected(d, _): return tr("연결됨", "Connected") + " · \(Int(d.pixelSize.width))×\(Int(d.pixelSize.height)) px"
    case .suspended: return tr("대기 중 (잠자기 또는 잠금)", "Idle (asleep or locked)")
    }
  }
}

private struct PermissionRow: View {
  let title: String
  let detail: String
  let granted: Bool
  let request: () -> Void

  var body: some View {
    HStack {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(granted ? .green : .orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !granted { Button(tr("허용하기…", "Allow…"), action: request) }
    }
  }
}

// MARK: - Touch

private struct TouchTab: View {
  let app: AppDelegate
  @ObservedObject var store: SettingsStore
  @ObservedObject var touch: TouchController

  var body: some View {
    Form {
      Section {
        Toggle(tr("터치 사용", "Enable touch"), isOn: $store.settings.touchEnabled)
        LabeledContent(tr("상태", "Status"), value: status)
        if touch.availability == .active || touch.reportRate > 0 {
          LabeledContent(tr("리포트 속도", "Report rate"), value: "\(Int(touch.reportRate)) Hz")
        }
        if let p = touch.lastTouchPoint {
          LabeledContent(tr("마지막 터치", "Last touch"), value: "\(Int(p.x)), \(Int(p.y))")
        }
        HStack {
          Button(tr("터치 테스트 열기", "Open touch test")) { app.openTouchTest() }
            .disabled(touch.availability != .active && touch.availability != .needsAccessibility)
          Button(tr("터치 장치 다시 연결", "Reconnect touch controller")) { app.reacquireTouch() }
        }
      }
      Section(tr("제스처", "Gestures")) {
        Toggle(tr("길게 누르면 우클릭", "Long press to right-click"), isOn: $store.settings.longPressRightClick)
        Toggle(tr("가로로 끌면 드래그 (슬라이더 조작용, 끄면 가로 스크롤)", "Horizontal drag presses (for sliders; off scrolls sideways)"), isOn: $store.settings.horizontalMoveDrags)
        Toggle(tr("관성 스크롤", "Momentum scrolling"), isOn: $store.settings.momentumScrolling)
        LabeledContent(tr("스크롤 속도", "Scroll speed")) {
          Slider(value: $store.settings.scrollSpeed, in: 0.5 ... 3, step: 0.1)
            .frame(width: 220)
          Text(String(format: "%.1f×", store.settings.scrollSpeed)).monospacedDigit().frame(width: 44)
        }
        Toggle(tr("다른 앱을 터치한 뒤 커서를 원래 자리로", "Return the cursor after touching other apps"), isOn: $store.settings.restoreCursorAfterTouch)
      }
      Section {
        Text(tr(
          "멀티터치는 macOS에서 패널 펌웨어가 켜 주지 않아서 지원하지 않아요. 대신 한 손가락으로 끌면 스크롤, 길게 누르면 우클릭이에요. 잠깐 누르고 있다가 끌면 드래그가 돼요.",
          "Multi-touch isn't available because the panel firmware doesn't enable it on macOS. Drag with one finger to scroll, long press to right-click, and hold briefly before moving to drag."
        ))
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var status: String {
    switch touch.availability {
    case .disabled: return tr("꺼짐", "Off")
    case .noDisplay: return tr("Edge 디스플레이 없음", "No Edge display")
    case .needsInputMonitoring: return tr("입력 모니터링 권한이 필요해요", "Needs Input Monitoring permission")
    case .needsAccessibility: return tr("대시보드만 터치 가능 (손쉬운 사용 권한 필요)", "Dashboard only (needs Accessibility permission)")
    case .busy: return tr("다른 앱이 터치 장치를 쓰고 있어요", "Another app is using the touch controller")
    case .waiting: return tr("장치를 기다리는 중", "Waiting for the device")
    case .active: return tr("동작 중", "Active")
    case let .failed(msg): return tr("오류", "Error") + ": \(msg)"
    }
  }
}

// MARK: - Color

private struct ColorTab: View {
  @ObservedObject var store: SettingsStore
  @ObservedObject var model: AppModel
  @ObservedObject var color: ColorService
  @State private var red = 50.0
  @State private var green = 41.0
  @State private var blue = 35.0

  var body: some View {
    Form {
      if let d = model.edgeState.display {
        Section(tr("패널 화이트 밸런스 (DDC 하드웨어 게인)", "Panel white balance (DDC hardware gains)")) {
          LabeledContent(tr("현재 패널 값", "Panel now"), value: panelText)
          gainSlider(tr("빨강", "Red"), $red, .red)
          gainSlider(tr("초록", "Green"), $green, .green)
          gainSlider(tr("파랑", "Blue"), $blue, .blue)
          HStack {
            Button(tr("적용", "Apply")) { save(d, WhiteBalance(red: Int(red), green: Int(green), blue: Int(blue))) }
              .keyboardShortcut(.defaultAction)
            Spacer()
            statusView
          }
        }
        Section(tr("프리셋", "Presets")) {
          HStack {
            Button("D65") { save(d, .tunedD65) }
            Button(tr("공장 초기값", "Factory")) {
              let original = store.profile(for: d.profileKey).originalWhiteBalance ?? .factory
              store.updateProfile(for: d.profileKey) { $0.whiteBalance = original }
              load(d)
              color.restoreOriginal()
            }
          }
          Toggle(tr("Edge가 연결될 때마다 이 값 적용", "Apply these values whenever the Edge connects"), isOn: Binding(
            get: { store.profile(for: d.profileKey).applyColorOnConnect },
            set: { v in store.updateProfile(for: d.profileKey) { $0.applyColorOnConnect = v } }
          ))
        }
      } else {
        Text(tr("XENEON EDGE가 연결되면 조절할 수 있어요.", "Available when the XENEON EDGE is connected.")).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      if let d = model.edgeState.display {
        load(d)
        color.syncFromPanel()
      }
    }
  }

  private var panelText: String {
    guard let b = color.panelBalance else { return tr("읽는 중…", "Reading…") }
    let preset = color.panelPreset.map { $0 == EdgeVCP.userPreset ? "User 1" : tr("프리셋", "Preset") + " \($0)" } ?? "?"
    return "R\(b.red) G\(b.green) B\(b.blue) · \(preset)"
  }

  @ViewBuilder private var statusView: some View {
    switch color.status {
    case .idle, .applied: EmptyView()
    case .working: ProgressView().controlSize(.small)
    case let .failed(msg): Label(msg, systemImage: "xmark.octagon").foregroundStyle(.red).lineLimit(1)
    }
  }

  private func gainSlider(_ title: String, _ value: Binding<Double>, _ tint: Color) -> some View {
    LabeledContent(title) {
      Slider(value: value, in: 0 ... 100, step: 1).tint(tint).frame(width: 300)
      Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 32, alignment: .trailing)
    }
  }

  private func load(_ d: EdgeDisplay) {
    let wb = store.profile(for: d.profileKey).whiteBalance
    red = Double(wb.red)
    green = Double(wb.green)
    blue = Double(wb.blue)
  }

  private func save(_ d: EdgeDisplay, _ wb: WhiteBalance) {
    store.updateProfile(for: d.profileKey) { $0.whiteBalance = wb }
    load(d)
    color.apply(wb)
  }
}

// MARK: - Dashboard

private struct DashboardTab: View {
  @ObservedObject var store: SettingsStore

  var body: some View {
    Form {
      Section(tr("터미널", "Terminal")) {
        Toggle(tr("터미널 표시", "Show terminal"), isOn: $store.settings.terminalEnabled)
        if store.settings.terminalEnabled {
          Picker(tr("위치", "Side"), selection: $store.settings.terminalSide) {
            Text(tr("왼쪽", "Left")).tag(TerminalSide.left)
            Text(tr("오른쪽", "Right")).tag(TerminalSide.right)
          }
          .pickerStyle(.segmented)
          LabeledContent(tr("너비", "Width")) {
            Slider(value: $store.settings.terminalWidth, in: 600 ... 1900, step: 20).frame(width: 260)
            Text("\(Int(store.settings.terminalWidth)) pt").monospacedDigit().frame(width: 64)
          }
          LabeledContent(tr("글자 크기", "Font size")) {
            Stepper(value: $store.settings.terminalFontSize, in: 10 ... 22, step: 1) {
              Text("\(Int(store.settings.terminalFontSize)) pt").monospacedDigit()
            }
          }
          Toggle(tr("tmux 세션으로 실행 (앱을 다시 켜도 작업 유지)", "Run inside tmux (work survives app restarts)"), isOn: $store.settings.terminalUseTmux)
          if store.settings.terminalUseTmux, TerminalSession.findTmux() != nil {
            LabeledContent(tr("다른 터미널에서 붙기", "Attach from another terminal")) {
              Text(TerminalSession.attachCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
          }
          if TerminalSession.findTmux() == nil {
            Text(tr("tmux가 설치돼 있지 않아서 일반 셸로 실행돼요. `brew install tmux`로 설치할 수 있어요.", "tmux isn't installed, so a plain shell runs. Install it with `brew install tmux`."))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section(tr("위젯 배치", "Widget layout")) {
        LayoutEditor(store: store)
      }
      UsageSection()
      WebPageSection(store: store)
      DiscordSection(store: store)
      Section(tr("런처", "Launcher")) {
        ForEach(store.settings.launcherItems) { item in
          HStack {
            Text(item.title)
            Text(item.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { store.settings.launcherItems.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
          }
        }
        Button(tr("앱 추가…", "Add app…")) { addApp() }
      }
    }
    .formStyle(.grouped)
  }


  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      let bundle = Bundle(url: url)
      let title = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
      store.settings.launcherItems.append(LauncherItem(title: title, target: bundle?.bundleIdentifier ?? url.path))
    }
  }
}

extension WidgetKind {
  var title: String {
    switch self {
    case .clock: return tr("시계", "Clock")
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .memory: return tr("메모리", "Memory")
    case .network: return tr("네트워크·디스크", "Network & disk")
    case .sensors: return tr("온도", "Thermals")
    case .battery: return tr("전원", "Power")
    case .launcher: return tr("런처", "Launcher")
    case .system: return tr("시스템", "System")
    case .aiUsage: return tr("AI 사용량", "AI usage")
    case .timer: return tr("타이머", "Timer")
    case .volume: return tr("볼륨", "Volume")
    case .sleep: return tr("잠자기", "Sleep")
    case .discord: return "Discord"
    case .web: return tr("웹페이지", "Web page")
    case .media: return tr("사진·영상", "Photo & video")
    case .spacer: return tr("빈 공간", "Empty space")
    }
  }
}

// MARK: - Web page widget

private struct WebPageSection: View {
  @ObservedObject var store: SettingsStore
  @State private var draft = ""

  var body: some View {
    Section(tr("웹페이지 위젯", "Web page widget")) {
      HStack {
        TextField(tr("주소", "Address"), text: $draft, prompt: Text("https://…"))
          .onSubmit(apply)
        Button(tr("적용", "Apply"), action: apply)
          .disabled(draft == store.settings.webURL)
      }
      if !draft.isEmpty, WebWidgetModel.url(from: draft) == nil {
        Text(tr("주소 형식이 올바르지 않아요", "That doesn't look like a web address")).font(.caption).foregroundStyle(.orange)
      }
      LabeledContent(tr("확대", "Zoom")) {
        Slider(value: $store.settings.webZoom, in: 0.5 ... 1.5, step: 0.05).frame(width: 260)
        Text("\(Int((store.settings.webZoom * 100).rounded()))%").monospacedDigit().frame(width: 48)
      }
      HStack {
        Text(tr("메인 화면에서 창을 엽니다 (로그인이 필요한 경우 사용)", "Opens a window on the main display (use it when you need to sign in)"))
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(tr("확인하기", "Open")) { WebLoginWindow.shared.show(store.settings.webURL) }
          .disabled(WebWidgetModel.url(from: store.settings.webURL) == nil)
        Button(tr("새로고침", "Reload")) { WebWidgetModel.shared.reload() }
          .disabled(WebWidgetModel.url(from: store.settings.webURL) == nil)
      }
    }
    .onAppear { draft = store.settings.webURL }
  }

  private func apply() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty || WebWidgetModel.url(from: trimmed) != nil else { return }
    draft = trimmed
    store.settings.webURL = trimmed
  }
}

// MARK: - Discord

/// Basic mode needs nothing. Linking the user's own Discord application (RPC is only open to an
/// app's own testers) adds the channel, members, speaking and Discord's mute controls.
private struct DiscordSection: View {
  @ObservedObject var store: SettingsStore
  @ObservedObject private var discord = DiscordController.shared
  @State private var clientID = ""
  @State private var secret = ""
  @State private var showSteps = false

  var body: some View {
    Section("Discord") {
      Text(tr("설정 없이도 Discord가 마이크를 쓰면 통화 중으로 표시해요. 아래에서 연결하면 채널, 참여자, 말하는 사람을 보여 주고 음소거, 헤드셋 음소거, 나가기를 다룰 수 있어요.",
              "Without setup, the widget shows a call whenever Discord uses the microphone. Link below to see the channel, members and who is speaking, and to mute, deafen or leave."))
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent(tr("상태", "Status")) { Text(status).foregroundStyle(statusColor) }
      if discord.linked {
        HStack {
          Spacer()
          Button(tr("연결 해제", "Unlink")) { discord.unlink() }
        }
      } else {
        DisclosureGroup(tr("연결 방법", "How to link"), isExpanded: $showSteps) {
          VStack(alignment: .leading, spacing: 10) {
            step(1, tr("Discord 개발자 페이지에서 New Application을 눌러 앱을 만들어요. 이름은 아무거나 괜찮아요.",
                       "On the Discord developer portal, click New Application. Any name works."))
            HStack {
              Spacer()
              Button(tr("개발자 페이지 열기", "Open developer portal")) {
                NSWorkspace.shared.open(URL(string: "https://discord.com/developers/applications")!)
              }
            }
            step(2, tr("왼쪽 OAuth2 메뉴의 Redirects에 아래 주소를 추가하고 저장해요.",
                       "Under OAuth2 → Redirects, add the address below and save."))
            HStack {
              Text(DiscordController.redirectURI).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
              Spacer()
              Button(tr("복사", "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DiscordController.redirectURI, forType: .string)
              }
            }
            step(3, tr("같은 화면에서 Client ID를 복사하고, Reset Secret을 눌러 Client Secret을 복사해요.",
                       "On the same page, copy the Client ID, then click Reset Secret and copy the Client Secret."))
            credentialField("Client ID") {
              TextField("", text: $clientID, prompt: Text(tr("숫자로 된 ID", "A numeric ID")))
            }
            credentialField("Client Secret") {
              SecureField("", text: $secret, prompt: Text(discord.hasCredentials ? tr("저장됨 · 바꿀 때만 입력", "Saved · enter only to change") : tr("Reset Secret으로 받은 값", "From Reset Secret")))
            }
            step(4, tr("연결을 누르면 Discord 앱에 승인 창이 떠요. 승인하면 끝이에요.",
                       "Click Link and approve the prompt in the Discord app."))
            Text(tr("Client Secret과 토큰은 로그인 키체인에 저장돼요. macOS가 EdgeCompanion의 키체인 접근을 물으면 \"항상 허용\"을 눌러 주세요. 그러면 다음부터는 묻지 않아요.",
                    "The Client Secret and tokens are kept in the login keychain. If macOS asks whether EdgeCompanion may use it, click \"Always Allow\" so it won't ask again."))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              Spacer()
              Button(tr("연결", "Link")) {
                discord.link(clientID: clientID, secret: secret)
                secret = ""
              }
              .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || (secret.isEmpty && !discord.hasCredentials) || !discord.running)
            }
            if !discord.running {
              Text(tr("Discord 앱을 먼저 켜 주세요.", "Open the Discord app first."))
                .font(.caption).foregroundStyle(.orange)
            }
          }
          .padding(.top, 6)
        }
      }
    }
    .onAppear {
      clientID = store.settings.discordClientID
      discord.retain()
    }
    .onDisappear { discord.release() }
  }

  /// A labelled, bordered field so the keys stand apart from the instructions around them.
  private func credentialField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.callout.weight(.medium))
        .frame(width: 96, alignment: .leading)
      field()
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .labelsHidden()
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(n)").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 14)
      Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var status: String {
    switch discord.link {
    case .off: return tr("기본 모드 (연결 안 됨)", "Basic (not linked)")
    case .connecting: return tr("연결하는 중…", "Connecting…")
    case .authorizing: return tr("Discord 앱에서 승인을 기다리는 중", "Waiting for approval in Discord")
    case let .ready(user): return user.isEmpty ? tr("연결됨", "Linked") : tr("연결됨 · \(user)", "Linked · \(user)")
    case let .failed(message): return tr("연결 실패: \(message)", "Failed: \(message)")
    }
  }

  private var statusColor: Color {
    switch discord.link {
    case .ready: return .green
    case .failed: return .orange
    default: return .secondary
    }
  }
}

// MARK: - Diagnostics

private struct DiagnosticsTab: View {
  @ObservedObject var model: AppModel
  @ObservedObject var touch: TouchController
  @State private var lines: [String] = Log.recentLines()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(tr("최근 로그", "Recent log")).font(.headline)
        Spacer()
        Button(tr("새로고침", "Refresh")) { lines = Log.recentLines() }
        Button(tr("복사", "Copy")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
      }
      ScrollView {
        Text(lines.joined(separator: "\n"))
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }
}

// MARK: - Usage connections

private struct UsageSection: View {
  @State private var claudeConnected = ClaudeStatusLine.isConnected
  @State private var message: String?

  var body: some View {
    Section(tr("사용량", "Usage limits")) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Claude Code")
          Text(claudeConnected
            ? tr("연결됨 · 응답할 때마다 상태줄이 사용량을 전해 줘요", "Connected · the status line reports usage after each reply")
            : tr("Claude Code 상태줄에 이 앱을 연결해요 (~/.claude/settings.json을 백업한 뒤 다시 저장해요)", "Adds this app as Claude Code's status line (~/.claude/settings.json is backed up, then rewritten)"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(claudeConnected ? tr("연결 해제", "Disconnect") : tr("연결", "Connect")) { toggleClaude() }
      }
      if let message { Text(message).font(.caption).foregroundStyle(.orange) }
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Codex")
          Text(CodexUsage.findBinary().map { tr("Codex CLI로 실시간 조회", "Live via the Codex CLI") + " · \($0)" } ?? tr("Codex CLI를 찾지 못했어요. 마지막 세션 기록을 보여 줘요.", "Codex CLI not found; showing the last session log."))
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer()
      }
    }
  }

  private func toggleClaude() {
    message = nil
    do {
      if claudeConnected { try ClaudeStatusLine.disconnect() } else { try ClaudeStatusLine.connect() }
    } catch ClaudeStatusLine.ConnectError.notInstalled {
      message = tr("Applications 폴더에 설치된 앱에서만 연결할 수 있어요 (scripts/build-app.sh --install).", "Connect from the app installed in Applications (scripts/build-app.sh --install).")
    } catch ClaudeStatusLine.ConnectError.otherStatusLine(let command) {
      message = tr("이미 다른 상태줄이 설정돼 있어서 바꾸지 않았어요: ", "A different status line is already set, so nothing was changed: ") + command
    } catch {
      message = "\(error)"
    }
    claudeConnected = ClaudeStatusLine.isConnected
    Task { @MainActor in UsageService.shared.reloadClaude() }
  }
}
