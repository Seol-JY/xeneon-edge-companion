import EdgeCore
import Foundation
import IOKit
import IOKit.hid

/// Owns the WCH touch controller on a dedicated thread with its own run loop.
///
/// Each interface is opened with `kIOHIDOptionsTypeSeizeDevice` so macOS's own driver stops moving
/// the cursor to the wrong display. Report 0x07 on the mouse-emulation interface carries the data;
/// the digitizer interface is seized too (otherwise macOS can still emit input from it) but stays silent.
/// The vendor interface (0xFF0A) is never opened.
final class TouchHIDDevice {
  enum Status: Equatable {
    case stopped
    case waitingForDevice
    case running
    case notPermitted
    case busy
    case failed(String)
  }

  /// Called on the HID thread for every parsed report, with the controller's logical maxima.
  var onReport: ((TouchReport, _ maxX: Double, _ maxY: Double, _ time: TimeInterval) -> Void)?
  /// Called on the HID thread while touching / momentum is active (~120 Hz), for gesture timing.
  var onTick: ((TimeInterval) -> Void)?
  /// Called on the main thread.
  var onStatus: ((Status) -> Void)?
  /// Called on the HID thread when the device goes away (cancel in-flight gestures).
  var onDeviceLost: (() -> Void)?

  private var thread: Thread?
  private var runLoop: CFRunLoop?
  private var manager: IOHIDManager?
  private var openDevices: [IOHIDDevice] = []
  private var buffers: [UnsafeMutablePointer<UInt8>] = []
  private var maxX = Double(TouchReport.defaultMaxX)
  private var maxY = Double(TouchReport.defaultMaxY)
  private var tickTimer: CFRunLoopTimer?
  private var reopenDelay: TimeInterval = 0.5
  private let readySemaphore = DispatchSemaphore(value: 0)

  private(set) var status: Status = .stopped {
    didSet {
      guard status != oldValue else { return }
      let s = status
      Log.info(.touch, "HID status → \(s)")
      DispatchQueue.main.async { self.onStatus?(s) }
    }
  }

  func start() {
    guard thread == nil else { return }
    let t = Thread { [weak self] in self?.threadMain() }
    t.name = "EdgeCompanion.TouchHID"
    t.qualityOfService = .userInteractive
    thread = t
    t.start()
    readySemaphore.wait()
    perform { self.openManager() }
  }

  func stop() {
    guard let rl = runLoop else { return }
    perform {
      self.closeManager()
      self.setTicking(false)
      self.status = .stopped
      CFRunLoopStop(rl)
    }
    thread = nil
    runLoop = nil
  }

  /// Re-creates the manager (after wake/unlock or when permission was just granted).
  func reacquire() {
    perform {
      Log.info(.touch, "reacquiring HID device")
      self.closeManager()
      self.openManager()
    }
  }

