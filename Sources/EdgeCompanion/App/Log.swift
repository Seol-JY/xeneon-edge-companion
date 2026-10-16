import Foundation
import os

/// Thin wrapper over `os.Logger` that also keeps the last lines in memory for the Diagnostics tab.
enum Log {
  static let subsystem = "pro.seol.EdgeCompanion"

  enum Category: String {
    case app, display, color, touch, kiosk, pointer, evictor, dashboard
  }

  private static let loggers: [Category: Logger] = {
    var map: [Category: Logger] = [:]
    for c in [Category.app, .display, .color, .touch, .kiosk, .pointer, .evictor, .dashboard] {
      map[c] = Logger(subsystem: subsystem, category: c.rawValue)
    }
    return map
  }()

  private static let lock = NSLock()
  private static var ring: [String] = []
  private static let ringLimit = 300
  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  static func info(_ category: Category, _ message: String) {
    loggers[category]?.info("\(message, privacy: .public)")
    remember("I", category, message)
  }

  static func error(_ category: Category, _ message: String) {
    loggers[category]?.error("\(message, privacy: .public)")
    remember("E", category, message)
  }

  static func debug(_ category: Category, _ message: String) {
    loggers[category]?.debug("\(message, privacy: .public)")
  }

  static func recentLines() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return ring
  }

  private static func remember(_ level: String, _ category: Category, _ message: String) {
    let line = "\(timeFormatter.string(from: Date())) \(level) [\(category.rawValue)] \(message)"
    lock.lock()
    ring.append(line)
    if ring.count > ringLimit { ring.removeFirst(ring.count - ringLimit) }
    lock.unlock()
    fileQueue.async { appendToFile(line) }
  }

  // MARK: File log (~/Library/Logs/EdgeCompanion/EdgeCompanion.log, rotated at 1 MB)

  private static let fileQueue = DispatchQueue(label: "pro.seol.EdgeCompanion.log", qos: .background)
  private static var fileHandle: FileHandle?

  static let logFileURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/EdgeCompanion", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("EdgeCompanion.log")
  }()

  private static func appendToFile(_ line: String) {
    let url = logFileURL
    if fileHandle == nil {
      if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
      }
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      fileHandle = try? FileHandle(forWritingTo: url)
      _ = try? fileHandle?.seekToEnd()
    }
    if let data = (line + "\n").data(using: .utf8) {
      try? fileHandle?.write(contentsOf: data)
    }
  }
}
