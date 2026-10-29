import AppKit
import Combine
import EdgeCore

/// One short-lived Shortcuts process every minute; no HTTP listener or HomeKit credentials.
@MainActor final class HomeTemperatureModel: ObservableObject {
  static let shared = HomeTemperatureModel()
  static let interval: TimeInterval = 60
  @Published private(set) var samples: [HomeTemperatureSample] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  @Published private(set) var configured = false
  var latest: HomeTemperatureSample? { samples.last }

  private var shortcut = ""
  private var enabled = false
  private var timer: Timer?
  private var generation = 0
  private var suspension: AnyCancellable?
  private let storage = DispatchQueue(label: "pro.seol.EdgeCompanion.temperature-storage", qos: .utility)
  nonisolated private static var archiveURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EdgeCompanion/temperature.json")
  }
  private struct Archive: Codable { let shortcut: String; let samples: [HomeTemperatureSample] }

  private init() {
    suspension = NotificationCenter.default.publisher(for: .edgeDashboardSuspensionChanged).sink { [weak self] _ in
      Task { @MainActor in self?.resumeIfNeeded() }
    }
  }

  func configure(shortcut name: String, enabled: Bool) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceChanged = shortcut != name
    guard sourceChanged || self.enabled != enabled else { return }
    generation += 1
    shortcut = name
    configured = !name.isEmpty
    self.enabled = enabled
    error = nil
    if sourceChanged {
      samples = []
      storage.async {
        let archive = (try? Data(contentsOf: Self.archiveURL)).flatMap { try? JSONDecoder().decode(Archive.self, from: $0) }
        DispatchQueue.main.async { [weak self] in
          guard let self, self.shortcut == name, self.samples.isEmpty,
                let archive, archive.shortcut == name else { return }
          self.samples = archive.samples.filter { $0.date > Date().addingTimeInterval(-86400) && $0.date <= Date() && $0.celsius.isFinite && (-50...80).contains($0.celsius) }
            .sorted { $0.date < $1.date }.suffix(1500).map { $0 }
        }
      }
    }
    timer?.invalidate(); timer = nil
    guard enabled, configured else { return }
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.enabled, !TelemetryHub.shared.isSuspended else { return }
        self.refresh()
      }
    }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    resumeIfNeeded()
  }

  private func resumeIfNeeded() {
    guard enabled, !TelemetryHub.shared.isSuspended else { return }
    if latest.map({ Date().timeIntervalSince($0.date) >= Self.interval }) ?? true { refresh() }
  }

  /// Also used by the explicit connection test before the widget is placed.
  func refresh() {
    guard configured, !isLoading else { return }
    isLoading = true
    error = nil
    let name = shortcut, version = generation
    Task {
      let value = await Task.detached(priority: .utility) { ShortcutTemperatureReader.read(name: name) }.value
      isLoading = false
      guard version == generation else { resumeIfNeeded(); return }
      switch value {
      case let .success(celsius):
        let now = Date()
        samples = samples.filter { $0.date > now.addingTimeInterval(-86400) }
        samples.append(HomeTemperatureSample(date: now, celsius: celsius))
        samples = Array(samples.suffix(1500))
        let archive = Archive(shortcut: name, samples: samples)
        storage.async {
          guard let data = try? JSONEncoder().encode(archive) else { return }
          let url = Self.archiveURL
          try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? data.write(to: url, options: .atomic)
        }
      case let .failure(failure): error = failure.message
      }
    }
  }
}

private enum ShortcutTemperatureReader {
  enum Failure: Error {
    case timeout, execution, invalidValue
    var message: String {
      switch self {
      case .timeout: return tr("온도 읽기가 지연돼요. 단축어 앱에서 접근 허용 요청을 확인해 주세요.", "Reading timed out. Check Shortcuts for an access request.")
      case .execution: return tr("단축어를 실행하지 못했어요. 이름과 센서 설정을 확인해 주세요.", "Couldn't run the shortcut. Check its name and sensor selection.")
      case .invalidValue: return tr("단축어가 온도를 반환하지 않았어요. 마지막 동작에서 온도 값을 출력해 주세요.", "The shortcut didn't return a temperature. Output the temperature as its final action.")
      }
    }
  }

  static func read(name: String) -> Result<Double, Failure> {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edge-temperature-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    catch { return .failure(.execution) }
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appendingPathComponent("value.txt")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = ["run", name, "--output-path", output.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return .failure(.execution) }
    let deadline = Date().addingTimeInterval(45)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning {
      process.terminate()
      let grace = Date().addingTimeInterval(2)
      while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      return .failure(.timeout)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return .failure(.execution) }
    guard let data = try? Data(contentsOf: output), data.count < 4096,
          let text = String(data: data, encoding: .utf8),
          let celsius = HomeTemperature.celsius(from: text) else { return .failure(.invalidValue) }
    return .success(celsius)
  }
}
