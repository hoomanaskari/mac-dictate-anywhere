import XCTest
import CoreAudio
@testable import Dictate_Anywhere

@MainActor
final class DictationStartupContextTests: XCTestCase {
    private var directory: URL!
    private var restoreSettings: (() -> Void)!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-context-\(UUID())")
        let settings = Settings.shared
        let engine = settings.engineChoice
        let sound = settings.soundEffectsEnabled
        let boost = settings.boostMicrophoneVolumeEnabled
        let mute = settings.muteSystemAudioDuringRecordingEnabled
        let preserve = settings.preserveCancelledSessions
        let microphone = settings.selectedMicrophoneUID
        let localLanguage = settings.selectedLanguage
        let cloudLanguage = settings.assemblyAILanguage
        let processing = settings.transcriptPostProcessingMode
        let history = settings.transcriptHistory
        restoreSettings = {
            settings.engineChoice = engine
            settings.soundEffectsEnabled = sound
            settings.boostMicrophoneVolumeEnabled = boost
            settings.muteSystemAudioDuringRecordingEnabled = mute
            settings.preserveCancelledSessions = preserve
            settings.selectedMicrophoneUID = microphone
            settings.transcriptPostProcessingMode = processing
            settings.transcriptHistory = history
            settings.selectedLanguage = localLanguage
            settings.assemblyAILanguage = cloudLanguage
        }
        settings.engineChoice = .assemblyAI
        settings.soundEffectsEnabled = false
        settings.boostMicrophoneVolumeEnabled = false
        settings.muteSystemAudioDuringRecordingEnabled = false
        settings.preserveCancelledSessions = false
        settings.selectedMicrophoneUID = nil
        settings.transcriptPostProcessingMode = .none
        settings.transcriptHistory = []
    }

    override func tearDown() async throws {
        #if DEBUG
        PerfTrace.onIntervalCompleted = nil
        #endif
        restoreSettings()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func app(
        engine: StartupContextEngine,
        capture: @escaping @Sendable (pid_t?) async -> DictationContext?,
        delivery: @escaping (String) async -> TextInsertionResult = { _ in .copiedOnly }
    ) -> AppState {
        let app = AppState(
            permissions: Permissions(statusProvider: { (true, false) }),
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            transcriptDelivery: delivery,
            contextCapture: capture
        )
        app.permissions.micGranted = true
        return app
    }

    func testSlowContextDoesNotDelayListeningAndStopClosesMicrophoneBeforeWaiting() async {
        let captured = expectation(description: "context capture began")
        let gate = StartupContextGate(started: captured)
        let engine = StartupContextEngine()
        var delivered: [String] = []
        let app = app(engine: engine, capture: { _ in await gate.capture() }) {
            delivered.append($0)
            return .copiedOnly
        }
        let listening = expectation(description: "listening before context is ready")
        let starting = Task {
            await app.startDictation()
            listening.fulfill()
        }
        await fulfillment(of: [captured, listening], timeout: 2)
        XCTAssertTrue(app.canStopDictation)
        XCTAssertTrue(engine.capturing)
        XCTAssertNil(engine.context)

        let micStopped = expectation(description: "microphone stopped")
        engine.onCaptureStopped = { micStopped.fulfill() }
        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [micStopped], timeout: 2)
        XCTAssertFalse(engine.capturing)
        XCTAssertEqual(engine.finalizationCount, 0)
        XCTAssertTrue(delivered.isEmpty)

        let context = Self.context(pid: 123, word: "Zephyr")
        await gate.resolve(context)
        await starting.value
        await stopping.value
        XCTAssertEqual(engine.contextAtFinalization, context)
        XCTAssertEqual(engine.vocabularyAtFinalization, context.lexicalHints)
        XCTAssertEqual(engine.finalizationCount, 1)
        XCTAssertEqual(delivered, ["Recorded words."])
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    func testCancelWhileWaitingForContextReturnsWithoutWaitingForAccessibility() async {
        let captured = expectation(description: "context capture began")
        let gate = StartupContextGate(started: captured)
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in await gate.capture() })
        await app.startDictation()
        await fulfillment(of: [captured], timeout: 2)
        let micStopped = expectation(description: "microphone stopped")
        engine.onCaptureStopped = { micStopped.fulfill() }
        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [micStopped], timeout: 2)
        let cancelled = expectation(description: "cancel returns before context")
        let cancelling = Task { await app.cancelDictation(); cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(app.status, .idle)
        XCTAssertEqual(engine.finalizationCount, 0)
        await gate.resolve(Self.context(pid: 123, word: "Stale"))
        await cancelling.value
        await stopping.value
        XCTAssertNil(engine.context)
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
        await app.shutdown()
    }

    func testLateCancelledContextCannotReplaceNextSessionsContext() async {
        let firstStarted = expectation(description: "first context capture began")
        let firstGate = StartupContextGate(started: firstStarted)
        let secondStarted = expectation(description: "second context capture began")
        let secondGate = StartupContextGate(started: secondStarted)
        let captures = StartupContextSequence(gates: [firstGate, secondGate])
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in await captures.capture() })
        await app.startDictation()
        await fulfillment(of: [firstStarted], timeout: 2)
        await app.cancelDictation()
        await app.startDictation()
        await fulfillment(of: [secondStarted], timeout: 2)
        let current = Self.context(pid: 456, word: "Current")
        await secondGate.resolve(current)
        await firstGate.resolve(Self.context(pid: 123, word: "Stale"))
        await app.stopDictation()
        XCTAssertEqual(engine.contextAtFinalization, current)
        XCTAssertFalse(engine.appliedContexts.contains { $0.processIdentifier == 123 })
        await app.shutdown()
    }

    func testShutdownWhileContextIsPendingDoesNotWaitOrApplyLateResult() async {
        let captured = expectation(description: "context capture began")
        let gate = StartupContextGate(started: captured)
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in await gate.capture() })
        await app.startDictation()
        await fulfillment(of: [captured], timeout: 2)
        await app.shutdown()
        await gate.resolve(Self.context(pid: 123, word: "Stale"))
        XCTAssertFalse(engine.capturing)
        XCTAssertTrue(engine.appliedContexts.isEmpty)
        XCTAssertEqual(app.status, .idle)
    }

    func testUnavailableContextStillFinalizesAudio() async {
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in nil })
        await app.startDictation()
        await app.stopDictation()
        XCTAssertEqual(engine.finalizationCount, 1)
        XCTAssertNil(engine.contextAtFinalization)
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    #if DEBUG
    func testAssemblyAISessionUsesCloudLanguageWhenLocalLanguageDiffers() async throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled trace emission")
        let events = TraceCompletions()
        PerfTrace.onIntervalCompleted = { name, _, metadata in
            events.record(name: name, metadata: metadata)
        }
        Settings.shared.selectedLanguage = .english
        Settings.shared.assemblyAILanguage = .spanish
        let app = app(engine: StartupContextEngine(), capture: { _ in nil })
        await app.startDictation()
        let request = events.metadata(for: "dictation.requestToRecording")
        XCTAssertTrue(request?.contains("engine=assemblyAI") == true, request ?? "missing request trace")
        XCTAssertTrue(request?.contains("language=es") == true, request ?? "missing request trace")
        await app.cancelDictation()
        await app.shutdown()
    }

    func testStopToInsertionEndsBeforePostDeliveryRestoration() async throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled trace emission")
        let events = TraceCompletions()
        PerfTrace.onIntervalCompleted = { name, _, metadata in
            events.record(name: name, metadata: metadata)
        }
        let app = app(engine: StartupContextEngine(), capture: { _ in nil })
        await app.startDictation()
        // Enable the post-delivery settle without muting any system output during startup.
        Settings.shared.muteSystemAudioDuringRecordingEnabled = true
        await app.stopDictation()
        let names = events.names
        guard let insertion = names.firstIndex(of: "dictation.stopToInsertion"),
              let restoration = names.firstIndex(of: "dictation.teardown") else {
            XCTFail("Missing stop-to-insertion or restoration interval")
            await app.shutdown()
            return
        }
        XCTAssertLessThan(insertion, restoration)
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    func testEmptyTranscriptStopsTimingBeforeAudioRestoration() async throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled trace emission")
        let events = TraceCompletions()
        PerfTrace.onIntervalCompleted = { name, _, metadata in
            events.record(name: name, metadata: metadata)
        }
        let engine = StartupContextEngine()
        engine.finalTranscript = ""
        let app = app(engine: engine, capture: { _ in nil })
        await app.startDictation()
        Settings.shared.muteSystemAudioDuringRecordingEnabled = true
        await app.stopDictation()
        let names = events.names
        guard let insertion = names.firstIndex(of: "dictation.stopToInsertion"),
              let restoration = names.firstIndex(of: "audio.microphoneRestore") else {
            XCTFail("Missing stop-to-insertion or microphone-restoration interval")
            await app.shutdown()
            return
        }
        XCTAssertLessThan(insertion, restoration)
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    #endif
    private static func context(pid: pid_t, word: String) -> DictationContext {
        DictationContext(
            processIdentifier: pid, bundleIdentifier: "test.\(pid)", appName: "Editor",
            category: .other, documentURL: nil, documentTitle: nil,
            fieldRole: "AXTextArea", fieldSubrole: nil, fieldPurpose: .unknown,
            textBeforeCursor: "\(word) ", selectedText: "", textAfterCursor: "next",
            isSecureField: false, isContextExcluded: false
        )
    }
}

