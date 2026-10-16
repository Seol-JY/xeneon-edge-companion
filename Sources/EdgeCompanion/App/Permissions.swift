import AppKit
import ApplicationServices
import IOKit.hid

/// TCC permissions this app depends on. They are tied to the code signature, so the app is
/// signed with a stable local certificate (see scripts/make-cert.sh).
enum Permissions {
  /// Input Monitoring: needed to seize and read the touch controller.
  static var canListen: Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
  }

  /// Accessibility: needed to post events into other apps, for the mouse fence and for moving windows.
  static var canPostEvents: Bool {
    AXIsProcessTrusted()
  }

  static func requestListen() {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
  }

  static func requestAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func openInputMonitoringSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
  }

  static func openAccessibilitySettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  private static func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
  }
}
