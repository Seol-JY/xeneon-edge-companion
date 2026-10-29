import Foundation
import Testing
@testable import EdgeCore

@Suite struct TerminalColumnTests {
  @Test func customWidthKeepsOtherColumnsEqualAndWithinPage() {
    let m = GridLayout.columnMetrics(count: 5, width: 2532, gap: 14, fixedColumn: 2, fixedWidth: 840)
    #expect(m.widths[2] == 840)
    #expect(m.widths[0] == m.widths[4])
    #expect(abs(m.origins[4] + m.widths[4] - 2532) < 0.001)
    for i in 1..<5 { #expect(m.origins[i] >= m.origins[i-1] + m.widths[i-1]) }
  }

  @Test func narrowScreenClampsTerminalWithoutNegativeWidgetWidths() {
    let m = GridLayout.columnMetrics(count: 5, width: 720, gap: 14, fixedColumn: 0, fixedWidth: 1900)
    #expect(m.widths.allSatisfy { $0 > 0 })
    #expect(abs(m.origins[4] + m.widths[4] - 720) < 0.001)
  }

  @Test func editorMatchesRealLayoutWhenScaled() {
    let actual = GridLayout.columnMetrics(count: 5, width: 2532, gap: 14, fixedColumn: 2, fixedWidth: 840)
    let preview = GridLayout.columnMetrics(count: 5, width: 506.4, gap: 2.8, fixedColumn: 2,
                                          fixedWidth: 168, minimumColumnWidth: 36)
    for i in 0..<5 {
      #expect(abs(preview.widths[i] - actual.widths[i] * 0.2) < 0.001)
      #expect(abs(preview.origins[i] - actual.origins[i] * 0.2) < 0.001)
    }
  }
}
