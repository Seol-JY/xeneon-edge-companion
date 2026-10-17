import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Keeps the Mac and its displays awake for a while, like `caffeinate -d`, and puts it to sleep on
/// demand. Nothing is kept across launches: quitting the app releases the assertion.
final class AwakeModel: ObservableObject {
  static let shared = AwakeModel()

  /// Durations offered on the widget, in minutes.
  static let choices = [60, 240, 480, 1440]

  @Published private(set) var minutes: Int?
  @Published private(set) var endDate: Date?
  var isOn: Bool { minutes != nil }

  private var assertion: IOPMAssertionID = 0
  private var expiry: Timer?

  /// Tapping the running duration again turns it off.
  func toggle(minutes choice: Int) {
    if minutes == choice { stop() } else { start(minutes: choice) }
  }

  func start(minutes choice: Int) {
    if assertion == 0 {
      // Preventing display sleep also prevents idle system sleep.
      let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "EdgeCompanion keep awake" as CFString, &assertion)
      guard result == kIOReturnSuccess else {
        Log.info(.dashboard, "keep awake: assertion failed (\(result))")
        assertion = 0
        return
      }
    }
    let end = Date().addingTimeInterval(TimeInterval(choice * 60))
    minutes = choice
    endDate = end
    expiry?.invalidate()
    let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.stop() }
    RunLoop.main.add(t, forMode: .common)
    expiry = t
  }

  func stop() {
    expiry?.invalidate()
    expiry = nil
    if assertion != 0 { IOPMAssertionRelease(assertion) }
    assertion = 0
    minutes = nil
    endDate = nil
  }

  /// Sleeps now. A sleep asked for explicitly is not held back by the keep-awake assertion.
  func sleepNow() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["sleepnow"]
    do { try p.run() } catch { Log.info(.dashboard, "sleep failed: \(error.localizedDescription)") }
  }

  /// Turns it on without the assertion, for `--render-widgets`.
  func preview(minutes choice: Int, left: TimeInterval) {
    minutes = choice
    endDate = Date().addingTimeInterval(left)
  }
}

/// Laid out like the timer: one large line over the duration buttons. Off, the line just reads
/// "caffeinate" in grey; on, it is the time left beside a cup. Swiping up on the card raises a
/// sleep panel over it, and a tap there puts the Mac to sleep.
struct SleepWidget: View {
  @ObservedObject private var awake = AwakeModel.shared
  /// The sleep panel is up and waiting for its tap.
  @State private var armed = false
  @State private var disarmWork: DispatchWorkItem?
  @State private var frame: CGRect = .zero

  private static let night = Color(red: 0.36, green: 0.40, blue: 0.90)

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let w = geo.size.width, h = geo.size.height
        let controls: CGFloat = min(42, h * 0.14)
        let chipWidth = min(92, (w - 3 * 8) / 4)
        // Centred on the whole card; the swipe hint sits apart along the bottom edge.
        VStack(spacing: 28) {
          headline(width: w, height: h)
          HStack(spacing: 8) {
            ForEach(AwakeModel.choices, id: \.self) { choice in
              chip(choice, height: controls).frame(width: chipWidth)
            }
          }
        }
        .frame(width: w, height: h)
        .overlay(alignment: .bottom) { sleepHint }
      }
    }
    .overlay { if armed { sleepPanel.transition(.move(edge: .bottom).combined(with: .opacity)) } }
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { frame = geo.frame(in: .global) }
          .onChange(of: geo.frame(in: .global)) { _, f in frame = f }
      }
    )
    .onReceive(NotificationCenter.default.publisher(for: .edgeDashboardSwipeUp)) { note in
      guard let point = note.object as? CGPoint, frame.contains(point) else { return }
      arm()
    }
    .onDisappear { disarm(animated: false) }
  }

  // MARK: Keep awake

  @ViewBuilder
  private func headline(width: CGFloat, height: CGFloat) -> some View {
    let size = min(height * 0.3, width * 0.15, 84)
    if let end = awake.endDate {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        HStack(spacing: size * 0.22) {
          Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Theme.memory)
          big(Self.clock(end.timeIntervalSince(context.date)), size: size, color: Theme.textPrimary)
        }
      }
    } else {
      big("caffeinate", size: size * 0.8, color: Theme.textTertiary)
    }
  }

  private func big(_ text: String, size: CGFloat, color: Color) -> some View {
    Text(text)
      .font(Theme.number(size, weight: .bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
  }

  private func chip(_ choice: Int, height: CGFloat) -> some View {
    let active = awake.minutes == choice
    return Button {
      awake.toggle(minutes: choice)
    } label: {
      Text(tr("\(choice / 60)시간", "\(choice / 60)h"))
        .font(Theme.text(14, weight: .semibold))
        .foregroundStyle(active ? Theme.background : Theme.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Capsule().fill(active ? Theme.memory : Color.white.opacity(0.08)))
        .contentShape(Capsule())
    }
    .buttonStyle(PressableStyle())
  }

  // MARK: Sleep

  /// The quiet prompt along the bottom edge. A tap works too, for a mouse.
  private var sleepHint: some View {
    HStack(spacing: 5) {
      Image(systemName: "chevron.up")
        .font(.system(size: 11.5, weight: .bold))
      Text("Swipe up to Sleep")
        .font(Theme.text(13.5, weight: .semibold))
    }
    .foregroundStyle(Theme.textTertiary.opacity(0.8))
    .contentShape(Rectangle().inset(by: -8))
    .onTapGesture { arm() }
  }

  /// Covers the whole card; a tap sleeps, otherwise it drops back after a few seconds.
  private var sleepPanel: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
    return Button {
      disarm(animated: false)
      awake.sleepNow()
    } label: {
      VStack(spacing: 12) {
        Image(systemName: "moon.fill")
          .font(.system(size: 34, weight: .semibold))
        Text("Tap again to Sleep")
          .font(Theme.text(19, weight: .semibold))
      }
      .foregroundStyle(Color.white)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(shape.fill(Self.night))
      .contentShape(shape)
    }
    .buttonStyle(PressableStyle())
  }

  private func arm() {
    disarmWork?.cancel()
    withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { armed = true }
    let work = DispatchWorkItem { disarm(animated: true) }
    disarmWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
  }

  private func disarm(animated: Bool) {
    disarmWork?.cancel()
    disarmWork = nil
    guard armed else { return }
    if animated { withAnimation(.easeInOut(duration: 0.3)) { armed = false } } else { armed = false }
  }

  private static func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
  }
}
