import Foundation
import IOKit

// Minimal read-only AppleSMC client (user client selector 2 = kSMCHandleYPCEvent).
// Struct layout and command codes adapted from exelban/stats SMC/smc.swift (MIT, Serhiy Mytrovtsiy);
// service selection ("AppleSMCKeysEndpoint") and temperature key discovery follow
// vladkens/macmon src/sources.rs + src/metrics.rs (MIT).

struct SMCKeyData {
  typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
  struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
  struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
  struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

  var key: UInt32 = 0
  var vers = Vers()
  var pLimit = PLimit()
  var keyInfo = KeyInfo()
  /// Swift packs the 9-byte KeyInfo without C tail padding; this restores the C layout (80 bytes).
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Not thread-safe: used only from the telemetry queue.
final class SMCConnection {
  private enum Command: UInt8 { case readBytes = 5, readIndex = 8, readKeyInfo = 9 }
  static let typeFLT = fourCC("flt ")

  private var conn: io_connect_t = 0
  private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

  /// Opens the connection once; returns nil without an AppleSMC service (VMs).
  init?() {
    guard MemoryLayout<SMCKeyData>.size == 80 else { return nil }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    var chosen: io_service_t = 0
    while case let s = IOIteratorNext(iter), s != 0 {
      var name = [CChar](repeating: 0, count: 128)
      IORegistryEntryGetName(s, &name)
      if String(cString: name) == "AppleSMCKeysEndpoint" {
        if chosen != 0 { IOObjectRelease(chosen) }
        chosen = s
        break
      }
      if chosen == 0 { chosen = s } else { IOObjectRelease(s) }
    }
    guard chosen != 0 else { return nil }
    defer { IOObjectRelease(chosen) }
    guard IOServiceOpen(chosen, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
  }

  deinit { if conn != 0 { IOServiceClose(conn) } }

  static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
  static func string(_ k: UInt32) -> String {
    String(decoding: [UInt8(k >> 24 & 0xff), UInt8(k >> 16 & 0xff), UInt8(k >> 8 & 0xff), UInt8(k & 0xff)], as: UTF8.self)
  }

  private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
    var output = SMCKeyData()
    var outSize = MemoryLayout<SMCKeyData>.stride
    let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
    guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
    return output
  }

  func keyInfo(_ key: UInt32) -> SMCKeyData.KeyInfo? {
    if let cached = infoCache[key] { return cached }
    var input = SMCKeyData()
    input.key = key
    input.data8 = Command.readKeyInfo.rawValue
    guard let out = call(&input) else { return nil }
    infoCache[key] = out.keyInfo
    return out.keyInfo
  }

  /// Raw bytes of a key plus its type.
  func read(_ key: UInt32) -> (type: UInt32, bytes: [UInt8])? {
    guard let info = keyInfo(key), info.dataSize > 0, info.dataSize <= 32 else { return nil }
    var input = SMCKeyData()
    input.key = key
    input.keyInfo = info
    input.data8 = Command.readBytes.rawValue
    guard let out = call(&input) else { return nil }
    let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
    return (info.dataType, bytes)
  }

  /// A 4-byte little-endian float key ('flt '), the format of temperatures and power on Apple silicon.
  func readFloat(_ key: UInt32) -> Float? {
    guard let info = keyInfo(key), info.dataType == Self.typeFLT, info.dataSize == 4 else { return nil }
    var input = SMCKeyData()
    input.key = key
    input.keyInfo = info
    input.data8 = Command.readBytes.rawValue
    guard let out = call(&input) else { return nil }
    let v = withUnsafeBytes(of: out.bytes) { $0.loadUnaligned(as: Float.self) }
    return v.isFinite ? v : nil
  }

  /// Integer keys (ui8/ui16/ui32, big-endian) such as #KEY and FNum.
  func readUInt(_ key: UInt32) -> UInt32? {
    guard let (type, b) = read(key) else { return nil }
    switch type {
    case Self.fourCC("ui8 "): return b.count >= 1 ? UInt32(b[0]) : nil
    case Self.fourCC("ui16"): return b.count >= 2 ? UInt32(b[0]) << 8 | UInt32(b[1]) : nil
    case Self.fourCC("ui32"): return b.count >= 4 ? UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) : nil
    default: return nil
    }
  }

  func key(at index: UInt32) -> UInt32? {
    var input = SMCKeyData()
    input.data8 = Command.readIndex.rawValue
    input.data32 = index
    return call(&input)?.key
  }

  /// Every key name the SMC exposes (a few thousand; costs one call per key, run once).
  func allKeys() -> [UInt32] {
    guard let count = readUInt(Self.fourCC("#KEY")), count > 0, count < 20_000 else { return [] }
    return (0..<count).compactMap { key(at: $0) }
  }
}
