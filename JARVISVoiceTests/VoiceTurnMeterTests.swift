import XCTest
@testable import JARVIS

final class VoiceTurnMeterTests: XCTestCase {
    func testTurnFixtures() {
        let report = VoiceTurnFixtures.run()
        XCTAssertTrue(report.passed, report.lines.joined(separator: "\n"))
    }

    func testSemanticEndOfTurn() {
        let finishedScore = SemanticTurn.probability("That is all.")
        let unfinishedScore = SemanticTurn.probability("and then")
        XCTAssertGreaterThanOrEqual(finishedScore, TurnEagerness.medium.unlikelyThreshold)
        XCTAssertLessThan(unfinishedScore, TurnEagerness.high.unlikelyThreshold)
        XCTAssertLessThan(SemanticTurn.probability("uhhm"), 0.2)

        let finished = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .medium, endProbability: finishedScore)
        XCTAssertEqual(finished, 650)

        let medium = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .medium, endProbability: unfinishedScore)
        let high = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .high, endProbability: unfinishedScore)
        let low = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.65, eagerness: .low, endProbability: unfinishedScore)
        XCTAssertGreaterThan(medium, finished)
        XCTAssertLessThan(high, medium)
        XCTAssertGreaterThan(low, medium)
        XCTAssertLessThanOrEqual(high, TurnEagerness.high.maxTimeoutMs)
        XCTAssertLessThanOrEqual(medium, TurnEagerness.medium.maxTimeoutMs)
        XCTAssertLessThanOrEqual(low, TurnEagerness.low.maxTimeoutMs)
        XCTAssertEqual(TurnEagerness.high.maxTimeoutMs, 2_000)
        XCTAssertEqual(TurnEagerness.medium.maxTimeoutMs, 4_000)
        XCTAssertEqual(TurnEagerness.low.maxTimeoutMs, 8_000)
        XCTAssertEqual(SemanticTurn.fillerAfterMs, 1_200)
    }

    func testMissingTranscriptWaits() {
        let wait = VoiceTurnMeter.endpointDelayMs(minSeconds: 0.85, eagerness: .low, endProbability: nil)
        let finished = VoiceTurnMeter.endpointDelayMs(
            minSeconds: 0.85, eagerness: .low, endProbability: SemanticTurn.probability("That is all."))
        XCTAssertGreaterThanOrEqual(wait, 2_000)
        XCTAssertGreaterThan(wait, finished)
        XCTAssertEqual(finished, 850)
        XCTAssertGreaterThanOrEqual(finished, VoiceTurnMeter.minimumHangoverMs)
    }
}
