import AppKit
import SwiftUI

/// Countdown timer that keeps running while the widget is off screen.
final class TimerModel: ObservableObject {
  static let shared = TimerModel()

  enum Phase: Equatable { case idle, running, paused, finished }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var total: TimeInterval = 25 * 60
  @Published private(set) var remaining: TimeInterval = 25 * 60
  /// Flips every second after finishing, for the blinking ring.
  @Published private(set) var blink = false

  private var endDate: Date?
  private var ticker: Timer?
  private var alertCount = 0

  func start(minutes: Int) {
    total = TimeInterval(minutes * 60)
    remaining = total
    resume()
  }

  func resume() {
    guard remaining > 0 else { return }
    endDate = Date().addingTimeInterval(remaining)
    phase = .running
    startTicker()
  }

  func pause() {
    guard phase == .running else { return }
    tick()
    phase = .paused
    endDate = nil
    stopTicker()
  }

  func addMinute() {
    total += 60
    remaining += 60
    if phase == .running { endDate = endDate?.addingTimeInterval(60) }
    if phase == .finished || phase == .idle { resume() }
  }

  func reset() {
    stopTicker()
    phase = .idle
    remaining = total
    endDate = nil
    blink = false
  }

  private func startTicker() {
    stopTicker()
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = 0.1
    RunLoop.main.add(t, forMode: .common)
    ticker = t
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  private func tick() {
    switch phase {
    case .running:
      remaining = max(0, endDate.map { $0.timeIntervalSinceNow } ?? 0)
      if remaining <= 0 { finish() }
    case .finished:
      blink.toggle()
      // Chime a few times, then keep blinking quietly until reset.
      if alertCount < 3, Int(Date().timeIntervalSinceReferenceDate) % 2 == 0 {
        alertCount += 1
        NSSound(named: "Glass")?.play()
      }
    default:
      break
    }
  }

  private func finish() {
    phase = .finished
    remaining = 0
    alertCount = 1
    NSSound(named: "Glass")?.play()
    Log.info(.dashboard, "timer finished")
  }
}

struct TimerWidget: View {
  @ObservedObject private var timer = TimerModel.shared

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let controls: CGFloat = min(52, geo.size.height * 0.17)
        // Two rows, centred both ways: the time, then reset / +1 / start.
        VStack(alignment: .center, spacing: 16) {
          Text(timeText)
            .font(Theme.number(min(geo.size.height * 0.34, geo.size.width * 0.27, 110), weight: .bold))
            .foregroundStyle(timeColor)
            .opacity(timer.phase == .finished && timer.blink ? 0.35 : 1)
            .lineLimit(1)
          HStack(spacing: 12) {
            RoundButton(symbol: "arrow.counterclockwise", size: controls * 0.86) { timer.reset() }
            RoundButton(symbol: "plus", size: controls * 0.86) { timer.addMinute() }
            playButton(height: controls)
          }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
      }
    }
  }

  private func playButton(height: CGFloat) -> some View {
    let running = timer.phase == .running
    return Button {
      switch timer.phase {
      case .running: timer.pause()
      case .finished: timer.start(minutes: Int(timer.total / 60))
      default: timer.resume()
      }
    } label: {
      Label(running ? tr("일시정지", "Pause") : tr("시작", "Start"), systemImage: running ? "pause.fill" : "play.fill")
        .font(Theme.text(16, weight: .semibold))
        .foregroundStyle(running ? Theme.textPrimary : Theme.background)
        .padding(.horizontal, 20)
        .frame(height: height)
        .background(Capsule().fill(running ? Color.white.opacity(0.1) : accent))
        .contentShape(Capsule())
    }
    .buttonStyle(PressableStyle())
  }


  /// The time's colour carries the state: white while running, grey when idle or paused, red when done.
  private var timeColor: Color {
    switch timer.phase {
    case .running: return Theme.textPrimary
    case .finished: return Theme.critical
    case .idle, .paused: return Theme.textSecondary
    }
  }

  private var accent: Color {
    switch timer.phase {
    case .finished: return Theme.critical
    case .paused: return Theme.textTertiary
    default: return Theme.memory
    }
  }

  private var timeText: String {
    let s = Int(timer.remaining.rounded(.up))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
  }

}
