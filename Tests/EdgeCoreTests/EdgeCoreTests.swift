import CoreGraphics
import Testing
@testable import EdgeCore

@Suite struct TouchReportTests {
  @Test func parsesWithReportID() {
    let r = TouchReport.parse([0x07, 0x01, 0xFF, 0x3F, 0x7F, 0x25, 0x00])
    #expect(r == TouchReport(isDown: true, x: 16383, y: 9599))
  }

  @Test func parsesWithoutReportID() {
    let r = TouchReport.parse([0x00, 0x10, 0x00, 0x20, 0x00, 0x00])
    #expect(r == TouchReport(isDown: false, x: 16, y: 32))
  }

  @Test func rejectsOtherReports() {
    #expect(TouchReport.parse([0x0D, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == nil)
    #expect(TouchReport.parse([0x07, 0x01]) == nil)
  }
}

@Suite struct CoordinateMapperTests {
  let bounds = CGRect(x: -2560, y: 1692, width: 2560, height: 720)

  @Test func mapsCornersInsideBounds() {
    let m = CoordinateMapper(displayBounds: bounds)
    #expect(m.map(x: 0, y: 0) == CGPoint(x: -2560, y: 1692))
    let far = m.map(x: 16383, y: 9599)
    #expect(far == CGPoint(x: -1, y: 2411))
    #expect(bounds.contains(far))
  }

  @Test func clampsOutOfRange() {
    let m = CoordinateMapper(displayBounds: bounds)
    #expect(bounds.contains(m.map(x: 20000, y: 12000)))
  }

  @Test func rotation180() {
    let m = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 101, height: 11), rotation: 180)
    #expect(m.map(x: 0, y: 0) == CGPoint(x: 100, y: 10))
  }

  @Test func calibrationSolve() throws {
    let cal = try #require(TouchCalibration.solve(
      expected: CGPoint(x: 0.1, y: 0.1), touched: CGPoint(x: 0.12, y: 0.08),
      expected: CGPoint(x: 0.9, y: 0.9), touched: CGPoint(x: 0.92, y: 0.88)))
    let (x, y) = cal.apply(0.12, 0.08)
    #expect(abs(x - 0.1) < 1e-9)
    #expect(abs(y - 0.1) < 1e-9)
  }
}

@Suite struct GestureEngineTests {
  func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

  @Test func tapProducesClick() {
    var g = GestureEngine()
    #expect(g.handle(down: true, point: p(10, 10), time: 0) == [.touchBegan(p(10, 10))])
    #expect(g.handle(down: true, point: p(12, 11), time: 0.02).isEmpty)
    #expect(g.handle(down: false, point: p(12, 11), time: 0.05) == [.click(p(10, 10), clickCount: 1), .touchEnded])
  }

  @Test func doubleTap() {
    var g = GestureEngine()
    _ = g.handle(down: true, point: p(10, 10), time: 0)
    _ = g.handle(down: false, point: p(10, 10), time: 0.05)
    _ = g.handle(down: true, point: p(14, 12), time: 0.2)
    #expect(g.handle(down: false, point: p(14, 12), time: 0.25).first == .click(p(14, 12), clickCount: 2))
  }

  @Test func verticalMoveScrollsWithMomentum() {
    var g = GestureEngine()
    _ = g.handle(down: true, point: p(100, 100), time: 0)
    let began = g.handle(down: true, point: p(100, 130), time: 0.016)
    #expect(began == [.scroll(at: p(100, 100), dx: 0, dy: 30, phase: .began)])
    #expect(g.handle(down: true, point: p(100, 160), time: 0.032) == [.scroll(at: p(100, 160), dx: 0, dy: 30, phase: .changed)])
    let end = g.handle(down: false, point: p(100, 160), time: 0.04)
    #expect(end.contains(.scroll(at: p(100, 160), dx: 0, dy: 0, phase: .ended)))
    #expect(end.contains(.momentum(at: p(100, 160), dx: 0, dy: 0, phase: .began)))
    #expect(g.needsTick)
    var t = 0.04
    var ended = false
    for _ in 0 ..< 600 {
      t += 1.0 / 60
      if g.tick(now: t).contains(where: { if case .momentum(_, _, _, .ended) = $0 { return true } else { return false } }) {
        ended = true
        break
      }
    }
    #expect(ended)
    #expect(!g.needsTick)
  }

