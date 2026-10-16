import Combine
import Foundation

/// One rate-limit window: how much is used and when it resets.
struct UsageWindow: Codable, Equatable {
  var usedPercent: Double
  var resetsAt: Date?

  /// A window whose reset time has passed is empty again, even before fresh data arrives.
  func current(at now: Date = Date()) -> UsageWindow {
    if let resetsAt, resetsAt <= now { return UsageWindow(usedPercent: 0, resetsAt: nil) }
    return self
  }
}

struct UsageSnapshot: Codable, Equatable {
  var fiveHour: UsageWindow?
  var weekly: UsageWindow?
  var updatedAt: Date
  var plan: String?
  /// True when the values come from Codex's last session log rather than a live query.
  var fromLog = false
}

enum UsageState: Equatable {
  case unavailable(String)
  case waiting
  case ready(UsageSnapshot)
}

/// Claude Code and Codex usage limits for the dashboard, without handling any credentials:
/// - Claude: Claude Code hands `rate_limits` to its status line command; ours stores just those
///   numbers in a file this service watches (official, offline). See `ClaudeStatusLine`.
/// - Codex: the Codex CLI's own `app-server` answers `account/rateLimits/read`; it does the
///   authenticated request itself. See `CodexUsage`.
@MainActor
final class UsageService: ObservableObject {
  static let shared = UsageService()

  @Published private(set) var claude: UsageState = .waiting
  @Published private(set) var codex: UsageState = .waiting
  /// Ticks once a minute so reset countdowns and expired windows refresh.
  @Published private(set) var now = Date()

  private var users = 0
  private var claudeWatcher: DispatchSourceFileSystemObject?
  private var minuteTimer: Timer?
  private var codexTimer: Timer?
  private var codexQuerying = false
  private var lastCodexQuery = Date.distantPast
  private var lastCodexActivity: Date?

  /// The usage widget calls this on appear/disappear; watchers run only while it is shown.
  func retain(_ kind: WidgetKind) {
    guard kind == .aiUsage else { return }
    users += 1
    guard users == 1 else { return }
    startClaude()
    startCodex()
    startMinuteTimer()
  }

  func release(_ kind: WidgetKind) {
    guard kind == .aiUsage else { return }
    users = max(0, users - 1)
    guard users == 0 else { return }
    claudeWatcher?.cancel()
    claudeWatcher = nil
    codexTimer?.invalidate()
    codexTimer = nil
    minuteTimer?.invalidate()
    minuteTimer = nil
  }

  private func startMinuteTimer() {
    guard minuteTimer == nil else { return }
    let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.now = Date() }
    }
    t.tolerance = 10
    RunLoop.main.add(t, forMode: .common)
    minuteTimer = t
  }

  // MARK: Claude

  private func startClaude() {
    reloadClaude()
    let dir = ClaudeStatusLine.storeURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // The file is replaced atomically, so watch the folder rather than the file itself.
    let fd = open(dir.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.reloadClaude() }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    claudeWatcher = source
  }

  func reloadClaude() {
    if let snapshot = ClaudeStatusLine.readStore() {
      claude = .ready(snapshot)
    } else if ClaudeStatusLine.isConnected {
      claude = .unavailable(tr("Claude Code를 한 번 사용하면 표시돼요", "Shows after your next Claude Code reply"))
    } else {
      claude = .unavailable(tr("설정 → 대시보드에서 Claude Code를 연결하세요", "Connect Claude Code in Settings → Dashboard"))
    }
  }

  // MARK: Codex

  private func startCodex() {
    queryCodex()
    let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.codexTick() }
    }
    t.tolerance = 5
    RunLoop.main.add(t, forMode: .common)
    codexTimer = t
  }

  /// Every 30 s: re-query after fresh Codex activity (a session log changed), or every 2 minutes.
  private func codexTick() {
    let activity = CodexUsage.latestActivity()
    let sinceQuery = Date().timeIntervalSince(lastCodexQuery)
    if let activity, activity > lastCodexQuery, activity != lastCodexActivity, sinceQuery > 20 {
      lastCodexActivity = activity
      queryCodex()
    } else if sinceQuery >= 120 {
      queryCodex()
    }
  }

  func queryCodex() {
    guard !codexQuerying else { return }
    codexQuerying = true
    lastCodexQuery = Date()
    Task.detached(priority: .utility) {
      let result = CodexUsage.fetch()
      await MainActor.run {
        self.codexQuerying = false
        switch result {
        case let .success(snapshot): self.codex = .ready(snapshot)
        case let .failure(error):
          if case .ready = self.codex { return } // keep the last good value through a hiccup
          self.codex = .unavailable(error.message)
        }
      }
    }
  }
}
