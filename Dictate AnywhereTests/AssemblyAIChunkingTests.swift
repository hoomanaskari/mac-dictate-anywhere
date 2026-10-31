import XCTest
import AVFoundation
@testable import Dictate_Anywhere

@MainActor
final class AssemblyAIChunkingTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("assemblyai-chunks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testFiveMinutesHasExactCoverageAndOverlapWithoutDroppingTail() {
        let samples = (0..<(300 * 16_000 + 17)).map { Float($0 % 1000) / 1000 + 0.1 }
        var chunker = AssemblyAIChunker()
        var chunks: [AssemblyAIChunk] = []
        for offset in stride(from: 0, to: samples.count, by: 4073) {
            chunks += chunker.append(Array(samples[offset..<min(offset + 4073, samples.count)]))
        }
        chunks += chunker.append([], final: true)
        XCTAssertEqual(chunks.count, 4)
        var rebuilt: [Float] = []
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.samples.count, 100 * 16_000)
            if index > 0 { XCTAssertEqual(chunks[index - 1].end - chunk.start, 3 * 16_000) }
            rebuilt += chunk.samples.dropFirst(max(0, rebuilt.count - chunk.start))
        }
        XCTAssertEqual(rebuilt, samples)
    }

    func testSilenceBoundaryAndFileReadsProduceIdenticalChunks() {
        var samples = Array(repeating: Float(0.2), count: 201 * 16_000)
        samples.replaceSubrange((97 * 16_000)..<(98 * 16_000), with: repeatElement(0, count: 16_000))
        var single = AssemblyAIChunker(), streamed = AssemblyAIChunker()
        let expected = single.append(samples, final: true)
        var actual: [AssemblyAIChunk] = []
        for offset in stride(from: 0, to: samples.count, by: 160_000) {
            actual += streamed.append(Array(samples[offset..<min(offset + 160_000, samples.count)]))
        }
        actual += streamed.append([], final: true)
        XCTAssertEqual(expected.first?.end, 98 * 16_000)
        XCTAssertEqual(actual.map(\.start), expected.map(\.start))
        XCTAssertEqual(actual.map(\.samples), expected.map(\.samples))
    }

    func testExactBoundaryDoesNotCreateOverlapOnlyTail() {
        var chunker = AssemblyAIChunker()
        let chunks = chunker.append(Array(repeating: 0.3, count: 100 * 16_000), final: true)
        XCTAssertEqual(chunks.count, 1)
    }

    func testOverlapIgnoresPunctuationAndAcceptsStrongOneWordVariation() {
        XCTAssertEqual(AssemblyAIOverlap.stablePrefix("We should meet. Tomorrow, after the meeting!", before: "tomorrow after the meeting we can discuss it."), "We should meet.")
        XCTAssertEqual(AssemblyAIOverlap.stablePrefix("Start here. I would like to review the design today", before: "I would like to revisit the design today and discuss it"), "Start here.")
        XCTAssertNil(AssemblyAIOverlap.stablePrefix("Yes yes", before: "yes yes please"))
        XCTAssertNil(AssemblyAIOverlap.stablePrefix("One totally unrelated ending", before: "A different sentence follows"))
    }

    func testProcessorDecodesWhileRecordingAndRetriesOnlyMissingChunkAcrossRelaunch() async throws {
        let url = directory.appendingPathComponent("session.caf")
        let store = try AssemblyAIChunkStore(audioURL: url)
        var requests = 0
        let first = AssemblyAIChunkProcessor(store: store, signature: "en") { _ in
            requests += 1
            if requests == 1 { return "Opening. We should review this design" }
            throw AssemblyAIEngineError.requestFailed(status: 401, message: nil)
        }
        store.append(Array(repeating: 0.2, count: 100 * 16_000))
        try await first.processAvailable()
        XCTAssertEqual(requests, 1, "A full chunk is sent before Stop")
        store.append(Array(repeating: 0.2, count: 45 * 16_000))
        try await store.finish()
        do { try await first.processAvailable(); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(requests, 2, "Authentication failures are not retried")
        // Recovery reconstructs deterministic boundaries from the full audio.
        let reopened = try AssemblyAIChunkStore(audioURL: url)
        reopened.append(Array(repeating: 0.2, count: 145 * 16_000))
        try await reopened.finish()
        var recoveryRequests = 0
        let resumed = AssemblyAIChunkProcessor(store: reopened, signature: "en") { _ in
            recoveryRequests += 1
            return "We should review this design and finish the work."
        }
        try await resumed.processAvailable()
        XCTAssertEqual(recoveryRequests, 1)
        XCTAssertEqual(resumed.text, "Opening. We should review this design and finish the work.")
        let preview = try String(contentsOf: reopened.directory.appendingPathComponent("preview.txt"), encoding: .utf8)
        XCTAssertEqual(preview, resumed.text)
    }

    func testUncertainBoundaryRedecodesCombinedAudioAndCachesRepair() async throws {
        let store = try AssemblyAIChunkStore(audioURL: directory.appendingPathComponent("repair.caf"))
        store.append(Array(repeating: 0.2, count: 145 * 16_000))
        try await store.finish()
        var counts: [Int] = []
        let processor = AssemblyAIChunkProcessor(store: store, signature: "en") { samples in
            counts.append(samples.count)
            switch counts.count {
            case 1: return "First part has an uncertain ending"
            case 2: return "Different words at the start of the next part"
            default: return "All the words recovered in one continuous transcript."
            }
        }
        try await processor.processAvailable()
        XCTAssertEqual(counts, [100 * 16_000, 48 * 16_000, 145 * 16_000])
        XCTAssertEqual(processor.text, "All the words recovered in one continuous transcript.")
        let recovered = AssemblyAIChunkProcessor(store: store, signature: "en") { _ in XCTFail("Already cached"); return "" }
        try await recovered.processAvailable()
        XCTAssertEqual(recovered.text, processor.text)
    }

    func testNetworkRetryAndCancellationLeaveOriginalAudioAndDoNotCommitPartialResult() async throws {
        let store = try AssemblyAIChunkStore(audioURL: directory.appendingPathComponent("retry.caf"))
        store.append(Array(repeating: 0.2, count: 16_000))
        try await store.finish()
        var attempts = 0
        let processor = AssemblyAIChunkProcessor(store: store, signature: "en") { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return "Recovered words"
        }
        try await processor.processAvailable()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(processor.text, "Recovered words")
        let started = expectation(description: "Request started")
        let cancelled = AssemblyAIChunkProcessor(store: store, signature: "different-language") { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return "Must not commit"
        }
        let task = Task { try await cancelled.processAvailable() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertEqual(cancelled.text, "")
        let chunks = try await store.snapshot()
        XCTAssertFalse(chunks.isEmpty)
        let cache = try await store.cachedText(for: chunks[0], signature: "different-language")
        XCTAssertNil(cache)
    }

    func testRecoveryCopyAndWAVExportDoNotRequireTranscriptionOrDeleteSource() async throws {
        let recovery = DictationRecoveryStore(directory: directory)
        let capture = try recovery.beginCapture()
        let samples: [Float] = [0.1, 0.3, -0.5, 0.7]
        capture.append(samples)
        let saved = try await recovery.preserve(capture, preview: "Saved preview", completedTranscript: nil)
        let entry = try XCTUnwrap(saved)
        XCTAssertEqual(recovery.copyableText(for: entry), "Saved preview")
        let destination = directory.appendingPathComponent("export.wav")
        try await recovery.exportAudio(id: entry.id, to: destination)
        let reader = try RecoveryAudioReader(url: destination)
        XCTAssertEqual(try reader.nextSamples(), samples)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.url.path))
        XCTAssertEqual(recovery.entries, [entry])
        // Replacing a previous export is safe and produces a finalized WAV.
        try await recovery.exportAudio(id: entry.id, to: destination)
        XCTAssertEqual(try RecoveryAudioReader(url: destination).nextSamples(), samples)
    }

    func testInterruptedAudioSurfacesOnRelaunchAndExpiryRemovesChunkCache() async throws {
        let recovery = DictationRecoveryStore(directory: directory)
        let capture = try recovery.beginCapture()
        capture.append(Array(repeating: 0.2, count: 16_000))
        _ = await capture.finish() // Simulate interruption before preserve metadata.
        let chunks = try AssemblyAIChunkStore(audioURL: capture.url)
        try await chunks.savePreview("Durable chunk text")
        let reopened = DictationRecoveryStore(directory: directory)
        try reopened.reload()
        let entry = try XCTUnwrap(reopened.entries.first)
        XCTAssertEqual(entry.id, capture.id)
        XCTAssertEqual(entry.preview, "Durable chunk text")
        XCTAssertNil(entry.completedTranscript)
        XCTAssertEqual(entry.duration, 1)
        try reopened.reload(now: entry.expiresAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunks.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
    }
    func testEngineLongRecoveryUsesFinishedEndpointAndOneWholeTranscriptCleanup() async throws {
        let settings = Settings.shared
        let oldMode = settings.assemblyAIOutputMode
        let oldRegion = settings.assemblyAIRegion
        settings.assemblyAIOutputMode = .polished
        settings.assemblyAIRegion = .europeanUnion
        defer { settings.assemblyAIOutputMode = oldMode; settings.assemblyAIRegion = oldRegion }
        let capture = try RecoveryAudioCapture(id: UUID(), url: directory.appendingPathComponent("long.caf"))
        capture.append(Array(repeating: 0.2, count: 145 * 16_000))
        _ = await capture.finish()
        let engine = AssemblyAIEngine()
        engine.apiKey = { "test-key-not-a-real-secret" }
        var audioRequests = 0, cleanupRequests = 0
        let raw = "Opening. We should review this design and finish the work."
        engine.sendRequest = { request in
            let object: [String: Any]
            if request.url?.path == "/v1/transcribe" {
                XCTAssertEqual(request.url?.host, "dictation.eu.assemblyai.com")
                audioRequests += 1
                object = ["text": audioRequests == 1 ? "Opening. We should review this design" : "We should review this design and finish the work.",
                          "llm_response": "Chunk rewrite must be ignored"]
            } else {
                cleanupRequests += 1
                XCTAssertEqual(request.url?.host, "llm-gateway.eu.assemblyai.com")
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                XCTAssertEqual(messages.last?["content"], raw)
                object = ["choices": [["message": ["content": "Opening. Let's review this design and finish the work."], "finish_reason": "stop"]]]
            }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await engine.transcribeRecording(at: capture.url)
        XCTAssertEqual(result, "Opening. Let's review this design and finish the work.")
        XCTAssertEqual(engine.lastRawTranscript, raw)
        XCTAssertTrue(engine.lastResultWasPolished)
        XCTAssertEqual(audioRequests, 2)
        XCTAssertEqual(cleanupRequests, 1)
        // Reopening the same recording skips all successful audio requests.
        _ = try await engine.transcribeRecording(at: capture.url)
        XCTAssertEqual(audioRequests, 2)
        XCTAssertEqual(cleanupRequests, 2)
    }

    func testEngineShortDictationKeepsSingleRequestAndLongTruncatedCleanupFallsBackToRaw() async throws {
        let oldMode = Settings.shared.assemblyAIOutputMode
        Settings.shared.assemblyAIOutputMode = .polished
        defer { Settings.shared.assemblyAIOutputMode = oldMode }
        let engine = AssemblyAIEngine()
        engine.apiKey = { "test-key" }
        var requests = 0
        engine.sendRequest = { request in
            requests += 1
            let object: [String: Any] = request.url?.path == "/v1/transcribe"
                ? ["text": "These are the original words", "llm_response": "These are the polished words."]
                : ["choices": [["message": ["content": "Truncated"], "finish_reason": "length"]]]
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let short = try RecoveryAudioCapture(id: UUID(), url: directory.appendingPathComponent("short.caf"))
        short.append(Array(repeating: 0.2, count: 16_000))
        _ = await short.finish()
        let shortResult = try await engine.transcribeRecording(at: short.url)
        XCTAssertEqual(shortResult, "These are the polished words.")
        XCTAssertEqual(requests, 1)
        let long = try RecoveryAudioCapture(id: UUID(), url: directory.appendingPathComponent("limit.caf"))
        long.append(Array(repeating: 0.2, count: 100 * 16_000))
        _ = await long.finish()
        let result = try await engine.transcribeRecording(at: long.url)
        XCTAssertEqual(result, "These are the original words")
        XCTAssertFalse(engine.lastResultWasPolished)
        XCTAssertNil(engine.lastInsertionPlan)
    }

    func testRepeatedOverlapIsRepairedRatherThanGuessingWhichRepetitionToRemove() {
        XCTAssertNil(AssemblyAIOverlap.stablePrefix("please do this please do this", before: "please do this please do this again"))
    }

    #if DEBUG
    func testStopDrainsInflightChunkInsteadOfAbortingAndResendingIt() async throws {
        let oldMode = Settings.shared.assemblyAIOutputMode
        Settings.shared.assemblyAIOutputMode = .verbatim
        defer { Settings.shared.assemblyAIOutputMode = oldMode }
        let store = try AssemblyAIChunkStore(audioURL: directory.appendingPathComponent("drain.caf"))
        store.append(Array(repeating: 0.2, count: 100 * 16_000))
        let engine = AssemblyAIEngine()
        engine.apiKey = { "test-key" }
        let started = expectation(description: "Chunk request in flight")
        var requests = 0
        var release: CheckedContinuation<Void, Never>?
        engine.sendRequest = { request in
            requests += 1
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            XCTAssertFalse(Task.isCancelled, "Normal Stop must finish the current request")
            return (Data(#"{"text":"The entire recording"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        engine.installChunkPipelineForTesting(store)
        await fulfillment(of: [started], timeout: 3)
        let stopping = Task { await engine.stopRecording() }
        await Task.yield()
        release?.resume()
        let result = await stopping.value
        XCTAssertEqual(result, "The entire recording")
        XCTAssertEqual(requests, 1)
        XCTAssertNil(engine.lastTranscriptionError)
    }

    func testCancelAbortsInflightChunkAndKeepsDiskAudio() async throws {
        let store = try AssemblyAIChunkStore(audioURL: directory.appendingPathComponent("cancel.caf"))
        store.append(Array(repeating: 0.2, count: 100 * 16_000))
        let engine = AssemblyAIEngine()
        engine.apiKey = { "test-key" }
        let started = expectation(description: "Chunk request in flight")
        var cancelled = false
        engine.sendRequest = { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
            throw AssemblyAIEngineError.invalidResponse
        }
        engine.installChunkPipelineForTesting(store)
        await fulfillment(of: [started], timeout: 3)
        await engine.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(engine.currentTranscript, "")
        let chunks = try await store.snapshot()
        XCTAssertEqual(chunks.count, 1)
        let samples = try await store.samples(for: chunks[0])
        XCTAssertEqual(samples.count, 100 * 16_000)
    }
    #endif

}
