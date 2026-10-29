import Foundation

/// Widget footprint in grid cells on the two-row dashboard.
public enum WidgetSize: String, Codable, CaseIterable, Sendable {
  case small    // 1 × 1
  case wide     // 2 × 1
  case tall     // 1 × 2
  case large    // 2 × 2

  public var columns: Int { self == .wide || self == .large ? 2 : 1 }
  public var rows: Int { self == .tall || self == .large ? 2 : 1 }
}

/// Packs widgets into a grid with a fixed number of rows, filling column by column so the reading
/// order matches the list order (top-to-bottom, then left-to-right). The grid grows to the right.
public enum GridLayout {
  public struct Placement: Equatable, Sendable {
    public var index: Int
    public var column: Int
    public var row: Int
    public var columns: Int
    public var rows: Int
  }

  public struct Result: Equatable, Sendable {
    public var placements: [Placement]
    /// Columns actually used.
    public var columnCount: Int
  }

  /// Shared by the dashboard and its scaled editor preview. A full-height terminal occupies
  /// one column with a point-based width; the remaining columns share the available space.
  public struct ColumnMetrics {
    public var widths: [CGFloat]
    public var origins: [CGFloat]
  }

  public static func columnMetrics(count: Int, width: CGFloat, gap: CGFloat,
                                   fixedColumn: Int? = nil, fixedWidth: CGFloat = 0,
                                   minimumColumnWidth: CGFloat = 180) -> ColumnMetrics {
    guard count > 0 else { return ColumnMetrics(widths: [], origins: []) }
    let available = max(0, width - gap * CGFloat(count - 1))
    var widths = Array(repeating: available / CGFloat(count), count: count)
    if let column = fixedColumn, widths.indices.contains(column) {
      let otherCount = count - 1
      // Keep ordinary widgets usable when the display is narrower than the saved preference.
      let minimum = min(max(0, minimumColumnWidth), available / CGFloat(count))
      let terminal = min(max(0, fixedWidth), max(0, available - minimum * CGFloat(otherCount)))
      widths = Array(repeating: otherCount > 0 ? (available - terminal) / CGFloat(otherCount) : 0, count: count)
      widths[column] = terminal
    }
    var x: CGFloat = 0
    let origins = widths.map { value -> CGFloat in
      defer { x += value + gap }
      return x
    }
    return ColumnMetrics(widths: widths, origins: origins)
  }

  public static func pack(_ sizes: [WidgetSize], rows: Int = 2) -> Result {
    var occupied: [[Bool]] = []   // [column][row]
    func free(_ c: Int, _ r: Int) -> Bool { c >= occupied.count || !occupied[c][r] }
    func fits(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
      guard r + h <= rows else { return false }
      for dc in 0 ..< w { for dr in 0 ..< h where !free(c + dc, r + dr) { return false } }
      return true
    }
    func occupy(_ c: Int, _ r: Int, _ w: Int, _ h: Int) {
      while occupied.count < c + w { occupied.append(Array(repeating: false, count: rows)) }
      for dc in 0 ..< w { for dr in 0 ..< h { occupied[c + dc][r + dr] = true } }
    }

    var placements: [Placement] = []
    for (index, size) in sizes.enumerated() {
      let w = size.columns
      let h = min(size.rows, rows)
      var placed = false
      var c = 0
      while !placed {
        for r in 0 ..< rows where fits(c, r, w, h) {
          occupy(c, r, w, h)
          placements.append(Placement(index: index, column: c, row: r, columns: w, rows: h))
          placed = true
          break
        }
        c += 1
      }
    }
    return Result(placements: placements, columnCount: occupied.count)
  }
}
