import XCTest
import CoreAudio
@testable import Dictate_Anywhere

@MainActor
final class DictationContinuationTests: XCTestCase {
    private var directory: URL!
    private var store: DictationRecoveryStore!
    private var restoreSettings: (() -> Void)!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-continue-\(UUID())")
        store = DictationRecoveryStore(directory: directory)
        let settings = Settings.shared
        let sound = settings.soundEffectsEnabled
        let boost = settings.boostMicrophoneVolumeEnabled
        let mute = settings.muteSystemAudioDuringRecordingEnabled
        let preserve = settings.preserveCancelledSessions
        let microphone = settings.selectedMicrophoneUID
        let processing = settings.transcriptPostProcessingMode
        let history = settings.transcriptHistory
        restoreSettings = {
            settings.soundEffectsEnabled = sound
            settings.boostMicrophoneVolumeEnabled = boost
            settings.muteSystemAudioDuringRecordingEnabled = mute
            settings.preserveCancelledSessions = preserve
            settings.selectedMicrophoneUID = microphone
            settings.transcriptPostProcessingMode = processing
            settings.transcriptHistory = history
        }
        settings.soundEffectsEnabled = false
        settings.boostMicrophoneVolumeEnabled = false
        settings.muteSystemAudioDuringRecordingEnabled = false
        settings.preserveCancelledSessions = true
        settings.selectedMicrophoneUID = nil
        settings.transcriptPostProcessingMode = .none
        settings.transcriptHistory = []
    }

    override func tearDown() async throws {
        restoreSettings()
        store = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func savedSession(completed: String? = nil, target: String? = nil) async throws -> CancelledDictation {
        let capture = try store.beginCapture()
        capture.append(Array(repeating: 0.25, count: 16_000))
        let entry = try await store.preserve(capture, preview: "An incomplete preview",
                                              completedTranscript: completed, targetBundleIdentifier: target)
        return try XCTUnwrap(entry)
    }

    private func app(engine: ContinuationTestEngine, delivery: ((String) async -> TextInsertionResult)? = nil) -> AppState {
        let app = AppState(permissions: Permissions(statusProvider: { (true, false) }), recoveryStore: store, engine: engine,
                           transcriptDelivery: delivery ?? { _ in .copiedOnly })
        app.permissions.micGranted = true
        return app
    }

    func testContinueRestoresCompleteWordsThenStartsMicAndDeliversOnce() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        var delivered: [String] = []
        let app = app(engine: engine) { delivered.append($0); return .success }
        await app.continueCancelledDictation(entry)
        XCTAssertEqual(engine.events, ["restore", "start"])
        XCTAssertEqual(app.status, .recording)
        XCTAssertEqual(app.currentTranscript, "The original words.")
        XCTAssertEqual(store.entries, [entry])
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(app.canCancelDictation)
        await app.stopDictation()
        await app.stopDictation()
        XCTAssertEqual(delivered, ["The original words. More words."])
        XCTAssertEqual(Settings.shared.transcriptHistory.map(\.text), delivered)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertNil(app.continuingEntryID)
        XCTAssertEqual(app.status, .idle)
    }

    func testCancelAgainPreservesPrefixAndOnlyNewAudioAcrossRelaunch() async throws {
        let entry = try await savedSession(target: "example.unavailable-app")
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        app.currentTranscript = "The original words. More"
        await app.cancelDictation()
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
        let relaunched = DictationRecoveryStore(directory: directory)
        try relaunched.reload()
        let saved = try XCTUnwrap(relaunched.entries.first)
        XCTAssertEqual(relaunched.entries.count, 1)
        XCTAssertNotEqual(saved.id, entry.id)
        XCTAssertEqual(saved.transcriptPrefix, "The original words.")
        XCTAssertEqual(saved.targetBundleIdentifier, "example.unavailable-app")
        XCTAssertEqual(saved.duration, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(id: entry.id).path))
        let reader = try RecoveryAudioReader(url: store.audioURL(id: saved.id))
        var samples: [Float] = []
        while let chunk = try reader.nextSamples() { samples += chunk }
        XCTAssertEqual(samples, Array(repeating: 0.5, count: 16_000))
        engine.restoredText = "More words."
        let secondApp = AppState(permissions: Permissions(statusProvider: { (true, false) }),
                                recoveryStore: relaunched, engine: engine, transcriptDelivery: { _ in .copiedOnly })
        secondApp.permissions.micGranted = true
        await secondApp.continueCancelledDictation(saved)
        XCTAssertEqual(secondApp.currentTranscript, "The original words. More words.")
        engine.stoppedText = "Last words."
        await secondApp.stopDictation()
        XCTAssertEqual(Settings.shared.transcriptHistory.map(\.text), ["The original words. More words. Last words."])
        XCTAssertTrue(relaunched.entries.isEmpty)
    }

    func testStopWithoutNewSpeechKeepsOriginalWords() async throws {
        let entry = try await savedSession(completed: "The original words.")
        let engine = ContinuationTestEngine()
        engine.stoppedText = ""
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        XCTAssertEqual(engine.events, ["start"])
        await app.stopDictation()
        XCTAssertEqual(Settings.shared.transcriptHistory.map(\.text), ["The original words."])
    }

    func testRestorationFailureKeepsSourceAndDoesNotStartMic() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        engine.restoreFails = true
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        XCTAssertEqual(engine.events, ["restore"])
        XCTAssertEqual(app.status, .idle)
        XCTAssertNil(app.continuingEntryID)
        XCTAssertEqual(store.entries, [entry])
        XCTAssertNotNil(store.errorMessage)
        // The failed attempt must release the source for a subsequent retry.
        engine.restoreFails = false
        await app.continueCancelledDictation(entry)
        XCTAssertEqual(app.status, .recording)
        await app.cancelDictation()
    }

    func testMicrophoneStartupFailureKeepsOriginalAndDiscardsTemporaryCopy() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        engine.startFails = true
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        XCTAssertEqual(app.status, .idle)
        XCTAssertNil(app.continuingEntryID)
        XCTAssertEqual(store.entries, [entry])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testCancellationWhileFinishingPreservesCombinedResultWithoutDuplicatingPrefix() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        let began = expectation(description: "recognition began")
        engine.onStop = { began.fulfill() }
        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [began], timeout: 1)
        let cancelling = Task { await app.cancelDictation() }
        for _ in 0..<100 where app.canCancelDictation { await Task.yield() }
        XCTAssertFalse(app.canCancelDictation)
        engine.finishPendingStop()
        await stopping.value
        await cancelling.value
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
        let saved = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(saved.completedTranscript, "The original words. More words.")
        engine.events = []
        await app.recoverCancelledDictation(saved)
        XCTAssertTrue(engine.events.isEmpty)
        XCTAssertEqual(Settings.shared.transcriptHistory.map(\.text), ["The original words. More words."])
    }

    func testFirstMicrophonePermissionGrantKeepsSessionWithoutStartingRecording() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = AppState(permissions: Permissions(statusProvider: { (false, false) }),
                           microphonePermissionRequester: { true }, recoveryStore: store, engine: engine)
        await app.continueCancelledDictation(entry)
        XCTAssertTrue(engine.events.isEmpty)
        XCTAssertEqual(store.entries, [entry])
        XCTAssertEqual(app.status, .idle)
        XCTAssertNil(app.continuingEntryID)
    }

    func testCancelledDecoderReturningEmptyDoesNotSkipNewestAudioOnRecovery() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        let began = expectation(description: "recognition began")
        engine.onStop = { began.fulfill() }
        engine.stoppedText = ""
        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [began], timeout: 1)
        let cancelling = Task { await app.cancelDictation() }
        for _ in 0..<100 where app.canCancelDictation { await Task.yield() }
        engine.finishPendingStop()
        await stopping.value
        await cancelling.value
        let saved = try XCTUnwrap(store.entries.first)
        XCTAssertNil(saved.completedTranscript)
        XCTAssertEqual(saved.transcriptPrefix, "The original words.")
        engine.restoredText = "Words from the newest audio."
        await app.recoverCancelledDictation(saved)
        XCTAssertEqual(Settings.shared.transcriptHistory.map(\.text),
                       ["The original words. Words from the newest audio."])
    }

    func testRetainedSourceSurvivesExpiryAndClearUntilContinuationFinishes() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        try store.reload(now: Date().addingTimeInterval(90_000))
        try store.removeAll()
        XCTAssertThrowsError(try store.remove(id: entry.id))
        XCTAssertEqual(store.entries, [entry])
        await app.cancelDictation()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNotEqual(store.entries.first?.id, entry.id)
    }

    func testContinuationPreservesWordsEvenIfNewSessionPreservationWasDisabled() async throws {
        let entry = try await savedSession()
        Settings.shared.preserveCancelledSessions = false
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        XCTAssertNotNil(engine.recoveryCapture)
        await app.cancelDictation()
        XCTAssertEqual(store.entries.first?.transcriptPrefix, "The original words.")
    }

    func testRecoverTextFromContinuedSessionIncludesPrefixWithoutStartingMic() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        await app.cancelDictation()
        let saved = try XCTUnwrap(store.entries.first)
        engine.events = []
        engine.restoredText = "More words."
        await app.recoverCancelledDictation(saved)
        XCTAssertEqual(engine.events, ["restore"])
        XCTAssertEqual(Settings.shared.transcriptHistory.map(\.text), ["The original words. More words."])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testLegacySavedSessionDecodesWithoutContinuationMetadata() async throws {
        let entry = try await savedSession()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "transcriptPrefix")
        json.removeValue(forKey: "targetBundleIdentifier")
        let decoded = try JSONDecoder().decode(CancelledDictation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, entry)
        XCTAssertNil(decoded.transcriptPrefix)
        XCTAssertNil(decoded.targetBundleIdentifier)
    }

    func testEmptyDecodeOfNewestAudioKeepsItAvailableInsteadOfReplacingItWithPrefix() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        await app.cancelDictation()
        let saved = try XCTUnwrap(store.entries.first)
        engine.restoredText = ""
        engine.events = []
        await app.continueCancelledDictation(saved)
        XCTAssertEqual(engine.events, ["restore"])
        XCTAssertEqual(app.status, .idle)
        XCTAssertEqual(store.entries, [saved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(id: saved.id).path))
        XCTAssertNotNil(store.errorMessage)
        await app.recoverCancelledDictation(saved)
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
        XCTAssertEqual(store.entries, [saved])
    }

    func testDoubleContinueDoesNotStartAnotherRecording() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        let app = app(engine: engine)
        await app.continueCancelledDictation(entry)
        await app.continueCancelledDictation(entry)
        XCTAssertEqual(engine.events, ["restore", "start"])
        await app.cancelDictation()
    }

    func testShutdownDoesNotDeliverPendingRecognition() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        var delivered: [String] = []
        let app = app(engine: engine) { delivered.append($0); return .success }
        await app.continueCancelledDictation(entry)
        let recognitionBegan = expectation(description: "recognition began")
        engine.onStop = { recognitionBegan.fulfill() }

        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [recognitionBegan], timeout: 1)
        let shuttingDown = Task { await app.shutdown() }
        await Task.yield()
        engine.finishPendingStop()
        await stopping.value
        await shuttingDown.value

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
    }

    func testShutdownPreventsPendingContinuationFromStartingMicrophone() async throws {
        let entry = try await savedSession()
        let engine = ContinuationTestEngine()
        engine.suspendRestore = true
        let app = app(engine: engine)
        let restorationBegan = expectation(description: "restoration began")
        engine.onRestore = { restorationBegan.fulfill() }

        let continuing = Task { await app.continueCancelledDictation(entry) }
        await fulfillment(of: [restorationBegan], timeout: 1)
        await app.shutdown()
        engine.finishPendingRestore()
        await continuing.value

        XCTAssertEqual(engine.events, ["restore", "cancel"])
        XCTAssertEqual(app.status, .idle)
    }

    func testShutdownDrainsPendingMicrophoneStartup() async throws {
        let engineChoice = Settings.shared.engineChoice
        defer { Settings.shared.engineChoice = engineChoice }
        Settings.shared.engineChoice = .appleSpeech
        let engine = ContinuationTestEngine()
        engine.suspendStart = true
        let app = app(engine: engine)
        let startupBegan = expectation(description: "microphone startup began")
        engine.onStart = { startupBegan.fulfill() }

        let starting = Task { await app.startDictation() }
        await fulfillment(of: [startupBegan], timeout: 1)
        var shutdownCompleted = false
        let shuttingDown = Task {
            await app.shutdown()
            shutdownCompleted = true
        }
        await Task.yield()
        XCTAssertFalse(shutdownCompleted)
        engine.finishPendingStart()
        await starting.value
        await shuttingDown.value

        XCTAssertEqual(engine.events, ["start", "cancel"])
        XCTAssertEqual(app.status, .idle)
    }
}

