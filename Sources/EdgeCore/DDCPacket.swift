import Foundation

/// DDC/CI packet framing used over `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` on Apple Silicon.
public enum DDCPacket {
  public static let chipAddress: UInt8 = 0x37
  public static let dataAddress: UInt8 = 0x51

  /// Set VCP feature: `[0x84, 0x03, vcp, hi, lo, chk]`.
  public static func setVCP(_ vcp: UInt8, value: UInt16) -> [UInt8] {
    frame([0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
  }

  /// Get VCP feature request: `[0x82, 0x01, vcp, chk]`.
  public static func getVCP(_ vcp: UInt8) -> [UInt8] {
    frame([0x01, vcp])
  }

  /// `[0x80 | length][opcode, args...][checksum]`; the checksum XORs the destination (0x6E),
  /// the source (0x51) and every byte, per DDC/CI.
  static func frame(_ payload: [UInt8]) -> [UInt8] {
    let packet: [UInt8] = [0x80 | UInt8(payload.count)] + payload
    var chk: UInt8 = (chipAddress << 1) ^ dataAddress
    for b in packet { chk ^= b }
    return packet + [chk]
  }

  public struct VCPReply: Equatable, Sendable {
    public var vcp: UInt8
    public var current: UInt16
    public var maximum: UInt16
  }

  public enum ReplyError: Error, Equatable {
    case badLength, badChecksum, notAVCPReply, unsupported(UInt8)
  }

  /// Parses an 11-byte Get VCP reply:
  /// `[src 0x6E][0x88][0x02][result][vcp][type][max hi][max lo][cur hi][cur lo][chk]`.
  public static func parseReply(_ reply: [UInt8], expecting vcp: UInt8) -> Result<VCPReply, ReplyError> {
    guard reply.count >= 11 else { return .failure(.badLength) }
    var chk: UInt8 = 0x50
    for i in 0 ..< 10 { chk ^= reply[i] }
    guard chk == reply[10] else { return .failure(.badChecksum) }
    guard reply[2] == 0x02, reply[4] == vcp else { return .failure(.notAVCPReply) }
    guard reply[3] == 0 else { return .failure(.unsupported(reply[3])) }
    let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
    let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
    return .success(VCPReply(vcp: vcp, current: current, maximum: maximum))
  }
}

/// VCP codes this app is allowed to touch. Anything that can blank a panel with no physical
/// buttons (input select 0x60, power 0xD6, factory reset 0x04/0x08) is deliberately absent.
public enum EdgeVCP: UInt8, CaseIterable, Sendable {
  case colorPreset = 0x14
  case redGain = 0x16
  case greenGain = 0x18
  case blueGain = 0x1A

  /// Colour preset value that enables the RGB gains.
  public static let userPreset: UInt16 = 0x0B
}

/// White balance as the panel's RGB gains in percent (what DDC writes take).
/// Reads come back on a 0...255 scale, so `fromReadback` converts.
public struct WhiteBalance: Codable, Equatable, Sendable {
  public var red: Int
  public var green: Int
  public var blue: Int

  public init(red: Int, green: Int, blue: Int) {
    self.red = Self.clamp(red)
    self.green = Self.clamp(green)
    self.blue = Self.clamp(blue)
  }

  private enum CodingKeys: String, CodingKey { case red, green, blue }

  /// Clamps on decode too, so a corrupted saved value can never become an out-of-range DDC write.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(red: try c.decode(Int.self, forKey: .red), green: try c.decode(Int.self, forKey: .green), blue: try c.decode(Int.self, forKey: .blue))
  }

  public static func fromReadback(red: UInt16, green: UInt16, blue: UInt16) -> WhiteBalance {
    WhiteBalance(red: toPercent(red), green: toPercent(green), blue: toPercent(blue))
  }

  static func toPercent(_ v: UInt16) -> Int { Int((Double(v) * 100 / 255).rounded()) }
  static func clamp(_ v: Int) -> Int { min(max(v, 0), 100) }

  /// Factory gains R151/G127/B139 (0...255), as percentages.
  public static let factory = WhiteBalance(red: 59, green: 50, blue: 55)
  /// Gains from a measured calibration of the panel towards D65 (Tweakers review, via rliessum's gist).
  public static let reviewD65 = WhiteBalance(red: 50, green: 41, blue: 35)
  /// The same D65 ratio scaled so luminance matches the factory setting (green back at 50%).
  public static let d65KeepBrightness = reviewD65.scaled(toLumaOf: factory)
  /// d65KeepBrightness with red and blue +4, tuned by eye on this panel to cancel the factory
  /// green cast (Hardware Busters also measured green excess at default). The app's default.
  public static let tunedD65 = WhiteBalance(red: 66, green: 50, blue: 47)

  /// Relative luminance of the gains (Rec. 709 weights), in percent units.
  public var luma: Double { 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue) }

  /// Scales all channels by the same factor (keeps the white point). Clamped to 0...100,
  /// so the factor is capped where the strongest channel reaches 100.
  public func scaled(by factor: Double) -> WhiteBalance {
    let top = Double(max(red, green, blue, 1))
    let f = min(max(factor, 0), 100 / top)
    return WhiteBalance(red: Int((Double(red) * f).rounded()), green: Int((Double(green) * f).rounded()), blue: Int((Double(blue) * f).rounded()))
  }

  public func scaled(toLumaOf other: WhiteBalance) -> WhiteBalance {
    guard luma > 0 else { return self }
    return scaled(by: other.luma / luma)
  }
}
