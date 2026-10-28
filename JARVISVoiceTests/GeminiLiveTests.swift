import XCTest
@testable import JARVIS

final class GeminiLiveTests: XCTestCase {
    func testTextSetupCarriesPersonaAndTools() {
        let tool: JSONValue = .object([
            "type": .string("function"),
            "function": .object([
                "name": .string("web_search"),
                "description": .string("Search the web"),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object(["type": .string("string")])]),
                    "required": .array([.string("query")]),
                ]),
            ]),
        ])
        let declarations = LiveWire.declarations(from: [tool])
        let text = LiveWire.setup(instruction: "You are JARVIS. Known: the gate code.", declarations: declarations, modality: .text)
        XCTAssertTrue(text.contains("gemini-3.8-live"))
        XCTAssertTrue(text.contains("\"TEXT\""))
        XCTAssertTrue(text.contains("You are JARVIS"))
        XCTAssertTrue(text.contains("web_search"))
        XCTAssertTrue(text.contains("BLOCKING"))
        XCTAssertTrue(text.contains("silenceDurationMs"))
        XCTAssertTrue(text.contains("600"))
        XCTAssertTrue(text.contains("START_SENSITIVITY_HIGH"))
        XCTAssertTrue(text.contains("END_SENSITIVITY_LOW"))
        XCTAssertFalse(text.contains("END_SENSITIVITY_HIGH"))
        XCTAssertFalse(text.contains("outputAudioTranscription"))
        XCTAssertFalse(LiveWire.rejectsText("setup accepted"))
    }

    func testAudioTranscriptIsTheFallbackWhenTextIsRejected() {
        XCTAssertTrue(LiveWire.rejectsText("Request contains an invalid argument: response modalities. Model only supports AUDIO."))
        let audio = LiveWire.setup(instruction: "You are JARVIS.", declarations: [], modality: .audioTranscript)
        XCTAssertTrue(audio.contains("\"AUDIO\""))
        XCTAssertTrue(audio.contains("outputAudioTranscription"))
        XCTAssertTrue(audio.contains("inputAudioTranscription"))
        XCTAssertFalse(audio.contains("\"TEXT\""))
    }

    func testTranscriptIsSpokenInClausesAndAudioBytesAreIgnored() {
        let message = """
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"aaaa","mimeType":"audio/pcm"}}]},"outputTranscription":{"text":"Hello there, this is the rest of the sentence."}}}
        """.data(using: .utf8)!
        var reducer = LiveTurnReducer()
        let effects = LiveMessages.parse(message).flatMap { reducer.apply($0) }
        XCTAssertEqual(effects, [
            .speak("Hello there,"),
            .speak("this is the rest of the sentence."),
        ])
    }

    func testInterruptionAndActivityStartStopPlayback() {
        var reducer = LiveTurnReducer()
        _ = reducer.apply(.outputTranscript("I was still talking about the booking and the time."))
        let interrupted = reducer.apply(.interrupted)
        XCTAssertEqual(interrupted, [.interrupt])
        let started = reducer.apply(.activityStart)
        XCTAssertEqual(started, [.speechStart, .interrupt])
        XCTAssertEqual(reducer.apply(.activityEnd), [.speechEnd])
        XCTAssertEqual(reducer.apply(.turnComplete), [])
    }

    func testSimpleTurnsUseAShortReflex() {
        XCTAssertEqual(LiveReflex.line(for: "Hello"), "Hello, Sir.")
        XCTAssertEqual(LiveReflex.line(for: "Thank you."), "Of course, Sir.")
        XCTAssertNil(LiveReflex.line(for: "Book a table for four and ask about the window."))

        var greeting = LiveTurnReducer()
        XCTAssertEqual(greeting.apply(.inputTranscript("Hello")), [.user("Hello")])
        XCTAssertEqual(greeting.apply(.activityEnd), [
            .speechEnd,
            .userFinal("Hello"),
            .speak("Hello, Sir."),
        ])
        XCTAssertEqual(greeting.apply(.modelText("Good evening. How can I help?")), [])
        XCTAssertEqual(greeting.apply(.turnComplete), [])

        var late = LiveTurnReducer()
        XCTAssertEqual(late.apply(.activityEnd), [.speechEnd])
        XCTAssertEqual(late.apply(.inputTranscript("Thank you")), [
            .user("Thank you"),
            .userFinal("Thank you"),
            .speak("Of course, Sir."),
        ])
        XCTAssertEqual(late.apply(.outputTranscript("You are most welcome, Sir.")), [])
    }

    func testModelTextWinsOverADuplicateTranscript() {
        var reducer = LiveTurnReducer()
        let spoken = reducer.apply(.modelText("The meeting is at four."))
        XCTAssertEqual(spoken, [.speak("The meeting is at four.")])
        XCTAssertEqual(reducer.apply(.outputTranscript("The meeting is at four.")), [])
    }

    func testToolCallKeepsTheArguments() {
        let message = """
        {"toolCall":{"functionCalls":[{"id":"call_1","name":"calendar_list_events","args":{"days":1}}]}}
        """.data(using: .utf8)!
        let events = LiveMessages.parse(message)
        XCTAssertEqual(events.count, 1)
        guard case .toolCall(let id, let name, let arguments) = events[0] else {
            return XCTFail("expected a tool call")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "calendar_list_events")
        XCTAssertTrue(arguments.contains("days"))
    }

    func testMicrophonePCMIs16kWithoutDroppingSamples() {
        let pcm = LivePCM.int16([1, 1, 1], sourceRate: 48_000)
        XCTAssertEqual(pcm.count, 2)
        let native = LivePCM.int16([0.5, -0.5, 0], sourceRate: 16_000)
        XCTAssertEqual(native.count, 6)
        XCTAssertTrue(LivePCM.int16([], sourceRate: 48_000).isEmpty)
        XCTAssertTrue(LivePCM.int16([1], sourceRate: 0).isEmpty)
    }

    func testDownsampleAveragesAToneThatWouldAlias() {
        var samples: [Float] = []
        for index in 0..<48 {
            samples.append(index.isMultiple(of: 2) ? 1 : -1)
        }
        let pcm = LivePCM.int16(samples, sourceRate: 48_000)
        XCTAssertEqual(pcm.count, 32)
        let first = pcm.withUnsafeBytes { raw in
            Int(Int16(littleEndian: raw.loadUnaligned(as: Int16.self)))
        }
        XCTAssertLessThan(abs(first), 20_000)
    }

    func testDebugDetailDropsNumbersAndTokens() {
        let text = VoiceDebugLog.safe("ring +44 7700 900123 access_token=ephemeral-secret")
        XCTAssertFalse(text.contains("7700"))
        XCTAssertFalse(text.contains("ephemeral-secret"))
        XCTAssertTrue(text.contains("[number]"))
        XCTAssertTrue(text.contains("access_token redacted"))
    }
}
