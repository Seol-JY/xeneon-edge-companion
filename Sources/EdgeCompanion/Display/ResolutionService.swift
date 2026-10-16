import CoreGraphics
import EdgeCore
import Foundation

/// macOS sometimes brings the Edge up in a 16:9 mode (e.g. 1920×1080) that the scaler letterboxes.
/// This puts it back to native 2560×720 using public API only.
enum ResolutionService {
  /// Returns true if a mode change was requested.
  @discardableResult
  static func ensureNative(_ display: EdgeDisplay) -> Bool {
    guard !display.isNativeResolution else { return false }
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display.id, options) as? [CGDisplayMode] else { return false }
    let native = modes
      .filter { $0.pixelWidth == Int(EdgeIdentity.nativeSize.width) && $0.pixelHeight == Int(EdgeIdentity.nativeSize.height) && $0.width == $0.pixelWidth }
      .max { $0.refreshRate < $1.refreshRate }
    guard let mode = native else {
      Log.info(.display, "native 2560×720 mode not offered by the system (current \(display.summary))")
      return false
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil)
    let result = CGCompleteDisplayConfiguration(config, .forSession)
    Log.info(.display, "requested native mode: \(result == .success ? "ok" : "error \(result.rawValue)")")
    return result == .success
  }
}
