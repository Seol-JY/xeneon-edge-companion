import Foundation

/// Claude Code's status line integration.
///
/// Claude Code (2.1.80+) runs the configured status line command after each reply and passes a JSON
/// document on stdin that includes `rate_limits.five_hour` / `seven_day` (`used_percentage`,
/// `resets_at`). Running this app's binary with `--claude-statusline` keeps only those numbers in a
/// small file and prints a short summary for Claude Code's own status line. No tokens, no network.
enum ClaudeStatusLine {
  static let flag = "--claude-statusline"

  static var storeURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/EdgeCompanion/claude-usage.json")
  }

  static var settingsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }

  // MARK: Status line command (runs inside Claude Code, must be quick and never fail loudly)

  static func runCommand() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let limits = root["rate_limits"] as? [String: Any] else {
      print("")
      return
    }
    func window(_ key: String) -> UsageWindow? {
      guard let w = limits[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
      let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
      return UsageWindow(usedPercent: used, resetsAt: resets)
    }
    let snapshot = UsageSnapshot(fiveHour: window("five_hour"), weekly: window("seven_day"), updatedAt: Date(), plan: nil)
    if snapshot.fiveHour != nil || snapshot.weekly != nil {
      writeStore(snapshot)
    }
    var parts: [String] = []
    if let f = snapshot.fiveHour { parts.append("5h \(Int(f.usedPercent.rounded()))%") }
    if let w = snapshot.weekly { parts.append("7d \(Int(w.usedPercent.rounded()))%") }
    print(parts.joined(separator: " · "))
  }

  private static func writeStore(_ snapshot: UsageSnapshot) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    guard let data = try? encoder.encode(snapshot) else { return }
    let url = storeURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: [.atomic])
  }

  static func readStore() -> UsageSnapshot? {
    guard let data = try? Data(contentsOf: storeURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(UsageSnapshot.self, from: data)
  }

  // MARK: Connecting (edits ~/.claude/settings.json only when the user asks)

  enum ConnectError: Error {
    case otherStatusLine(String)
    case notInstalled
    case unreadable
    case writeFailed(String)
  }

  /// The status line command points at this binary, so only connect from a lasting location.
  static var isRunningFromApplications: Bool {
    let path = Bundle.main.bundlePath
    return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
  }

  static var commandLine: String {
    let path = Bundle.main.executablePath ?? "/Applications/EdgeCompanion.app/Contents/MacOS/EdgeCompanion"
    return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' \(flag)"
  }

  private static func loadSettings() throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
    let data = try Data(contentsOf: settingsURL)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectError.unreadable }
    return obj
  }

  static var isConnected: Bool {
    guard let settings = try? loadSettings(),
          let status = settings["statusLine"] as? [String: Any],
          let command = status["command"] as? String else { return false }
    return command.contains(flag)
  }

  /// Existing status line command that isn't ours, if any.
  static var foreignStatusLine: String? {
    guard let settings = try? loadSettings(),
          let status = settings["statusLine"] as? [String: Any],
          let command = status["command"] as? String, !command.contains(flag) else { return nil }
    return command
  }

  /// Adds our status line to Claude Code's user settings after backing the file up.
  /// Refuses to replace a status line the user already has.
  static func connect() throws {
    guard isRunningFromApplications else { throw ConnectError.notInstalled }
    var settings = try loadSettings()
    if let other = foreignStatusLine { throw ConnectError.otherStatusLine(other) }
    try backup()
    settings["statusLine"] = ["type": "command", "command": commandLine, "padding": 0]
    try save(settings)
  }

  static func disconnect() throws {
    var settings = try loadSettings()
    guard isConnected else { return }
    try backup()
    settings.removeValue(forKey: "statusLine")
    try save(settings)
  }

  private static func backup() throws {
    guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let dest = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.edgecompanion-\(stamp).bak")
    try FileManager.default.copyItem(at: settingsURL, to: dest)
  }

  private static func save(_ settings: [String: Any]) throws {
    do {
      let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      // Write through a symlinked settings file (dotfile setups) instead of replacing the link.
      let target = settingsURL.resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target, options: [.atomic])
    } catch {
      throw ConnectError.writeFailed(error.localizedDescription)
    }
  }
}