#if DEBUG
private final class TraceCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(name: String, metadata: String)] = []

    func record(name: String, metadata: String) {
        lock.withLock { records.append((name, metadata)) }
    }

    var names: [String] {
        lock.withLock { records.map(\.name) }
    }

    func metadata(for name: String) -> String? {
        lock.withLock { records.first { $0.name == name }?.metadata }
    }
}
#endif

private actor StartupContextGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<DictationContext?, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func capture() async -> DictationContext? {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resolve(_ context: DictationContext?) {
        continuation?.resume(returning: context)
        continuation = nil
    }
}

private actor StartupContextSequence {
    private var gates: [StartupContextGate]
    init(gates: [StartupContextGate]) { self.gates = gates }
    func capture() async -> DictationContext? { await gates.removeFirst().capture() }
}

@MainActor
private final class StartupContextEngine: TranscriptionEngine {
    var recoveryCapture: RecoveryAudioCapture?
    var isReady = true
    var currentTranscript = ""
    var audioSamples: [Float] = []
    var capturing = false
    var context: DictationContext?
    var contextAtFinalization: DictationContext?
    var vocabulary: [String] = []
    var vocabularyAtFinalization: [String] = []
    var appliedContexts: [DictationContext] = []
    var finalizationCount = 0
    var finalTranscript = "Recorded words."
    var onCaptureStopped: (() -> Void)?

    func levelSamples(count: Int) -> [Float] { [] }
    func prepare() async throws {}
    func startRecording(deviceID: AudioDeviceID?) async throws { capturing = true }
    func stopAudioCapture() async { capturing = false; onCaptureStopped?() }
    func stopRecording() async -> String {
        finalizationCount += 1
        contextAtFinalization = context
        vocabularyAtFinalization = vocabulary
        return finalTranscript
    }
    func cancel() async { capturing = false }
    func transcribeRecording(at url: URL) async throws -> String { "Restored words." }
    func setSessionContextualVocabulary(_ terms: [String]) { vocabulary = terms }
    func setSessionDictationContext(_ context: DictationContext?) {
        self.context = context
        if let context { appliedContexts.append(context) }
    }
}
