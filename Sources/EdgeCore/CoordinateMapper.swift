import CoreGraphics
import Foundation

/// Maps raw controller coordinates onto a display's rectangle in global Quartz points
/// (top-left origin, the space `CGDisplayBounds` and `CGEvent.location` use).
public struct CoordinateMapper: Equatable, Sendable {
  public var displayBounds: CGRect
  /// `CGDisplayRotation` in degrees (0, 90, 180, 270).
  public var rotation: Int
  public var maxX: Double
  public var maxY: Double
  /// Optional user calibration applied in normalized space before rotation.
  public var calibration: TouchCalibration

  public init(displayBounds: CGRect, rotation: Int = 0, maxX: Double = Double(TouchReport.defaultMaxX), maxY: Double = Double(TouchReport.defaultMaxY), calibration: TouchCalibration = .identity) {
    self.displayBounds = displayBounds
    self.rotation = rotation
    self.maxX = max(maxX, 1)
    self.maxY = max(maxY, 1)
    self.calibration = calibration
  }

  public func map(x: UInt16, y: UInt16) -> CGPoint {
    var nx = clamp01(Double(x) / maxX)
    var ny = clamp01(Double(y) / maxY)
    (nx, ny) = calibration.apply(nx, ny)
    switch ((rotation % 360) + 360) % 360 {
    case 90: (nx, ny) = (ny, 1 - nx)
    case 180: (nx, ny) = (1 - nx, 1 - ny)
    case 270: (nx, ny) = (1 - ny, nx)
    default: break
    }
    // Stay one point inside the far edges so a touch on the border never lands on the neighbouring display.
    let b = displayBounds
    let px = b.minX + nx * max(b.width - 1, 0)
    let py = b.minY + ny * max(b.height - 1, 0)
    return CGPoint(x: px, y: py)
  }

  private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// Linear per-axis correction (scale and offset in normalized units), with optional axis flips.
public struct TouchCalibration: Codable, Equatable, Sendable {
  public var scaleX: Double
  public var scaleY: Double
  public var offsetX: Double
  public var offsetY: Double
  public var flipX: Bool
  public var flipY: Bool

  public static let identity = TouchCalibration(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0, flipX: false, flipY: false)

  public init(scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double, flipX: Bool, flipY: Bool) {
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.offsetX = offsetX
    self.offsetY = offsetY
    self.flipX = flipX
    self.flipY = flipY
  }

  func apply(_ x: Double, _ y: Double) -> (Double, Double) {
    var nx = flipX ? 1 - x : x
    var ny = flipY ? 1 - y : y
    nx = min(max(nx * scaleX + offsetX, 0), 1)
    ny = min(max(ny * scaleY + offsetY, 0), 1)
    return (nx, ny)
  }

  /// Solves the calibration from two touched targets with known normalized positions
  /// (for example points at 10% and 90% of each axis).
  public static func solve(expected a: CGPoint, touched ta: CGPoint, expected b: CGPoint, touched tb: CGPoint) -> TouchCalibration? {
    let dxT = tb.x - ta.x
    let dyT = tb.y - ta.y
    guard abs(dxT) > 0.05, abs(dyT) > 0.05 else { return nil }
    let sx = (b.x - a.x) / dxT
    let sy = (b.y - a.y) / dyT
    guard sx > 0.5, sx < 1.5, sy > 0.5, sy < 1.5 else { return nil }
    return TouchCalibration(scaleX: sx, scaleY: sy, offsetX: a.x - ta.x * sx, offsetY: a.y - ta.y * sy, flipX: false, flipY: false)
  }
}
