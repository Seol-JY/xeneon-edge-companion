import AppKit
import CoreGraphics
import EdgeCore
import IOKit

/// A snapshot of the connected Edge as CoreGraphics sees it.
struct EdgeDisplay: Equatable {
  let id: CGDirectDisplayID
  /// WindowServer UUID; stable across reconnects on the same Mac.
  let uuid: String
  /// Real panel serial from the IORegistry (`AlphanumericSerialNumber`), if found.
  let serial: String?
  /// Global Quartz points (top-left origin).
  let bounds: CGRect
  let rotation: Int
  let pixelSize: CGSize
  let isAsleep: Bool

  /// Key for per-panel settings.
  var profileKey: String { serial.map { "sn:\($0)" } ?? "uuid:\(uuid)" }

  var isNativeResolution: Bool {
    Int(pixelSize.width) == Int(EdgeIdentity.nativeSize.width) && Int(pixelSize.height) == Int(EdgeIdentity.nativeSize.height)
  }

  /// The AppKit screen for this display (bottom-left origin coordinates).
  var screen: NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
  }

  var summary: String {
    "\(Int(pixelSize.width))×\(Int(pixelSize.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY)))"
  }
}

enum EdgeLocator {
  static func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
  }

  static func isEdge(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == EdgeIdentity.displayVendor && CGDisplayModelNumber(id) == EdgeIdentity.displayModel
  }

  /// Finds the Edge. With several panels attached, prefers the one whose UUID matches `preferredUUID`.
  /// Returns nil when nothing matches; we never guess from size alone.
  static func find(preferredUUID: String? = nil) -> EdgeDisplay? {
    let candidates = onlineDisplays().filter(isEdge)
    guard !candidates.isEmpty else { return nil }
    let chosen = candidates.first { uuidString($0) == preferredUUID } ?? candidates[0]
    return snapshot(chosen)
  }

  static func snapshot(_ id: CGDirectDisplayID) -> EdgeDisplay {
    let uuid = uuidString(id) ?? "unknown-\(id)"
    let mode = CGDisplayCopyDisplayMode(id)
    let pixel = CGSize(width: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)), height: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)))
    return EdgeDisplay(
      id: id,
      uuid: uuid,
      serial: SerialCache.serial(forUUID: uuid),
      bounds: CGDisplayBounds(id),
      rotation: Int(CGDisplayRotation(id)),
      pixelSize: pixel,
      isAsleep: CGDisplayIsAsleep(id) != 0
    )
  }

  static func uuidString(_ id: CGDirectDisplayID) -> String? {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, u) as String?
  }

  /// Bounds of every online display, for fence geometry.
  static func allBounds() -> [CGRect] {
    onlineDisplays().map { CGDisplayBounds($0) }
  }
}

/// The IORegistry walk is comparatively slow, so the serial is cached per WindowServer UUID.
enum SerialCache {
  private static var cache: [String: String] = [:]
  private static let lock = NSLock()

  static func serial(forUUID uuid: String) -> String? {
    lock.lock()
    if let s = cache[uuid] {
      lock.unlock()
      return s
    }
    lock.unlock()
    let framebuffers = IORegistryDisplays.edgeFramebuffers()
    framebuffers.forEach { IOObjectRelease($0.avServiceEntry) }
    guard let s = framebuffers.first?.serial, !s.isEmpty else { return nil }
    lock.lock()
    cache[uuid] = s
    lock.unlock()
    return s
  }
}

/// Walks the IORegistry for Apple Silicon display framebuffers and their DDC (IOAVService) proxies.
enum IORegistryDisplays {
  struct Framebuffer {
    var productName: String
    var serial: String
    /// The `DCPAVServiceProxy` entry that follows the framebuffer, when it is an external port.
    var avServiceEntry: io_service_t
  }

  /// Returns the Edge framebuffers in registry order. Callers own `avServiceEntry` and must release it.
  static func edgeFramebuffers() -> [Framebuffer] {
    var result: [Framebuffer] = []
    var iterator = io_iterator_t()
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return result }
    defer { IOObjectRelease(iterator) }

    var name = [CChar](repeating: 0, count: 128)
    var current: (product: String, serial: String)?
    while true {
      let entry = IOIteratorNext(iterator)
      guard entry != IO_OBJECT_NULL else { break }
      IORegistryEntryGetName(entry, &name)
      let entryName = String(cString: name)
      if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
        current = nil
        if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let product = attrs["ProductAttributes"] as? [String: Any],
           let productName = product["ProductName"] as? String,
           productName == EdgeIdentity.productName {
          current = (productName, (product["AlphanumericSerialNumber"] as? String) ?? "")
        }
        IOObjectRelease(entry)
      } else if entryName == "DCPAVServiceProxy", let fb = current {
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if location == "External" {
          result.append(Framebuffer(productName: fb.product, serial: fb.serial, avServiceEntry: entry))
        } else {
          IOObjectRelease(entry)
        }
        current = nil
      } else {
        IOObjectRelease(entry)
      }
    }
    return result
  }
}
