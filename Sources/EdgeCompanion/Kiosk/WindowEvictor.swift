import AppKit
import ApplicationServices
import EdgeCore

/// Moves other apps' windows out from under the dashboard, so nothing gets "lost" underneath.
/// With the whole Edge covered they go to the main display; in split mode they are fitted into the
/// Edge's regular part. Uses the Accessibility API; checks cheaply on app activation and every few seconds.
final class WindowEvictor {
  private var covered: CGRect?
  private var edgeBounds: CGRect?
  /// Split mode: where windows on the Edge may stay (global Quartz points).
  private var freeArea: CGRect?
  private var timer: Timer?
  private var observer: NSObjectProtocol?
  private let ownPID = ProcessInfo.processInfo.processIdentifier

  /// `covered` is the dashboard's area (nil: off); `freeArea` is set only in split mode.
  func configure(covered: CGRect?, edgeBounds: CGRect?, freeArea: CGRect?) {
    self.covered = edgeBounds == nil ? nil : covered
    self.edgeBounds = edgeBounds
    self.freeArea = freeArea
    if self.covered != nil { start() } else { stop() }
  }

  private func start() {
    guard timer == nil else { return }
    Log.info(.evictor, "watching the Edge for stray windows")
    let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.sweep() }
    t.tolerance = 1
    RunLoop.main.add(t, forMode: .common)
    timer = t
    observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.sweep() }
    }
    sweep()
  }

  private func stop() {
    if timer != nil { Log.info(.evictor, "stopped") }
    timer?.invalidate()
    timer = nil
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observer = nil
  }

  private func sweep() {
    guard let covered, Permissions.canPostEvents,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
    for info in list {
      guard (info[kCGWindowLayer as String] as? Int) == 0,
            let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
            let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
      let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      guard rect.width > 40, rect.height > 40 else { continue }
      let overlap = rect.intersection(covered)
      guard !overlap.isNull else { continue }
      let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
      if let freeArea, let edgeBounds {
        // Split mode: a window on the Edge that reaches under the dashboard slides (and if needed
        // shrinks) into the regular part. Windows mostly on another display are left alone.
        guard edgeBounds.contains(CGPoint(x: rect.midX, y: rect.midY)), overlap.width > 16, overlap.height > 16 else { continue }
        move(pid: pid, windowRect: rect, ownerName: owner, to: SplitLayout.fit(rect, into: freeArea))
      } else {
        // Mostly on the Edge (its centre is there, or over half its area).
        guard covered.contains(CGPoint(x: rect.midX, y: rect.midY)) || overlap.width * overlap.height > rect.width * rect.height / 2 else { continue }
        move(pid: pid, windowRect: rect, ownerName: owner, to: destinationFrame(for: rect.size))
      }
    }
  }

  private func move(pid: pid_t, windowRect: CGRect, ownerName: String, to target: CGRect) {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    guard err == .success, let windows = value as? [AXUIElement] else {
      Log.error(.evictor, "cannot list \(ownerName) windows (AX error \(err.rawValue))")
      return
    }
    for w in windows {
      guard let frame = axFrame(w), abs(frame.minX - windowRect.minX) < 2, abs(frame.minY - windowRect.minY) < 2 else { continue }
      var origin = target.origin
      var size = target.size
      if let posValue = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posValue)
      }
      if size != windowRect.size, let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sizeValue)
        // Some apps refuse a position that would put the old, larger size off screen; retry now it fits.
        if let posValue = AXValueCreate(.cgPoint, &origin) {
          AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posValue)
        }
      }
      Log.info(.evictor, "moved a \(ownerName) window out from under the dashboard")
      return
    }
    Log.error(.evictor, "no AX window of \(ownerName) matches \(windowRect); AX frames: \(windows.compactMap(axFrame))")
  }

  /// Where to put an evicted window: the main display's visible area, in global Quartz coordinates.
  private func destinationFrame(for size: CGSize) -> CGRect {
    let mainID = CGMainDisplayID()
    let main = CGDisplayBounds(mainID)
    let menuBar: CGFloat = 40
    let maxW = main.width - 80
    let maxH = main.height - menuBar - 80
    let w = min(size.width, maxW)
    let h = min(size.height, maxH)
    return CGRect(x: main.midX - w / 2, y: main.minY + menuBar + max((maxH - h) / 2, 0), width: w, height: h)
  }

  private func axFrame(_ w: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posRef, let sizeRef else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
  }
}
