import XCTest
@testable import Dictate_Anywhere

final class AssemblyAIStreamingTests: XCTestCase {
    func testLaterTurnMessagesReplaceEarlierOnesForTheSameTurn() {
        var transcript = AssemblyAIStreamingTranscript(languageCode: "en")
        transcript.apply(order: 0, transcript: "hello", endOfTurn: false, isFormatted: false)
        transcript.apply(order: 0, transcript: "hello world", endOfTurn: true, isFormatted: false)
        transcript.apply(order: 0, transcript: "Hello world.", endOfTurn: true, isFormatted: true)
        transcript.apply(order: 1, transcript: "second", endOfTurn: false, isFormatted: false)
        XCTAssertEqual(transcript.text, "Hello world. second")
        XCTAssertTrue(transcript.hasOpenTurn)
        transcript.apply(order: 1, transcript: "Second turn.", endOfTurn: true, isFormatted: true)
        XCTAssertEqual(transcript.text, "Hello world. Second turn.")
        XCTAssertFalse(transcript.hasOpenTurn)
        XCTAssertEqual(transcript.turnCount, 2)
    }

    func testFormattedFinalIsNeverDowngradedByALateMessage() {
        var transcript = AssemblyAIStreamingTranscript(languageCode: "en")
        transcript.apply(order: 0, transcript: "Hello world.", endOfTurn: true, isFormatted: true)
        transcript.apply(order: 0, transcript: "hello world", endOfTurn: true, isFormatted: false)
        XCTAssertEqual(transcript.text, "Hello world.")
    }

    func testTurnsJoinInOrderAndSkipEmptyFinals() {
        var transcript = AssemblyAIStreamingTranscript(languageCode: "en")
        transcript.apply(order: 2, transcript: "Third.", endOfTurn: true, isFormatted: true)
        transcript.apply(order: 0, transcript: "First.", endOfTurn: true, isFormatted: true)
        transcript.apply(order: 1, transcript: "  ", endOfTurn: true, isFormatted: true)
        XCTAssertEqual(transcript.text, "First. Third.")
    }

    func testCJKTurnsJoinWithoutSpaces() {
        var transcript = AssemblyAIStreamingTranscript(languageCode: "zh")
        transcript.apply(order: 0, transcript: "你好。", endOfTurn: true, isFormatted: true)
        transcript.apply(order: 1, transcript: "再见。", endOfTurn: true, isFormatted: true)
        XCTAssertEqual(transcript.text, "你好。再见。")
    }

    func testStreamingKeytermsRespectDocumentedLimits() {
        let long = String(repeating: "x", count: 51)
        let terms = ["  Kubernetes ", "kubernetes", long, ""] + (0..<150).map { "Term\($0)" }
        let fitted = AssemblyAIStreamingConfiguration.fittedKeyterms(terms)
        XCTAssertEqual(fitted.count, 100)
        XCTAssertEqual(fitted.first, "Kubernetes")
        XCTAssertFalse(fitted.contains(long))
        XCTAssertEqual(fitted.filter { $0.lowercased() == "kubernetes" }.count, 1)
    }

    func testURLCarriesModelAudioFormatAndSteering() throws {
        let configuration = AssemblyAIStreamingConfiguration(
            model: .realtimeAgent, languageCode: "en",
            prompt: String(repeating: "p", count: 2_000), keyterms: ["C++", "Dr. Smith"])
        let url = configuration.url(region: .europeanUnion)
        XCTAssertEqual(url.host, "streaming.eu.assemblyai.com")
        XCTAssertEqual(url.path, "/v3/ws")
        XCTAssertFalse(url.absoluteString.contains("+"), "A literal + would decode as a space")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["speech_model"], "assemblyai-stt-3-7-realtime-agent")
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["encoding"], "pcm_s16le")
        XCTAssertEqual(query["mode"], "max_accuracy")
        XCTAssertEqual(query["language_codes"], #"["en"]"#)
        XCTAssertEqual(query["prompt"]?.count, AssemblyAIStreamingConfiguration.maximumPromptCharacters)
        let keyterms = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(query["keyterms_prompt"]).utf8))
        XCTAssertEqual(keyterms as? [String], ["C++", "Dr. Smith"])
    }

    func testURLOmitsEmptySteering() {
        let configuration = AssemblyAIStreamingConfiguration(
            model: .realtime, languageCode: "de", prompt: nil, keyterms: [])
        let url = configuration.url(region: .global)
        XCTAssertEqual(url.host, "streaming.assemblyai.com")
        XCTAssertFalse(url.absoluteString.contains("prompt"))
    }

    func testAudioIsFramedIn100MillisecondChunksAndTailIsPadded() async {
        let audio = AssemblyAIStreamingAudio()
        audio.append([Float](repeating: 0.1, count: 2_500))  // 156 ms
        audio.append([Float](repeating: 0.1, count: 150))    // tail 1,050 samples
        audio.finish()
        audio.append([Float](repeating: 0.1, count: 1_600))  // ignored after finish
        var sizes: [Int] = []
        for await frame in audio.frames { sizes.append(frame.count) }
        XCTAssertEqual(sizes, [3_200, 2_100])

        let short = AssemblyAIStreamingAudio()
        short.append([Float](repeating: 0.1, count: 100))
        short.finish()
        var shortSizes: [Int] = []
        for await frame in short.frames { shortSizes.append(frame.count) }
        XCTAssertEqual(shortSizes, [AssemblyAIStreamingAudio.minimumFrameBytes])
    }

    func testAbandonedAudioDropsBufferedTail() async {
        let audio = AssemblyAIStreamingAudio()
        audio.append([Float](repeating: 0.1, count: 500))
        audio.abandon()
        var count = 0
        for await _ in audio.frames { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