  @Test func horizontalMoveDragsWhenEnabled() {
    var cfg = GestureConfig()
    cfg.horizontalMoveDrags = true
    var g = GestureEngine(config: cfg)
    _ = g.handle(down: true, point: p(100, 100), time: 0)
    let a = g.handle(down: true, point: p(140, 102), time: 0.02)
    #expect(a == [.pointerDown(p(100, 100), clickCount: 1), .pointerDrag(p(140, 102))])
    #expect(g.handle(down: false, point: p(150, 102), time: 0.05) == [.pointerUp(p(150, 102), clickCount: 1), .touchEnded])
  }

  @Test func horizontalMoveScrollsByDefault() {
    var g = GestureEngine()
    _ = g.handle(down: true, point: p(100, 100), time: 0)
    #expect(g.handle(down: true, point: p(140, 102), time: 0.02) == [.scroll(at: p(100, 100), dx: 40, dy: 2, phase: .began)])
  }

  @Test func holdThenMoveDrags() {
    var g = GestureEngine()
    _ = g.handle(down: true, point: p(100, 100), time: 0)
    _ = g.handle(down: true, point: p(101, 100), time: 0.35)
    #expect(g.handle(down: true, point: p(140, 100), time: 0.4).first == .pointerDown(p(100, 100), clickCount: 1))
  }

  @Test func longPressRightClicksOnce() {
    var g = GestureEngine()
    _ = g.handle(down: true, point: p(50, 50), time: 0)
    #expect(g.tick(now: 0.3).isEmpty)
    _ = g.handle(down: true, point: p(51, 50), time: 0.5)
    #expect(g.tick(now: 0.6) == [.rightClick(p(50, 50))])
    #expect(g.handle(down: true, point: p(80, 50), time: 0.7).isEmpty)
    #expect(g.handle(down: false, point: p(80, 50), time: 0.8) == [.touchEnded])
  }

  @Test func watchdogReleasesDragWithoutClick() {
    var cfg = GestureConfig()
    cfg.horizontalMoveDrags = true
    var g = GestureEngine(config: cfg)
    _ = g.handle(down: true, point: p(0, 0), time: 0)
    _ = g.handle(down: true, point: p(50, 0), time: 0.02)
    let out = g.tick(now: 2)
    #expect(out == [.pointerUp(p(50, 0), clickCount: 1), .touchEnded])
  }

  @Test func watchdogDropsPendingTapSilently() {
    var g = GestureEngine()
    var cfg = GestureConfig()
    cfg.longPressRightClick = false
    g.config = cfg
    _ = g.handle(down: true, point: p(0, 0), time: 0)
    #expect(g.tick(now: 2) == [.touchEnded])
  }
}

@Suite struct DDCTests {
  @Test func setPacketMatchesKnownGood() {
    // Verified on the panel: writing blue gain 55 read back as 140/255.
    let pkt = DDCPacket.setVCP(0x1A, value: 55)
    var chk: UInt8 = 0x6E ^ 0x51
    for b in [UInt8(0x84), 0x03, 0x1A, 0x00, 55] { chk ^= b }
    #expect(pkt == [0x84, 0x03, 0x1A, 0x00, 55, chk])
  }

  @Test func getPacket() {
    let pkt = DDCPacket.getVCP(0x14)
    #expect(pkt.prefix(3) == [0x82, 0x01, 0x14])
  }

  @Test func parsesReply() {
    var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x16, 0x00, 0x00, 0xFF, 0x00, 0x97, 0]
    var c: UInt8 = 0x50
    for i in 0 ..< 10 { c ^= reply[i] }
    reply[10] = c
    #expect(DDCPacket.parseReply(reply, expecting: 0x16) == .success(.init(vcp: 0x16, current: 151, maximum: 255)))
    reply[10] ^= 1
    #expect(DDCPacket.parseReply(reply, expecting: 0x16) == .failure(.badChecksum))
  }

  @Test func whiteBalanceReadback() {
    #expect(WhiteBalance.fromReadback(red: 151, green: 127, blue: 139) == WhiteBalance(red: 59, green: 50, blue: 55))
    #expect(WhiteBalance(red: 150, green: -3, blue: 50) == WhiteBalance(red: 100, green: 0, blue: 50))
  }

  @Test func keepBrightnessPreset() {
    #expect(WhiteBalance.d65KeepBrightness == WhiteBalance(red: 62, green: 50, blue: 43))
    #expect(abs(WhiteBalance.d65KeepBrightness.luma - WhiteBalance.factory.luma) < 1)
  }

  @Test func scalingCapsAtFullGain() {
    #expect(WhiteBalance(red: 80, green: 40, blue: 20).scaled(by: 2) == WhiteBalance(red: 100, green: 50, blue: 25))
  }

}

