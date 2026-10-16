import Foundation

/// Codex rate limits through the Codex CLI's `app-server` (newline-delimited JSON-RPC over stdio):
/// `initialize` → `initialized` → `account/rateLimits/read`. Codex performs the authenticated
/// request itself, so this app never reads `~/.codex/auth.json`. Falls back to the `rate_limits`
/// record in the newest session log when the CLI is missing or the query fails.
enum CodexUsage {
  struct FetchError: Error {
    var message: String
  }

  static var codexHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }

  /// The Codex CLI: on PATH, or the copy bundled in the ChatGPT / Codex desktop apps.
  static func findBinary() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
      "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
      "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  static func fetch() -> Result<UsageSnapshot, FetchError> {
    if let binary = findBinary(), let live = queryAppServer(binary) {
      return .success(live)
    }
    if let logged = latestLoggedLimits() {
      return .success(logged)
    }
    return .failure(FetchError(message: findBinary() == nil
      ? tr("Codex를 찾지 못했어요", "Codex not found")
      : tr("Codex 사용량을 읽지 못했어요", "Couldn't read Codex usage")))
  }

  // MARK: app-server

  private static func queryAppServer(_ binary: String) -> UsageSnapshot? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["app-server"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    defer {
      if process.isRunning { process.terminate() }
    }

    func send(_ object: [String: Any]) {
      guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
      data.append(0x0A)
      try? input.fileHandleForWriting.write(contentsOf: data)
    }

    let reader = LineReader(handle: output.fileHandleForReading, process: process)
    send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "edgecompanion", "version": "0.1"]]])
    guard reader.waitFor(id: 1, timeout: 6) != nil else { return nil }
    send(["method": "initialized"])
    // Replies sent too soon after the handshake can come back empty.
    usleep(400_000)
    send(["id": 2, "method": "account/rateLimits/read"])
    guard let reply = reader.waitFor(id: 2, timeout: 8),
          let result = reply["result"] as? [String: Any],
          let limits = result["rateLimits"] as? [String: Any] else { return nil }

    func window(_ key: String) -> UsageWindow? {
      guard let w = limits[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
      let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
      return UsageWindow(usedPercent: used, resetsAt: resets)
    }
    return UsageSnapshot(fiveHour: window("primary"), weekly: window("secondary"), updatedAt: Date(), plan: limits["planType"] as? String)
  }

  /// Reads newline-delimited JSON from a pipe until a reply with the wanted id shows up.
  private final class LineReader {
    private let handle: FileHandle
    private let process: Process
    private var buffer = Data()

    init(handle: FileHandle, process: Process) {
      self.handle = handle
      self.process = process
    }

    func waitFor(id: Int, timeout: TimeInterval) -> [String: Any]? {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        while let newline = buffer.firstIndex(of: 0x0A) {
          let line = buffer[buffer.startIndex ..< newline]
          buffer.removeSubrange(buffer.startIndex ... newline)
          if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], (obj["id"] as? Int) == id {
            return obj
          }
        }
        let chunk = handle.availableDataNonBlocking(waitingUpTo: min(0.5, deadline.timeIntervalSinceNow))
        if chunk.isEmpty {
          // Nothing more will arrive once the child is gone; don't spin until the deadline.
          if !process.isRunning { return nil }
          continue
        }
        buffer.append(chunk)
      }
      return nil
    }
  }

  // MARK: Session logs

  /// Newest session log modification time: a cheap signal that Codex was just used.
  static func latestActivity() -> Date? {
    newestSessionLog()?.modified
  }

  private static func newestSessionLog() -> (url: URL, modified: Date)? {
    let fm = FileManager.default
    let calendar = Calendar.current
    // Session logs live in sessions/YYYY/MM/DD; today's and yesterday's folders are enough.
    var newest: (URL, Date)?
    for dayOffset in 0 ... 1 {
      guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
      let c = calendar.dateComponents([.year, .month, .day], from: day)
      let dir = codexHome.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
      guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
      for f in files where f.pathExtension == "jsonl" {
        guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
        if newest == nil || m > newest!.1 { newest = (f, m) }
      }
    }
    return newest.map { (url: $0.0, modified: $0.1) }
  }

  /// The last `rate_limits` record in the newest session log (snapshot at Codex's last request).
  private static func latestLoggedLimits() -> UsageSnapshot? {
    guard let log = newestSessionLog(), let handle = try? FileHandle(forReadingFrom: log.url) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
      guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let limits = findRateLimits(obj) else { continue }
      func window(_ key: String) -> UsageWindow? {
        guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: used, resetsAt: resets)
      }
      return UsageSnapshot(fiveHour: window("primary"), weekly: window("secondary"), updatedAt: log.modified, plan: nil, fromLog: true)
    }
    return nil
  }

  private static func findRateLimits(_ value: Any) -> [String: Any]? {
    if let dict = value as? [String: Any] {
      if let limits = dict["rate_limits"] as? [String: Any] { return limits }
      for v in dict.values { if let found = findRateLimits(v) { return found } }
    }
    return nil
  }
}

private extension FileHandle {
  /// Reads whatever is available within `seconds` without blocking forever.
  func availableDataNonBlocking(waitingUpTo seconds: TimeInterval) -> Data {
    var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, Int32(max(seconds, 0) * 1000))
    guard ready > 0 else { return Data() }
    return availableData
  }
}
