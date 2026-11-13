import XCTest
@testable import JARVIS

final class LiveEchoTests: XCTestCase {
    private let george = "The weather in Ashford is twelve degrees with light rain this evening, Sir."

    func testGeorgeHeardThroughTheSpeakerIsEcho() {
        XCTAssertEqual(LiveEcho.verdict(heard: "the weather in Ashford is twelve degrees", spoken: george), .echo)
        XCTAssertEqual(LiveEcho.verdict(heard: "light rain this evening sir", spoken: george), .echo)
    }

    func testTheUserTalkingOverGeorgeIsTheUser() {
        XCTAssertEqual(LiveEcho.verdict(heard: "what about tomorrow morning", spoken: george), .user)
        XCTAssertEqual(LiveEcho.verdict(heard: "book me a taxi", spoken: george), .user)
    }

    func testStopWordsAlwaysInterrupt() {
        XCTAssertEqual(LiveEcho.verdict(heard: "stop", spoken: george), .user)
        XCTAssertEqual(LiveEcho.verdict(heard: "wait", spoken: george), .user)
        XCTAssertEqual(LiveEcho.verdict(heard: "hang on", spoken: george), .user)
    }

    func testAStopWordGeorgeJustSaidIsNotAnInterruption() {
        let line = "Please wait while I check the booking."
        XCTAssertEqual(LiveEcho.verdict(heard: "please wait while I check", spoken: line), .echo)
    }

    func testOneOrTwoMatchingWordsWaitForMore() {
        XCTAssertEqual(LiveEcho.verdict(heard: "the weather", spoken: george), .undecided)
        XCTAssertEqual(LiveEcho.verdict(heard: "", spoken: george), .undecided)
    }

    func testNothingSpokenMeansTheUser() {
        XCTAssertEqual(LiveEcho.verdict(heard: "the weather", spoken: ""), .user)
    }

    func testLivePauseHasAFloorSoPeopleAreNotCutOff() {
        XCTAssertEqual(LiveWire.silenceMs(endpointSilence: 0.55), 800)
        XCTAssertEqual(LiveWire.silenceMs(endpointSilence: 0.65), 800)
        XCTAssertEqual(LiveWire.silenceMs(endpointSilence: 1.0), 1150)
        XCTAssertEqual(LiveWire.silenceMs(endpointSilence: 3.0), 1400)
        let setup = LiveWire.setup(instruction: "You are JARVIS.", declarations: [], modality: .text, silenceMs: 950)
        XCTAssertTrue(setup.contains("950"))
    }
}