@MainActor
private final class ContinuationTestEngine: TranscriptionEngine {
    var recoveryCapture: RecoveryAudioCapture?
    var isReady = true
    var currentTranscript = ""
    var audioSamples: [Float] = []
    var events: [String] = []
    var restoredText = "The original words."
    var stoppedText = "More words."
    var restoreFails = false
    var startFails = false
    var onStop: (() -> Void)?
    var onRestore: (() -> Void)?
    var onStart: (() -> Void)?
    var suspendRestore = false
    var suspendStart = false
    private var pendingStop: CheckedContinuation<String, Never>?
    private var pendingRestore: CheckedContinuation<String, Never>?
    private var pendingStart: CheckedContinuation<Void, Never>?
    func levelSamples(count: Int) -> [Float] { [] }
    func prepare() async throws { isReady = true }
    func startRecording(deviceID: AudioDeviceID?) async throws {
        events.append("start")
        if suspendStart {
            await withCheckedContinuation { continuation in
                pendingStart = continuation
                onStart?()
            }
        }
        if startFails { throw TranscriptionError.engineNotReady }
        recoveryCapture?.append(Array(repeating: 0.5, count: 16_000))
    }
    func stopRecording() async -> String {
        events.append("stop")
        guard onStop != nil else { return stoppedText }
        return await withCheckedContinuation { continuation in
            pendingStop = continuation
            onStop?()
        }
    }
    func finishPendingStop() {
        pendingStop?.resume(returning: stoppedText)
        pendingStop = nil
    }
    func finishPendingStart() {
        pendingStart?.resume()
        pendingStart = nil
    }
    func finishPendingRestore() {
        pendingRestore?.resume(returning: restoredText)
        pendingRestore = nil
    }
    func cancel() async { events.append("cancel") }
    func transcribeRecording(at url: URL) async throws -> String {
        events.append("restore")
        if restoreFails { throw TranscriptionError.engineNotReady }
        if suspendRestore {
            return await withCheckedContinuation { continuation in
                pendingRestore = continuation
                onRestore?()
            }
        }
        return restoredText
    }
}
