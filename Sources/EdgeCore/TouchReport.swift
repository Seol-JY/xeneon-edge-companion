import Foundation

/// One single-contact sample from the touch controller's mouse-emulation interface.
public struct TouchReport: Equatable, Sendable {
  public var isDown: Bool
  public var x: UInt16
  public var y: UInt16

  public init(isDown: Bool, x: UInt16, y: UInt16) {
    self.isDown = isDown
    self.x = x
    self.y = y
  }

  /// Logical ranges declared by the controller's report descriptor (0..16383 x 0..9599).
  public static let defaultMaxX: UInt16 = 16383
  public static let defaultMaxY: UInt16 = 9599
  public static let reportID: UInt8 = 0x07

  /// Parses report 0x07: `[0x07][buttons][X lo][X hi][Y lo][Y hi][wheel]`.
  ///
  /// IOKit sometimes delivers the buffer without the report ID byte (6 bytes), so both layouts are accepted.
  public static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> TouchReport? {
    let offset: Int
    if bytes.count >= 7, bytes[0] == reportID {
      offset = 1
    } else if bytes.count == 6 {
      offset = 0
    } else {
      return nil
    }
    let buttons = bytes[offset]
    let x = UInt16(bytes[offset + 1]) | UInt16(bytes[offset + 2]) << 8
    let y = UInt16(bytes[offset + 3]) | UInt16(bytes[offset + 4]) << 8
    return TouchReport(isDown: buttons & 0x01 == 1, x: x, y: y)
  }

  public static func parse(_ bytes: [UInt8]) -> TouchReport? {
    bytes.withUnsafeBufferPointer { parse($0) }
  }
}
