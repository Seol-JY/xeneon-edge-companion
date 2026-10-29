import Testing
@testable import EdgeCore

@Suite struct HomeTemperatureTests {
  @Test func parsesShortcutUnitsAndLocales() {
    #expect(HomeTemperature.celsius(from: "20.9°C\n") == 20.9)
    #expect(HomeTemperature.celsius(from: " 20,9 °C ") == 20.9)
    #expect(HomeTemperature.celsius(from: "-5.2℃") == -5.2)
    #expect(HomeTemperature.celsius(from: "68°F") == 20)
    #expect(HomeTemperature.celsius(from: "20.9") == 20.9)
  }
  @Test func rejectsOtherShortcutOutput() {
    for value in ["38%", "Error: 20", "No response", "NaN", "", "20°C 21°C", "200°C", "-100°C"] {
      #expect(HomeTemperature.celsius(from: value) == nil)
    }
  }
}
