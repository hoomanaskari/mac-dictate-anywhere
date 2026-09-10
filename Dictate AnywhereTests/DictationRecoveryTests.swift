import XCTest
import CoreAudio
@testable import Dictate_Anywhere

@MainActor
final class DictationRecoveryTests: XCTestCase {
    private var directory: URL!
    private var store: DictationRecoveryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recovery-test-\(UUID())")
        store = DictationRecoveryStore(directory: directory)
    }

    override func tearDown() async throws {
        store = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testCapturePreservesEveryChunkAcrossRelaunch() async throws {
        let capture = try store.beginCapture()
        let samples: [Float] = [0.25, -0.5, 0.125, 0.75]
        capture.append(Array(samples.prefix(2)))
        capture.append(Array(samples.suffix(2)))
        let preserved = try await store.preserve(capture, preview: "Partial preview", completedTranscript: nil)
        let entry = try XCTUnwrap(preserved)
        capture.append([0.99]) // A closed capture must never contaminate the saved session.
        _ = await capture.finish()
        let reader = try RecoveryAudioReader(url: capture.url)
        XCTAssertEqual(try reader.nextSamples(), samples)
        XCTAssertNil(try reader.nextSamples())
        let relaunched = DictationRecoveryStore(directory: directory)
        try relaunched.reload()
        XCTAssertEqual(relaunched.entries, [entry])
        XCTAssertEqual(entry.expiresAt.timeIntervalSince(entry.createdAt), 86_400)
    }

    func testReaderBoundsMemoryForLongRecordings() async throws {
        let capture = try store.beginCapture()
        capture.append(Array(repeating: 0.2, count: 320_003))
        _ = await capture.finish()
        let reader = try RecoveryAudioReader(url: capture.url)
        var total = 0
        while let samples = try reader.nextSamples() {
            XCTAssertLessThanOrEqual(samples.count, 160_000)
            XCTAssertTrue(samples.allSatisfy { $0 == 0.2 })
            total += samples.count
        }
        XCTAssertEqual(total, 320_003)
    }

    func testExpiryDeletesAudioAndMetadataAt24Hours() async throws {
        let capture = try store.beginCapture()
        capture.append([0.5])
        let now = Date()
        _ = try await store.preserve(capture, preview: "test", completedTranscript: nil, now: now)
        try store.reload(now: now.addingTimeInterval(86_399))
        XCTAssertEqual(store.entries.count, 1)
        try store.reload(now: now.addingTimeInterval(86_400))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testEmptyCancellationIsDiscarded() async throws {
        let capture = try store.beginCapture()
        let entry = try await store.preserve(capture, preview: "", completedTranscript: nil)
        XCTAssertNil(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
    }

    func testCompletedDictationDiscardDeletesTemporaryAudio() async throws {
        let capture = try store.beginCapture()
        capture.append([0.1, 0.2])
        try await store.discard(capture)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
    }

    func testClearAllRemovesSavedSessionsWithoutDeletingActiveRecording() async throws {
        let first = try store.beginCapture()
        first.append([0.5])
        _ = try await store.preserve(first, preview: "first", completedTranscript: nil)
        let active = try store.beginCapture()
        try store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.url.path))
        try await store.discard(active)
    }

    func testRecoveredTextGoesToHistoryAndAudioIsRemoved() async throws {
        let previousHistory = Settings.shared.transcriptHistory
        defer { Settings.shared.transcriptHistory = previousHistory }
        let capture = try store.beginCapture()
        capture.append([0.5])
        let preserved = try await store.preserve(capture, preview: "incomplete", completedTranscript: nil)
        let entry = try XCTUnwrap(preserved)
        let engine = RecoveryTestEngine()
        let app = AppState(recoveryStore: store, engine: engine)
        await app.recoverCancelledDictation(entry)
        XCTAssertEqual(Settings.shared.transcriptHistory.last?.text, "Recovered speech.")
        XCTAssertTrue(engine.didRecover)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
        XCTAssertEqual(app.status, .idle)
    }

    func testFailedRecoveryKeepsOriginalAudioForRetry() async throws {
        let capture = try store.beginCapture()
        capture.append([0.5])
        let preserved = try await store.preserve(capture, preview: "incomplete", completedTranscript: nil)
        let entry = try XCTUnwrap(preserved)
        let engine = RecoveryTestEngine()
        engine.recoveryFails = true
        let app = AppState(recoveryStore: store, engine: engine)
        await app.recoverCancelledDictation(entry)
        XCTAssertEqual(store.entries, [entry])
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.url.path))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(app.status, .idle)
    }

    func testCompletedRecognitionCanBeRecoveredWithoutRerunningModel() async throws {
        let history = Settings.shared.transcriptHistory
        defer { Settings.shared.transcriptHistory = history }
        let capture = try store.beginCapture()
        let preserved = try await store.preserve(capture, preview: "preview", completedTranscript: "Finished speech.")
        let entry = try XCTUnwrap(preserved)
        let engine = RecoveryTestEngine()
        let app = AppState(recoveryStore: store, engine: engine)
        await app.recoverCancelledDictation(entry)
        XCTAssertFalse(engine.didRecover)
        XCTAssertEqual(Settings.shared.transcriptHistory.last?.text, "Finished speech.")
    }

    func testCancellationPreservesAudioWhenEnabledAndNoneWhenDisabled() async throws {
        let previous = Settings.shared.preserveCancelledSessions
        defer { Settings.shared.preserveCancelledSessions = previous }
        for enabled in [false, true] {
            Settings.shared.preserveCancelledSessions = enabled
            let engine = RecoveryTestEngine()
            let app = AppState(recoveryStore: store, engine: engine)
            app.prepareSessionRecovery(for: engine)
            XCTAssertEqual(engine.recoveryCapture != nil, enabled)
            engine.recoveryCapture?.append([0.25])
            app.currentTranscript = "A partial preview"
            app.status = .recording
            await app.cancelDictation()
            XCTAssertTrue(engine.didCancel)
            XCTAssertEqual(store.entries.count, enabled ? 1 : 0)
            XCTAssertEqual(app.status, .idle)
            XCTAssertEqual(app.currentTranscript, "")
        }
    }

    func testCancelDuringProcessingNeverDeliversLateResultAndKeepsRecovery() async throws {
        let previousHistory = Settings.shared.transcriptHistory
        let previousPreserve = Settings.shared.preserveCancelledSessions
        let previousSound = Settings.shared.soundEffectsEnabled
        defer {
            Settings.shared.transcriptHistory = previousHistory
            Settings.shared.preserveCancelledSessions = previousPreserve
            Settings.shared.soundEffectsEnabled = previousSound
        }
        Settings.shared.preserveCancelledSessions = true
        Settings.shared.soundEffectsEnabled = false
        let engine = RecoveryTestEngine()
        let began = expectation(description: "recognition began")
        engine.onStop = { began.fulfill() }
        let app = AppState(recoveryStore: store, engine: engine)
        app.prepareSessionRecovery(for: engine)
        engine.recoveryCapture?.append([0.5])
        app.status = .recording
        let finishing = Task { await app.stopDictation() }
        await fulfillment(of: [began], timeout: 1)
        let cancelling = Task { await app.cancelDictation() }
        for _ in 0..<100 where app.canCancelDictation { await Task.yield() }
        XCTAssertFalse(app.canCancelDictation)
        engine.finishPendingStop("Late recognition result")
        await finishing.value
        await cancelling.value
        XCTAssertEqual(Settings.shared.transcriptHistory, previousHistory)
        XCTAssertEqual(app.lastTranscript, "")
        XCTAssertEqual(app.status, .idle)
        XCTAssertTrue(engine.didCancel)
        XCTAssertFalse(engine.cancelOverlappedStop)
        XCTAssertEqual(store.entries.first?.completedTranscript, "Late recognition result")
        XCTAssertTrue(store.entries.first?.hasAudio == true)
    }
}

@MainActor
private final class RecoveryTestEngine: TranscriptionEngine {
    var recoveryCapture: RecoveryAudioCapture?
    var isReady = true
    var currentTranscript = ""
    var audioSamples: [Float] = []
    var didRecover = false
    var recoveryFails = false
    var didCancel = false
    var cancelOverlappedStop = false
    var onStop: (() -> Void)?
    private var pendingStop: CheckedContinuation<String, Never>?
    func levelSamples(count: Int) -> [Float] { [] }
    func prepare() async throws {}
    func startRecording(deviceID: AudioDeviceID?) async throws {}
    func stopRecording() async -> String {
        guard onStop != nil else { return "Finished speech." }
        return await withCheckedContinuation { continuation in
            pendingStop = continuation
            onStop?()
        }
    }
    func finishPendingStop(_ text: String) {
        pendingStop?.resume(returning: text)
        pendingStop = nil
    }
    func cancel() async {
        cancelOverlappedStop = pendingStop != nil
        didCancel = true
    }
    func transcribeRecording(at url: URL) async throws -> String {
        didRecover = true
        if recoveryFails { throw TranscriptionError.engineNotReady }
        return "Recovered speech."
    }
}