@Suite struct PointerMathTests {
  // This Mac: 6K main on top, built-in to its upper left, Edge below the main display.
  let main = CGRect(x: 0, y: 0, width: 3008, height: 1692)
  let builtIn = CGRect(x: -1710, y: 0, width: 1710, height: 1107)
  let edge = CGRect(x: 273, y: 1692, width: 2560, height: 720)
  var all: [CGRect] { [main, builtIn, edge] }

  @Test func fenceClampsJustOutsideNearestEdge() {
    let p = PointerMath.fenceClamp(CGPoint(x: 400, y: 1700), fenced: edge, lastOutside: CGPoint(x: 380, y: 1650), displays: all, fallback: main)
    #expect(p == CGPoint(x: 400, y: 1691))
  }

  @Test func fenceDeepPointStillReturnsToNeighbour() {
    let p = PointerMath.fenceClamp(CGPoint(x: 1500, y: 2300), fenced: edge, lastOutside: nil, displays: all, fallback: main)
    #expect(p == CGPoint(x: 1500, y: 1691))
  }

  @Test func fenceFallsBackToMainCentre() {
    let lonely = CGRect(x: 5000, y: 5000, width: 100, height: 100)
    let p = PointerMath.fenceClamp(CGPoint(x: 5050, y: 5050), fenced: lonely, lastOutside: nil, displays: [main, lonely], fallback: main)
    #expect(p == CGPoint(x: main.midX, y: main.midY))
  }

  @Test func dockClampKeepsPointerOffEdgeBottom() {
    #expect(PointerMath.dockClamp(CGPoint(x: 1000, y: 2411), displays: all, blocked: [edge], edge: .bottom) == CGPoint(x: 1000, y: 2408))
    #expect(PointerMath.dockClamp(CGPoint(x: 1000, y: 2300), displays: all, blocked: [edge], edge: .bottom) == nil)
  }

  @Test func dockClampLeavesOtherDisplaysAlone() {
    // The Dock may still go to the built-in or the main display.
    #expect(PointerMath.dockClamp(CGPoint(x: -800, y: 1106), displays: all, blocked: [edge], edge: .bottom) == nil)
    #expect(PointerMath.dockClamp(CGPoint(x: 100, y: 1691), displays: all, blocked: [edge], edge: .bottom) == nil)
  }

  @Test func dockTriggerUsesLongestFreeStretchOfMainBottom() {
    // Main's bottom is shared with the Edge from x 273 to 2833; free stretches are 0–273 and 2833–3008.
    let p = PointerMath.dockTriggerPoint(on: main, edge: .bottom, displays: all)
    #expect(p?.y == 1691)
    #expect((p?.x ?? -1) > 100 && (p?.x ?? -1) < 180)
  }

  @Test func dockTriggerNilWhenEdgeFullyShared() {
    let top = CGRect(x: 0, y: 0, width: 100, height: 100)
    let below = CGRect(x: -50, y: 100, width: 200, height: 100)
    #expect(PointerMath.dockTriggerPoint(on: top, edge: .bottom, displays: [top, below]) == nil)
  }

  @Test func dockClampSkipsSharedEdges() {
    // The built-in's right edge touches the main display: crossing must stay possible.
    #expect(PointerMath.dockClamp(CGPoint(x: -1, y: 500), displays: all, blocked: [builtIn], edge: .right) == nil)
    // Its left edge is free, so a left Dock is kept off it.
    #expect(PointerMath.dockClamp(CGPoint(x: -1710, y: 500), displays: all, blocked: [builtIn], edge: .left) == CGPoint(x: -1707, y: 500))
  }
}

@Suite struct GridLayoutTests {
  typealias P = GridLayout.Placement

  @Test func smallWidgetsFillColumnByColumn() {
    let r = GridLayout.pack([.small, .small, .small, .small])
    #expect(r.columnCount == 2)
    #expect(r.placements.map { [$0.column, $0.row] } == [[0, 0], [0, 1], [1, 0], [1, 1]])
  }

  @Test func tallTakesWholeColumn() {
    let r = GridLayout.pack([.tall, .small, .small])
    #expect(r.placements[0] == P(index: 0, column: 0, row: 0, columns: 1, rows: 2))
    #expect(r.placements[1].column == 1 && r.placements[2].column == 1)
    #expect(r.columnCount == 2)
  }

  @Test func wideAndLarge() {
    let r = GridLayout.pack([.small, .wide, .large, .small])
    // small at (0,0); wide can't fit at column 0 row 1 (needs 2 columns, column 0 row 1 and column 1 row 1 free) → fits at (0,1)
    #expect(r.placements[0] == P(index: 0, column: 0, row: 0, columns: 1, rows: 1))
    #expect(r.placements[1] == P(index: 1, column: 0, row: 1, columns: 2, rows: 1))
    #expect(r.placements[2] == P(index: 2, column: 2, row: 0, columns: 2, rows: 2))
    #expect(r.placements[3] == P(index: 3, column: 1, row: 0, columns: 1, rows: 1))
    #expect(r.columnCount == 4)
  }

