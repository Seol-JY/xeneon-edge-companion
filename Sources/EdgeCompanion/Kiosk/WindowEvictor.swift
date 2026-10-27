import AppKit
import ApplicationServices
import EdgeCore

/// Moves other apps' windows out from under the dashboard, so nothing gets "lost" underneath.
/// With the whole Edge covered they go to the main display; in split mode they are fitted into the
/// Edge's regular part. Uses the Accessibility API: each app's window move/resize/create
/// notifications trigger a check once the window settles (mouse released), with a slow timer as
/// a backstop.
final class WindowEvictor {
  private var covered: CGRect?
  private var edgeBounds: CGRect?
  /// Split mode: where windows on the Edge may stay (global Quartz points).
  private var freeArea: CGRect?
  private var timer: Timer?
  private var observer: NSObjectProtocol?
  private var appObservers: [NSObjectProtocol] = []
  /// One Accessibility observer per running app, for its windows' move/resize/create notifications.
  private var axObservers: [pid_t: AXObserver] = [:]
  private var pendingSweep: DispatchWorkItem?
  /// When we last moved a window of each app; event-driven checks leave those alone briefly so an
  /// app that refuses a frame can't set off a loop of our own moves.
  private var lastMoved: [pid_t: Date] = [:]
  private let ownPID = ProcessInfo.processInfo.processIdentifier

  /// `covered` is the dashboard's area (nil: off); `freeArea` is set only in split mode.
  func configure(covered: CGRect?, edgeBounds: CGRect?, freeArea: CGRect?) {
    self.covered = edgeBounds == nil ? nil : covered
    self.edgeBounds = edgeBounds
    self.freeArea = freeArea
    if self.covered != nil { start() } else { stop() }
  }

  private func start() {
    guard timer == nil else {
      // Already running; pick up apps missed before Accessibility was granted.
      NSWorkspace.shared.runningApplications.forEach(watch)
      return
    }
    Log.info(.evictor, "watching the Edge for stray windows")
    let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.sweep() }
    t.tolerance = 1
    RunLoop.main.add(t, forMode: .common)
    timer = t
    observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.sweep() }
    }
    let ws = NSWorkspace.shared.notificationCenter
    appObservers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.watch(app) }
    })
    appObservers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.unwatch(app.processIdentifier) }
    })
    NSWorkspace.shared.runningApplications.forEach(watch)
    sweep()
  }

  // MARK: - Window notifications

  private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowCreatedNotification] as [CFString]

  private func watch(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard app.activationPolicy == .regular, pid != ownPID, axObservers[pid] == nil, Permissions.canPostEvents else { return }
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      Unmanaged<WindowEvictor>.fromOpaque(refcon).takeUnretainedValue().windowChanged()
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else { return }
    let element = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in Self.windowNotifications {
      AXObserverAddNotification(obs, element, name, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    axObservers[pid] = obs
  }

  private func unwatch(_ pid: pid_t) {
    guard let obs = axObservers.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    lastMoved[pid] = nil
  }

  /// A window moved, resized or appeared: check once it settles and the mouse is up, so a window
  /// being dragged is never pulled out from under the pointer.
  private func windowChanged() {
    pendingSweep?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.sweepWhenSettled() }
    pendingSweep = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  private func sweepWhenSettled() {
    if NSEvent.pressedMouseButtons != 0 {
      windowChanged()
      return
    }
    sweep(skipRecent: true)
  }

  private func stop() {
    if timer != nil { Log.info(.evictor, "stopped") }
    timer?.invalidate()
    timer = nil
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observer = nil
    appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    appObservers.removeAll()
    Array(axObservers.keys).forEach(unwatch)
    pendingSweep?.cancel()
    pendingSweep = nil
  }

  /// Accessibility hides other apps' windows while the screen is locked; checking then only fails.
  private static var screenLocked: Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  private func sweep(skipRecent: Bool = false) {
    guard let covered, Permissions.canPostEvents, !Self.screenLocked,
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
      if skipRecent, let last = lastMoved[pid], Date().timeIntervalSince(last) < 1.5 { continue }
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
      lastMoved[pid] = Date()
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
