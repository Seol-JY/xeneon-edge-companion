import AppKit
import CoreAudio

/// What the Discord widget shows. Without any setup it knows whether Discord is running and whether
/// it is using the microphone (on a call). Linked to the user's
/// own Discord application over the local RPC socket, it also knows the voice channel, who is in
/// it and speaking, and controls Discord's own mute and deafen.
final class DiscordController: ObservableObject {
  static let shared = DiscordController()
  static let bundleID = "com.hnc.Discord"

  enum Link: Equatable {
    /// No client ID and secret yet: basic mode.
    case off
    case connecting
    /// Connected but waiting for the user to approve access in Discord.
    case authorizing
    case ready(user: String)
    case failed(String)
  }

  struct Member: Identifiable, Equatable {
    let id: String
    var name: String
    var avatar: URL?
    var muted: Bool
    var deafened: Bool
  }

  struct Call: Equatable {
    var channelID: String
    var name: String
    var guildName: String?
    var members: [Member]
  }

  @Published private(set) var running = false
  /// Discord is capturing from the microphone, which it does only on a call.
  @Published private(set) var micInUse = false
  @Published private(set) var link: Link = .off
  @Published private(set) var call: Call?
  @Published private(set) var speaking: Set<String> = []
  @Published private(set) var selfMute = false
  @Published private(set) var selfDeaf = false
  @Published private(set) var avatars: [String: NSImage] = [:]
  /// When the current call was first seen, for the elapsed time.
  @Published private(set) var callStart: Date?

  var linked: Bool { if case .ready = link { return true } else { return false } }
  var inCall: Bool { linked ? call != nil : micInUse }

  private var users = 0
  private var poll: Timer?
  private var retry: Timer?
  private let ipc = DiscordIPC()
  private var pending: [String: ([String: Any]?, String?) -> Void] = [:]
  private var subscribedChannel: String?
  private var authorizeRequested = false
  private var observers: [NSObjectProtocol] = []

  private static let scopes = ["rpc", "rpc.voice.read", "rpc.voice.write"]
  /// Discord insists on a registered redirect URI even though nothing is redirected.
  static let redirectURI = "http://localhost"

