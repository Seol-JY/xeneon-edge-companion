import Foundation

/// One Euro filter (Casiez et al. 2012): low jitter when still, low lag when moving.
public struct OneEuroFilter: Sendable {
  public var minCutoff: Double
  public var beta: Double
  public var derivativeCutoff: Double

  private var lastValue: Double?
  private var lastDerivative: Double = 0
  private var lastTime: TimeInterval?

  public init(minCutoff: Double = 1.7, beta: Double = 0.02, derivativeCutoff: Double = 1.0) {
    self.minCutoff = minCutoff
    self.beta = beta
    self.derivativeCutoff = derivativeCutoff
  }

  public mutating func reset() {
    lastValue = nil
    lastTime = nil
    lastDerivative = 0
  }

  public mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
    guard let prev = lastValue, let prevTime = lastTime, time > prevTime else {
      lastValue = value
      lastTime = time
      return value
    }
    let dt = time - prevTime
    let derivative = (value - prev) / dt
    let smoothedDerivative = Self.lerp(lastDerivative, derivative, Self.alpha(cutoff: derivativeCutoff, dt: dt))
    let cutoff = minCutoff + beta * abs(smoothedDerivative)
    let result = Self.lerp(prev, value, Self.alpha(cutoff: cutoff, dt: dt))
    lastValue = result
    lastDerivative = smoothedDerivative
    lastTime = time
    return result
  }

  private static func alpha(cutoff: Double, dt: Double) -> Double {
    let tau = 1 / (2 * Double.pi * cutoff)
    return 1 / (1 + tau / dt)
  }

  private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
