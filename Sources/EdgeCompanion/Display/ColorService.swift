import Combine
import EdgeCore
import Foundation

/// Applies the saved white balance to the panel over DDC (hardware gains, stored in the panel).
///
/// The Edge only honours RGB gains in its "User 1" colour preset (0x0B). Gains are written as
/// percentages but read back on a 0...255 scale. Brightness (VCP 0x10) is left to MonitorControl.
final class ColorService: ObservableObject {
  enum Status: Equatable {
    case idle
    case working(String)
    case applied(WhiteBalance)
    case failed(String)
  }

  @Published private(set) var status: Status = .idle
  /// Last values read from the panel.
  @Published private(set) var panelBalance: WhiteBalance?
  @Published private(set) var panelPreset: UInt16?

  private let ddc = DDCController()
  private let settings: SettingsStore
  private var display: EdgeDisplay?
  private var pendingApply: DispatchWorkItem?

  init(settings: SettingsStore) {
    self.settings = settings
  }

  func edgeChanged(_ state: DisplayMonitor.State) {
    switch state {
    case let .connected(display, _):
      let isNewPanel = self.display?.profileKey != display.profileKey
      self.display = display
      if isNewPanel { ddc.invalidate() }
      // Wait a moment: right after connect/wake MonitorControl also talks to the panel.
      scheduleConnectApply(after: 2.5)
    case .suspended:
      pendingApply?.cancel()
    case .disconnected:
      pendingApply?.cancel()
      display = nil
      ddc.invalidate()
      DispatchQueue.main.async { self.status = .idle }
    }
  }

  private func scheduleConnectApply(after delay: TimeInterval) {
    pendingApply?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let display = self.display else { return }
      let profile = self.settings.profile(for: display.profileKey)
      self.syncFromPanel(captureOriginalFor: display.profileKey) { [weak self] in
        guard let self, profile.applyColorOnConnect else { return }
        self.apply(profile.whiteBalance, reason: "connect")
      }
    }
    pendingApply = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Reads the panel's current preset and gains. The first time a panel is seen, stores them as the original.
  func syncFromPanel(captureOriginalFor key: String? = nil, completion: (() -> Void)? = nil) {
    ddc.queue.async { [weak self] in
      guard let self else { return }
      do {
        let preset = try self.ddc.read(.colorPreset).current
        let r = try self.ddc.read(.redGain).current
        let g = try self.ddc.read(.greenGain).current
        let b = try self.ddc.read(.blueGain).current
        let balance = WhiteBalance.fromReadback(red: r, green: g, blue: b)
        DispatchQueue.main.async {
          self.panelPreset = preset
          self.panelBalance = balance
          if let key, self.settings.profile(for: key).originalWhiteBalance == nil {
            self.settings.updateProfile(for: key) {
              $0.originalWhiteBalance = balance
              $0.originalColorPreset = preset
            }
            Log.info(.color, "captured original preset=\(preset) gains=\(balance)")
          }
          completion?()
        }
      } catch {
        Log.error(.color, "read failed: \(error)")
        DispatchQueue.main.async {
          self.status = .failed("\(error)")
          completion?()
        }
      }
    }
  }

  /// Writes gains (switching to the User preset first if needed) and verifies by reading back.
  func apply(_ target: WhiteBalance, reason: String = "user") {
    guard display != nil else {
      status = .failed("Edge not connected")
      return
    }
    status = .working("applying")
    ddc.queue.async { [weak self] in
      guard let self else { return }
      do {
        let preset = try self.ddc.read(.colorPreset).current
        if preset != EdgeVCP.userPreset {
          try self.ddc.write(.colorPreset, EdgeVCP.userPreset)
          Log.info(.color, "switched colour preset \(preset) → User 1")
        }
        var current = try self.readBalance()
        for attempt in 1 ... 3 where current != target {
          if current.red != target.red { try self.ddc.write(.redGain, UInt16(target.red)) }
          if current.green != target.green { try self.ddc.write(.greenGain, UInt16(target.green)) }
          if current.blue != target.blue { try self.ddc.write(.blueGain, UInt16(target.blue)) }
          current = try self.readBalance()
          if current != target { Log.info(.color, "verify mismatch (attempt \(attempt)): \(current)") }
        }
        let final = current
        DispatchQueue.main.async {
          self.panelBalance = final
          self.panelPreset = EdgeVCP.userPreset
          // Readback is quantised (percent → /255 → percent), so allow ±1.
          let close = abs(final.red - target.red) <= 1 && abs(final.green - target.green) <= 1 && abs(final.blue - target.blue) <= 1
          self.status = close ? .applied(final) : .failed("panel reports \(final.red)/\(final.green)/\(final.blue)")
          Log.info(.color, "apply (\(reason)) target=\(target) panel=\(final)")
        }
      } catch {
        Log.error(.color, "apply failed: \(error)")
        DispatchQueue.main.async { self.status = .failed("\(error)") }
      }
    }
  }

  /// Puts back what the panel had before this app first touched it.
  func restoreOriginal() {
    guard let display else { return }
    let profile = settings.profile(for: display.profileKey)
    let original = profile.originalWhiteBalance ?? .factory
    apply(original, reason: "restore")
    if let preset = profile.originalColorPreset, preset != EdgeVCP.userPreset {
      ddc.queue.async { [weak self] in
        try? self?.ddc.write(.colorPreset, preset)
      }
    }
  }

  private func readBalance() throws -> WhiteBalance {
    let r = try ddc.read(.redGain).current
    let g = try ddc.read(.greenGain).current
    let b = try ddc.read(.blueGain).current
    return WhiteBalance.fromReadback(red: r, green: g, blue: b)
  }
}