  init() {
    ipc.onMessage = { [weak self] in self?.handle($0) }
    ipc.onClose = { [weak self] reason in self?.closed(reason) }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
        self?.refreshRunning()
      })
    }
  }

  // MARK: Lifecycle

  /// The widget holds this while it is on screen; polling and the RPC link only run meanwhile.
  func retain() {
    users += 1
    guard users == 1 else { return }
    refreshRunning()
    refreshAudio()
    let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAudio() }
    t.tolerance = 0.5
    RunLoop.main.add(t, forMode: .common)
    poll = t
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    poll?.invalidate()
    poll = nil
  }

  var clientID: String { SettingsStore.shared.settings.discordClientID.trimmingCharacters(in: .whitespaces) }
  var hasCredentials: Bool { !clientID.isEmpty && DiscordKeychain.get("clientSecret") != nil }
  /// Credentials plus either a saved token or a pending request to approve one.
  private var canLink: Bool { hasCredentials && (Token.load() != nil || authorizeRequested) }

  /// From Settings: saves the credentials and asks Discord for access.
  func link(clientID: String, secret: String) {
    SettingsStore.shared.settings.discordClientID = clientID.trimmingCharacters(in: .whitespaces)
    if !secret.isEmpty { DiscordKeychain.set(secret.trimmingCharacters(in: .whitespaces), for: "clientSecret") }
    DiscordKeychain.set(nil, for: "token")
    authorizeRequested = true
    reconnect()
  }

  func unlink() {
    DiscordKeychain.set(nil, for: "token")
    DiscordKeychain.set(nil, for: "clientSecret")
    authorizeRequested = false
    ipc.close()
    resetCall()
    link = .off
  }

  private func refreshRunning() {
    let now = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    if now != running { running = now }
    if !hasCredentials { link = .off }
    if now {
      // Give a freshly launched client a moment to open its socket.
      if canLink, !ipc.isOpen { scheduleReconnect(after: 3) }
    } else {
      ipc.close()
      resetCall()
      if hasCredentials, link != .off { link = .connecting }
    }
  }

  // MARK: Basic mode: is Discord recording?

  private func refreshAudio() {
    let inUse = Self.discordCapturing()
    if inUse != micInUse {
      micInUse = inUse
      if !linked { callStart = inUse ? Date() : nil }
    }
    // A client that started after us, or a link that dropped, is picked up here.
    if running, !ipc.isOpen, retry == nil, canLink { reconnect() }
  }

  /// Uses the per-process audio objects (macOS 14.2+) to see whether any Discord process records.
  private static func discordCapturing() -> Bool {
    guard #available(macOS 14.2, *) else { return false }
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
    for id in ids {
      var bundleAddr = address(kAudioProcessPropertyBundleID)
      var bundle: Unmanaged<CFString>?
      var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard AudioObjectGetPropertyData(id, &bundleAddr, 0, nil, &bundleSize, &bundle) == noErr,
            let name = bundle?.takeRetainedValue() as String?, name.hasPrefix(bundleID) else { continue }
      var inputAddr = address(kAudioProcessPropertyIsRunningInput)
      var running: UInt32 = 0
      var runningSize = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(id, &inputAddr, 0, nil, &runningSize, &running) == noErr, running != 0 { return true }
    }
    return false
  }

  private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  // MARK: Linked mode: RPC

  private func scheduleReconnect(after delay: TimeInterval) {
    retry?.invalidate()
    let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      self?.retry = nil
      self?.reconnect()
    }
    RunLoop.main.add(t, forMode: .common)
    retry = t
  }

  private func reconnect() {
    guard hasCredentials else {
      link = .off
      return
    }
    guard running else {
      link = .connecting
      return
    }
    link = .connecting
    if !ipc.connect(clientID: clientID) {
      link = .failed(tr("Discord에 연결하지 못했어요", "Couldn't reach Discord"))
      scheduleReconnect(after: 10)
    }
  }

  private func closed(_ reason: String?) {
    pending.removeAll()
    resetCall()
    guard hasCredentials else { return }
    if let reason, !reason.isEmpty {
      Log.info(.dashboard, "discord: closed (\(reason))")
      link = .failed(reason)
    } else if link != .off {
      link = .connecting
    }
    if running, users > 0 || authorizeRequested { scheduleReconnect(after: 5) }
  }

  private func command(_ cmd: String, _ args: [String: Any] = [:], evt: String? = nil, done: (([String: Any]?, String?) -> Void)? = nil) {
    let nonce = UUID().uuidString
    var payload: [String: Any] = ["cmd": cmd, "args": args, "nonce": nonce]
    if let evt { payload["evt"] = evt }
    if let done { pending[nonce] = done }
    ipc.send(.frame, payload)
  }

  private func handle(_ message: [String: Any]) {
    let cmd = message["cmd"] as? String
    let evt = message["evt"] as? String
    let data = message["data"] as? [String: Any]
    if let nonce = message["nonce"] as? String, let done = pending.removeValue(forKey: nonce) {
      done(evt == "ERROR" ? nil : data, evt == "ERROR" ? (data?["message"] as? String ?? "error") : nil)
      return
    }
    guard cmd == "DISPATCH" else { return }
    switch evt {
    case "READY": ready()
    case "VOICE_CHANNEL_SELECT": loadSelectedChannel()
    case "VOICE_SETTINGS_UPDATE": applySettings(data)
    case "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE": if let data { upsert(data) }
    case "VOICE_STATE_DELETE":
      if let id = (data?["user"] as? [String: Any])?["id"] as? String { call?.members.removeAll { $0.id == id } }
    case "SPEAKING_START": if let id = data?["user_id"] as? String { speaking.insert(id) }
    case "SPEAKING_STOP": if let id = data?["user_id"] as? String { speaking.remove(id) }
    default: break
    }
  }

  private func ready() {
    if let token = Token.load(), token.expires > Date().addingTimeInterval(60) {
      authenticate(token)
    } else if let token = Token.load() {
      exchange(["grant_type": "refresh_token", "refresh_token": token.refresh])
    } else if authorizeRequested {
      authorize()
    } else {
      link = .failed(tr("설정에서 다시 연결해 주세요", "Connect again in Settings"))
    }
  }

  private func authorize() {
    link = .authorizing
    // The redirect must be registered on the application, but AUTHORIZE itself refuses one; only
    // the token exchange names it.
    command("AUTHORIZE", ["client_id": clientID, "scopes": Self.scopes]) { [weak self] data, error in
      guard let self else { return }
      self.authorizeRequested = false
      guard let code = data?["code"] as? String else {
        Log.info(.dashboard, "discord: authorize failed: \(error ?? "no code")")
        self.link = .failed(error ?? tr("승인하지 않았어요", "Not approved"))
        return
      }
      self.exchange(["grant_type": "authorization_code", "code": code])
    }
  }

  /// Trades an authorization code or refresh token for an access token at discord.com.
  private func exchange(_ fields: [String: String]) {
    guard let secret = DiscordKeychain.get("clientSecret") else { return }
    var body = fields
    body["client_id"] = clientID
    body["client_secret"] = secret
    body["redirect_uri"] = Self.redirectURI
    var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var form = URLComponents()
    form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
      DispatchQueue.main.async {
        guard let self else { return }
        guard let json, let access = json["access_token"] as? String else {
          let message = (json?["error_description"] as? String) ?? (json?["error"] as? String) ?? tr("토큰을 받지 못했어요", "Couldn't get a token")
          Log.info(.dashboard, "discord: token exchange failed: \(message)")
          DiscordKeychain.set(nil, for: "token")
          self.link = .failed(message)
          return
        }
        let token = Token(access: access, refresh: json["refresh_token"] as? String ?? "",
                          expires: Date().addingTimeInterval(json["expires_in"] as? Double ?? 604_800))
        token.save()
        self.authenticate(token)
      }
    }.resume()
  }

  private func authenticate(_ token: Token) {
    command("AUTHENTICATE", ["access_token": token.access]) { [weak self] data, error in
      guard let self else { return }
      guard let data, let user = data["user"] as? [String: Any] else {
        DiscordKeychain.set(nil, for: "token")
        self.link = .failed(error ?? tr("인증하지 못했어요", "Couldn't sign in"))
        return
      }
      self.link = .ready(user: user["global_name"] as? String ?? user["username"] as? String ?? "")
      Log.info(.dashboard, "discord: linked")
      self.command("SUBSCRIBE", evt: "VOICE_CHANNEL_SELECT")
      self.command("SUBSCRIBE", evt: "VOICE_SETTINGS_UPDATE")
      self.command("GET_VOICE_SETTINGS") { [weak self] data, _ in self?.applySettings(data) }
      self.loadSelectedChannel()
    }
  }

  private func applySettings(_ data: [String: Any]?) {
    guard let data else { return }
    if let mute = data["mute"] as? Bool { selfMute = mute }
    if let deaf = data["deaf"] as? Bool { selfDeaf = deaf }
  }

  private func loadSelectedChannel() {
    command("GET_SELECTED_VOICE_CHANNEL") { [weak self] data, _ in
      guard let self else { return }
      guard let data, let id = data["id"] as? String else {
        self.resetCall()
        return
      }
      if self.subscribedChannel != id { self.subscribe(to: id) }
      if self.call?.channelID != id { self.callStart = Date() }
      let states = data["voice_states"] as? [[String: Any]] ?? []
      self.call = Call(channelID: id, name: data["name"] as? String ?? "", guildName: self.call?.channelID == id ? self.call?.guildName : nil,
                       members: states.compactMap(Self.member))
      self.call?.members.forEach { self.loadAvatar($0) }
      if let guild = data["guild_id"] as? String {
        self.command("GET_GUILD", ["guild_id": guild]) { [weak self] data, _ in
          guard let self, self.call?.channelID == id else { return }
          self.call?.guildName = data?["name"] as? String
        }
      }
    }
  }

  private func subscribe(to channel: String) {
    let events = ["VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE", "SPEAKING_START", "SPEAKING_STOP"]
    if let old = subscribedChannel {
      for e in events { command("UNSUBSCRIBE", ["channel_id": old], evt: e) }
    }
    for e in events { command("SUBSCRIBE", ["channel_id": channel], evt: e) }
    subscribedChannel = channel
    speaking = []
  }

  private func resetCall() {
    if let old = subscribedChannel, ipc.isOpen {
      for e in ["VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE", "SPEAKING_START", "SPEAKING_STOP"] {
        command("UNSUBSCRIBE", ["channel_id": old], evt: e)
      }
    }
    subscribedChannel = nil
    call = nil
    speaking = []
    if linked || !micInUse { callStart = nil }
  }

  private func upsert(_ state: [String: Any]) {
    guard let member = Self.member(state) else { return }
    if let i = call?.members.firstIndex(where: { $0.id == member.id }) {
      call?.members[i] = member
    } else {
      call?.members.append(member)
      loadAvatar(member)
    }
  }

  private static func member(_ state: [String: Any]) -> Member? {
    guard let user = state["user"] as? [String: Any], let id = user["id"] as? String else { return nil }
    let voice = state["voice_state"] as? [String: Any] ?? [:]
    let name = (state["nick"] as? String) ?? (user["global_name"] as? String) ?? (user["username"] as? String) ?? ""
    let avatar: URL?
    if let hash = user["avatar"] as? String {
      avatar = URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(hash).png?size=128")
    } else {
      avatar = URL(string: "https://cdn.discordapp.com/embed/avatars/\(((UInt64(id) ?? 0) >> 22) % 6).png")
    }
    let muted = (voice["self_mute"] as? Bool ?? false) || (voice["mute"] as? Bool ?? false) || (state["mute"] as? Bool ?? false)
    let deafened = (voice["self_deaf"] as? Bool ?? false) || (voice["deaf"] as? Bool ?? false)
    return Member(id: id, name: name, avatar: avatar, muted: muted, deafened: deafened)
  }

  private func loadAvatar(_ member: Member) {
    guard avatars[member.id] == nil, let url = member.avatar else { return }
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let image = NSImage(data: data) else { return }
      DispatchQueue.main.async { self?.avatars[member.id] = image }
    }.resume()
  }

  // MARK: Controls

  /// Like Discord's own button: while deafened, the microphone counts as muted, and unmuting it
  /// undeafens as well.
  func toggleMute() {
    guard linked else { return }
    let args: [String: Any] = selfDeaf ? ["mute": false, "deaf": false] : ["mute": !selfMute]
    command("SET_VOICE_SETTINGS", args) { [weak self] data, _ in self?.applySettings(data) }
  }

  func toggleDeaf() {
    guard linked else { return }
    command("SET_VOICE_SETTINGS", ["deaf": !selfDeaf]) { [weak self] data, _ in self?.applySettings(data) }
  }

  func leave() {
    guard linked else { return }
    command("SELECT_VOICE_CHANNEL", ["channel_id": NSNull()]) { [weak self] _, _ in self?.resetCall() }
  }

  func openDiscord() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }

  // MARK: Tokens

  private struct Token: Codable {
    var access: String
    var refresh: String
    var expires: Date

    static func load() -> Token? {
      DiscordKeychain.get("token").flatMap { try? JSONDecoder().decode(Token.self, from: Data($0.utf8)) }
    }

    func save() {
      guard let data = try? JSONEncoder().encode(self) else { return }
      DiscordKeychain.set(String(data: data, encoding: .utf8), for: "token")
    }
  }
}