  @Test func emptyIsZeroColumns() {
    #expect(GridLayout.pack([]).columnCount == 0)
  }
}

@Suite struct SplitLayoutTests {
  let edge = CGRect(x: -2560, y: 1692, width: 2560, height: 720)

  @Test func landscapeRightAndLeft() {
    let right = SplitLayout.dashboardRect(in: edge, side: .right, length: 1000)
    #expect(right == CGRect(x: -1000, y: 1692, width: 1000, height: 720))
    #expect(SplitLayout.freeRect(in: edge, side: .right, length: 1000) == CGRect(x: -2560, y: 1692, width: 1560, height: 720))
    let left = SplitLayout.dashboardRect(in: edge, side: .left, length: 1000)
    #expect(left == CGRect(x: -2560, y: 1692, width: 1000, height: 720))
    #expect(SplitLayout.freeRect(in: edge, side: .left, length: 1000) == CGRect(x: -1560, y: 1692, width: 1560, height: 720))
  }

  @Test func clampsLengthSoBothPartsStayUsable() {
    #expect(SplitLayout.dashboardRect(in: edge, side: .left, length: 100).width == 480)
    #expect(SplitLayout.dashboardRect(in: edge, side: .left, length: 5000).width == 2080)
  }

  @Test func portraitSplitsTopAndBottomInBothCoordinateSystems() {
    let portrait = CGRect(x: 0, y: 0, width: 720, height: 2560)
    // Quartz: y grows downward, so top is minY.
    #expect(SplitLayout.dashboardRect(in: portrait, side: .left, length: 800) == CGRect(x: 0, y: 0, width: 720, height: 800))
    #expect(SplitLayout.dashboardRect(in: portrait, side: .right, length: 800) == CGRect(x: 0, y: 1760, width: 720, height: 800))
    // AppKit: y grows upward, so top is maxY.
    #expect(SplitLayout.dashboardRect(in: portrait, side: .left, length: 800, yDown: false) == CGRect(x: 0, y: 1760, width: 720, height: 800))
    #expect(SplitLayout.freeRect(in: portrait, side: .left, length: 800) == CGRect(x: 0, y: 800, width: 720, height: 1760))
  }

  @Test func fenceAroundSplitDashboardReturnsPointerToRegularPart() {
    let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let edge = CGRect(x: 0, y: 1440, width: 2560, height: 720)
    let fence = SplitLayout.dashboardRect(in: edge, side: .right, length: 1000)
    let p = PointerMath.fenceClamp(CGPoint(x: 1600, y: 1800), fenced: fence, lastOutside: nil, displays: [main, edge], fallback: main)
    #expect(p == CGPoint(x: 1559, y: 1800))
  }

  @Test func fitMovesThenShrinks() {
    let area = CGRect(x: 0, y: 30, width: 1500, height: 690)
    // Reaching past the right edge: slides left, keeps its size.
    #expect(SplitLayout.fit(CGRect(x: 1200, y: 100, width: 600, height: 400), into: area) == CGRect(x: 900, y: 100, width: 600, height: 400))
    // Bigger than the area: shrinks to it.
    #expect(SplitLayout.fit(CGRect(x: -10, y: 0, width: 2560, height: 720), into: area) == area)
    // Already inside: unchanged.
    let inside = CGRect(x: 10, y: 40, width: 100, height: 100)
    #expect(SplitLayout.fit(inside, into: area) == inside)
  }
}

@Suite struct MenuBarInsetTests {
  @Test func dropsTheMenuBarStripInBothCoordinateSystems() {
    let quartz = CGRect(x: 1127, y: 1600, width: 2560, height: 720)
    let dash = SplitLayout.dashboardRect(in: quartz, side: .right, length: 480)
    #expect(SplitLayout.belowMenuBar(dash, display: quartz, menuBar: 30) == CGRect(x: 3207, y: 1630, width: 480, height: 690))
    let appKit = CGRect(x: 1127, y: -720, width: 2560, height: 720)
    let dashAK = SplitLayout.dashboardRect(in: appKit, side: .right, length: 480, yDown: false)
    #expect(SplitLayout.belowMenuBar(dashAK, display: appKit, menuBar: 30, yDown: false) == CGRect(x: 3207, y: -720, width: 480, height: 690))
    // Auto-hidden menu bar: unchanged.
    #expect(SplitLayout.belowMenuBar(dash, display: quartz, menuBar: 0) == dash)
  }
}
