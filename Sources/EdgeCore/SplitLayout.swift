import CoreGraphics
import Foundation

/// Which end of the Edge the dashboard takes in split mode. On a portrait Edge, left means top.
public enum SplitSide: String, Codable, CaseIterable, Sendable {
  case left, right
}

/// Geometry for split mode: the dashboard covers one end of the Edge along its long side and the
/// rest stays a regular display for app windows.
public enum SplitLayout {
  /// Neither part gets narrower than this, so both stay usable.
  public static let minimumLength: CGFloat = 480

  /// The dashboard's length along the display's long side, kept within reach of both parts.
  public static func clampedLength(_ length: Double, in display: CGRect) -> CGFloat {
    let long = max(display.width, display.height)
    guard long >= minimumLength * 2 else { return (long / 2).rounded() }
    return min(max(CGFloat(length), minimumLength), long - minimumLength).rounded()
  }

  /// The part of `display` the dashboard covers. `yDown` is true for Quartz (top-left origin)
  /// rects and false for AppKit (bottom-left origin) rects.
  public static func dashboardRect(in display: CGRect, side: SplitSide, length: Double, yDown: Bool = true) -> CGRect {
    let len = clampedLength(length, in: display)
    if display.width >= display.height {
      let x = side == .left ? display.minX : display.maxX - len
      return CGRect(x: x, y: display.minY, width: len, height: display.height)
    }
    let atTop = side == .left
    let y = atTop == yDown ? display.minY : display.maxY - len
    return CGRect(x: display.minX, y: y, width: display.width, height: len)
  }

  /// The part of `display` left as a regular display.
  public static func freeRect(in display: CGRect, side: SplitSide, length: Double, yDown: Bool = true) -> CGRect {
    let dash = dashboardRect(in: display, side: side, length: length, yDown: yDown)
    if display.width >= display.height {
      let x = dash.minX == display.minX ? dash.maxX : display.minX
      return CGRect(x: x, y: display.minY, width: display.width - dash.width, height: display.height)
    }
    let y = dash.minY == display.minY ? dash.maxY : display.minY
    return CGRect(x: display.minX, y: y, width: display.width, height: display.height - dash.height)
  }

  /// Moves and, if needed, shrinks `rect` so it lies inside `area`, moving it as little as possible.
  public static func fit(_ rect: CGRect, into area: CGRect) -> CGRect {
    let w = min(rect.width, area.width)
    let h = min(rect.height, area.height)
    let x = min(max(rect.minX, area.minX), area.maxX - w)
    let y = min(max(rect.minY, area.minY), area.maxY - h)
    return CGRect(x: x, y: y, width: w, height: h)
  }
}
