import Foundation

/// Text returned by a Home “Get State” shortcut. Store a canonical Celsius value.
public enum HomeTemperature {
  public static func celsius(from output: String) -> Double? {
    let pattern = #"^\s*([+-]?[0-9]+(?:[.,][0-9]+)?)\s*(?:°\s*)?([CF℃℉])?\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
          let range = Range(match.range(at: 1), in: output),
          let number = Double(output[range].replacingOccurrences(of: ",", with: ".")) else { return nil }
    let unit = Range(match.range(at: 2), in: output).map { output[$0].uppercased() } ?? "C"
    let celsius = unit == "F" || unit == "℉" ? (number - 32) * 5 / 9 : number
    guard celsius.isFinite, (-50...80).contains(celsius) else { return nil }
    return celsius
  }
}

public struct HomeTemperatureSample: Codable, Equatable, Sendable {
  public let date: Date
  public let celsius: Double
  public init(date: Date, celsius: Double) { self.date = date; self.celsius = celsius }
}
