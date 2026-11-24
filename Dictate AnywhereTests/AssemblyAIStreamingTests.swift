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

    #if DEBUG
    @MainActor
    func testStreamedTranscriptIsUsedWithoutDictationRequests() async throws {
        let result = try await runEngine(
            streaming: { audio, onUpdate in
                for await _ in audio.frames {}
                onUpdate("Streamed")
                return AssemblyAIStreamingResult(text: "Streamed words.", turnCount: 1,
                                                 audioDurationSeconds: 0.1, sessionDurationSeconds: 0.5)
            },
            dictation: { _ in XCTFail("Streaming must not call the Dictation API"); throw URLError(.badURL) })
        XCTAssertEqual(result, "Streamed words.")
    }

    @MainActor
    func testFailedStreamFallsBackToDictation() async throws {
        var dictationRequests = 0
        let result = try await runEngine(
            streaming: { audio, _ in
                for await _ in audio.frames { throw URLError(.networkConnectionLost) }
                throw URLError(.networkConnectionLost)
            },
            dictation: { request in
                XCTAssertEqual(request.url?.path, "/v1/transcribe")
                dictationRequests += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"text":"Recovered from the recording."}"#.utf8), response)
            })
        XCTAssertEqual(result, "Recovered from the recording.")
        XCTAssertEqual(dictationRequests, 1)
    }

    @MainActor
    private func runEngine(
        streaming: @escaping (AssemblyAIStreamingAudio, @escaping @Sendable (String) -> Void) async throws -> AssemblyAIStreamingResult,
        dictation: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> String {
        let settings = Settings.shared
        let saved = (settings.assemblyAIStreamingEnabled, settings.assemblyAIOutputMode,
                     settings.showTextPreview, settings.dictationContextAwarenessEnabled)
        settings.assemblyAIStreamingEnabled = true
        settings.assemblyAIOutputMode = .verbatim
        settings.showTextPreview = false
        settings.dictationContextAwarenessEnabled = false
        defer {
            settings.assemblyAIStreamingEnabled = saved.0
            settings.assemblyAIOutputMode = saved.1
            settings.showTextPreview = saved.2
            settings.dictationContextAwarenessEnabled = saved.3
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AssemblyAIEngine()
        engine.recoveryCapture = try RecoveryAudioCapture(id: UUID(), url: directory.appendingPathComponent("capture.caf"))
        engine.apiKey = { "test-key" }
        engine.runStreaming = { _, _, _, audio, onUpdate in try await streaming(audio, onUpdate) }
        engine.sendRequest = dictation
        engine.makeTestCaptureController = { onSamples in
            onSamples([Float](repeating: 0.2, count: 16_000))
            return SilentCapture()
        }
        try await engine.startRecording(deviceID: nil)
        return await engine.stopRecording()
    }
    #endif
}

#if DEBUG
private final class SilentCapture: @unchecked Sendable, AudioCaptureController {
    func stop() {}
}
#endif
