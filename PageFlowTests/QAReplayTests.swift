#if DEBUG
import Foundation
import Testing
@testable import PageFlow

@MainActor
struct QAReplayTests {
    @Test("a replay cannot pass without gestures and actual geometry samples")
    func missingMeasurementsFail() {
        var result = QAReplay.ScenarioResult(scenario: "scroll-read", document: "fixture")
        result.validate()
        #expect(!result.passed)
        #expect(result.failures.count == 2)
    }

    @Test("a measured movement of one point, or an invalid value, fails acceptance",
          arguments: [CGFloat(1), 1.1, .infinity, .nan, -1])
    func invalidMovementFails(_ movement: CGFloat) {
        var result = QAReplay.ScenarioResult(scenario: "scroll-read", document: "fixture")
        result.gestures = 1
        result.measuredSamples = 1
        result.maxIdleDrift = movement
        result.validate()
        #expect(!result.passed)
    }

    @Test("valid stationary measurements can pass and be written as JSON")
    func measuredRunPasses() throws {
        var result = QAReplay.ScenarioResult(scenario: "scroll-read", document: "fixture")
        result.gestures = 1
        result.measuredSamples = 1
        result.maxInteractionShift = 0.9
        result.validate()
        #expect(result.passed)
        let decoded = try JSONDecoder().decode(QAReplay.ScenarioResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.measuredSamples == 1)
        #expect(decoded.passed)
    }
}
#endif