  /// Enables a ~120 Hz tick on the HID thread; the controller turns it on while gestures need timing.
  func setTicking(_ on: Bool) {
    if on {
      guard tickTimer == nil, let rl = runLoop else { return }
      let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 1.0 / 120, 0, 0) { [weak self] _ in
        self?.onTick?(ProcessInfo.processInfo.systemUptime)
      }
      CFRunLoopAddTimer(rl, timer, .commonModes)
      tickTimer = timer
    } else if let timer = tickTimer {
      CFRunLoopTimerInvalidate(timer)
      tickTimer = nil
    }
  }

  func perform(_ block: @escaping () -> Void) {
    guard let rl = runLoop else { return }
    CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(rl)
  }

  // MARK: - HID thread

  private func threadMain() {
    runLoop = CFRunLoopGetCurrent()
    // A dummy source keeps the run loop alive while no device is attached.
    var ctx = CFRunLoopSourceContext()
    let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)
    CFRunLoopAddSource(runLoop, keepAlive, .commonModes)
    readySemaphore.signal()
    CFRunLoopRun()
  }

  private func openManager() {
    guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeDenied else {
      status = .notPermitted
      return
    }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let base: [String: Any] = [kIOHIDVendorIDKey: EdgeIdentity.touchVendorID, kIOHIDProductIDKey: EdgeIdentity.touchProductID]
    var mouse = base
    mouse[kIOHIDDeviceUsagePageKey] = kHIDPage_GenericDesktop
    mouse[kIOHIDDeviceUsageKey] = kHIDUsage_GD_Mouse
    var digitizer = base
    digitizer[kIOHIDDeviceUsagePageKey] = kHIDPage_Digitizer
    digitizer[kIOHIDDeviceUsageKey] = kHIDUsage_Dig_TouchScreen
    IOHIDManagerSetDeviceMatchingMultiple(m, [mouse, digitizer] as CFArray)

    let ctx = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
      guard let ctx else { return }
      Unmanaged<TouchHIDDevice>.fromOpaque(ctx).takeUnretainedValue().deviceMatched(device)
    }, ctx)
    IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
      guard let ctx else { return }
      Unmanaged<TouchHIDDevice>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
    }, ctx)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
    // The manager itself is not opened; each device is opened (seized) individually so one busy
    // interface cannot block the others.
    manager = m
    if openDevices.isEmpty { status = .waitingForDevice }
  }

  private func closeManager() {
    // Unscheduling and closing stops callbacks, so the report buffers can be freed afterwards.
    for device in openDevices {
      IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
      IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }
    openDevices.removeAll()
    buffers.forEach { $0.deallocate() }
    buffers.removeAll()
    if let m = manager {
      IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
      IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
      IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
    }
    manager = nil
  }

  private func deviceMatched(_ device: IOHIDDevice) {
    guard !openDevices.contains(where: { $0 === device }) else { return }
    let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
    let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    switch result {
    case kIOReturnSuccess:
      break
    case kIOReturnNotPermitted:
      status = .notPermitted
      return
    case kIOReturnExclusiveAccess:
      Log.error(.touch, "another app has the touch controller seized (0xE00002C5)")
      status = .busy
      return
    default:
      status = .failed(String(format: "open 0x%08X", result))
      scheduleReopen()
      return
    }
    openDevices.append(device)
    reopenDelay = 0.5

    if usagePage == kHIDPage_GenericDesktop {
      readLogicalMaxima(device)
      let size = 64
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
      buffers.append(buffer)
      let ctx = Unmanaged.passUnretained(self).toOpaque()
      IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { ctx, result, _, _, reportID, report, length in
        guard let ctx, result == kIOReturnSuccess else { return }
        Unmanaged<TouchHIDDevice>.fromOpaque(ctx).takeUnretainedValue().handleReport(reportID: reportID, report: report, length: length)
      }, ctx)
    }
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
    Log.info(.touch, "seized interface usagePage=0x\(String(usagePage, radix: 16))")
    status = .running
  }

  private func deviceRemoved(_ device: IOHIDDevice) {
    guard let index = openDevices.firstIndex(where: { $0 === device }) else { return }
    openDevices.remove(at: index)
    Log.info(.touch, "interface removed (\(openDevices.count) left)")
    onDeviceLost?()
    if openDevices.isEmpty { status = .waitingForDevice }
  }

  private func scheduleReopen() {
    let delay = reopenDelay
    reopenDelay = min(reopenDelay * 2, 5)
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.reacquire()
    }
  }

  private func readLogicalMaxima(_ device: IOHIDDevice) {
    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return }
    for e in elements where IOHIDElementGetUsagePage(e) == kHIDPage_GenericDesktop {
      let max = Double(IOHIDElementGetLogicalMax(e))
      guard max > 100 else { continue }
      switch Int(IOHIDElementGetUsage(e)) {
      case kHIDUsage_GD_X: maxX = max
      case kHIDUsage_GD_Y: maxY = max
      default: break
      }
    }
    Log.info(.touch, "logical max x=\(Int(maxX)) y=\(Int(maxY))")
  }

  private func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
    let bytes = UnsafeBufferPointer(start: report, count: length)
    var parsed = TouchReport.parse(bytes)
    if parsed == nil, reportID == UInt32(TouchReport.reportID), length >= 5 {
      // Some IOKit paths strip the ID byte and pass it separately.
      var withID = [TouchReport.reportID]
      withID.append(contentsOf: bytes.prefix(6))
      parsed = TouchReport.parse(withID)
    }
    guard let r = parsed else { return }
    onReport?(r, maxX, maxY, ProcessInfo.processInfo.systemUptime)
  }
}
