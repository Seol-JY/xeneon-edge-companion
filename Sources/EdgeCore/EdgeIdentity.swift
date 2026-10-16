import Foundation

/// Hardware identifiers for the Corsair XENEON EDGE, verified on this machine with ioreg.
public enum EdgeIdentity {
  /// EDID manufacturer "CRX" as reported by `CGDisplayVendorNumber`.
  public static let displayVendor: UInt32 = 0x0E58
  /// `CGDisplayModelNumber`.
  public static let displayModel: UInt32 = 0xED00
  /// `CGDisplaySerialNumber` is a placeholder (0x01010101) and must not be used to tell panels apart.
  public static let placeholderSerial: UInt32 = 0x0101_0101
  public static let productName = "XENEON EDGE"
  public static let nativeSize = CGSize(width: 2560, height: 720)

  /// WCH touch controller. Touch data arrives on its mouse-emulation interface.
  public static let touchVendorID = 0x27C0
  public static let touchProductID = 0x0859

  /// Corsair control interface (vendor page 0xFF1B). We only use it as a presence signal.
  public static let controlVendorID = 0x1B1C
  public static let controlProductID = 0x1D0D
}
