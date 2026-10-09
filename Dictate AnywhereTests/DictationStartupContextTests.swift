import XCTest
import CoreAudio
import FoundationModels
import os
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
        let vocabulary = settings.customVocabulary
        let model = settings.parakeetModelChoice
        let prewarm = settings.prewarmEnginesAtStartup
        let history = settings.transcriptHistory
        restoreSettings = {
            settings.engineChoice = engine
            settings.parakeetModelChoice = model
            settings.soundEffectsEnabled = sound
            settings.boostMicrophoneVolumeEnabled = boost
            settings.muteSystemAudioDuringRecordingEnabled = mute
            settings.preserveCancelledSessions = preserve
            settings.selectedMicrophoneUID = microphone
            settings.transcriptHistory = history
            settings.selectedLanguage = localLanguage
            settings.assemblyAILanguage = cloudLanguage
            settings.transcriptPostProcessingMode = processing
            settings.customVocabulary = vocabulary
            settings.prewarmEnginesAtStartup = prewarm
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
        cleanupPreparation: ((TranscriptPostProcessingMode) async -> Bool)? = nil,
        delivery: @escaping (String) async -> TextInsertionResult = { _ in .copiedOnly }
    ) -> AppState {
        let app = AppState(
            permissions: Permissions(statusProvider: { (true, false) }),
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            transcriptDelivery: delivery,
            contextCapture: capture,
            cleanupModelPreparation: cleanupPreparation
        )
        app.permissions.micGranted = true
        return app
    }

    func testModelPrewarmCanBeDeferredWithoutDisablingFirstUsePreparation() async {
        let engine = StartupContextEngine()
        engine.isReady = false
        let app = app(engine: engine, capture: { _ in nil })

        await app.prepareActiveEngine(prewarmModel: false)
        XCTAssertEqual(engine.prepareCount, 0)
        XCTAssertFalse(engine.isReady)

        await app.prepareActiveEngine()
        XCTAssertEqual(engine.prepareCount, 1)
        XCTAssertTrue(engine.isReady)
        await app.shutdown()
    }

    func testCleanupPreparationRespondsToSelectionLanguageOptOutAndIdleState() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .english
        settings.prewarmEnginesAtStartup = true
        var modes: [TranscriptPostProcessingMode] = []
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: {
            modes.append($0)
            return true
        })
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertTrue(modes.isEmpty)
        settings.transcriptPostProcessingMode = .s1Mini
        settings.prewarmEnginesAtStartup = false
        await app.prepareCleanupEngineIfNeeded()
        settings.prewarmEnginesAtStartup = true
        settings.selectedLanguage = .german
        await app.prepareCleanupEngineIfNeeded()
        settings.selectedLanguage = .english
        app.status = .recording
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertTrue(modes.isEmpty)
        app.status = .idle
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(modes, [.s1Mini])
        XCTAssertTrue(app.isCleanupEnginePrepared)
        app.status = .recording
        XCTAssertTrue(app.isCleanupEnginePrepared, "Recording must not make resident cleanup look cold")
        app.status = .idle
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(modes, [.s1Mini, .fluidAudioVocabulary])
        let oldKey = app.cleanupPreparationKey
        settings.customVocabulary = ["Quilter"]
        XCTAssertNotEqual(app.cleanupPreparationKey, oldKey)
        XCTAssertFalse(app.isCleanupEnginePrepared)
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(modes, [.s1Mini, .fluidAudioVocabulary, .fluidAudioVocabulary])
        settings.engineChoice = .assemblyAI
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(modes.count, 3)
        await app.shutdown()
    }

    func testRecordingJoinsMatchingIdleCleanupPreparation() async {
        let settings = Settings.shared
        let savedModel = settings.ollamaModel
        defer { settings.ollamaModel = savedModel }
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .ollama
        settings.ollamaModel = "test-model"
        settings.prewarmEnginesAtStartup = true
        let started = expectation(description: "idle cleanup started")
        let gate = StartupModelPreparationGate(started: started)
        var calls = 0
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return true
        })
        let idle = Task { await app.prepareCleanupEngineIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        await app.startDictation()
        XCTAssertEqual(app.status, .recording)
        // Allow the recording wrapper to join before releasing the owned task.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        await gate.release()
        await idle.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1, "Busy eligibility must not start a duplicate backend load")
        XCTAssertTrue(app.isCleanupEnginePrepared)
        await app.cancelDictation()
        XCTAssertFalse(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testCancelReleasesDictationWhileSharedRemotePreloadContinuesForNextRecording() async {
        let settings = Settings.shared
        let savedModel = settings.ollamaModel
        defer { settings.ollamaModel = savedModel }
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .ollama
        settings.ollamaModel = "test-model"
        settings.prewarmEnginesAtStartup = true
        let started = expectation(description: "remote cache loader started")
        let gate = StartupModelPreparationGate(started: started)
        let cache = TimedRequestCache<String, Bool>()
        let loads = OSAllocatedUnfairLock(initialState: 0)
        var secondPreparation: XCTestExpectation?
        var calls = 0
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in nil }, cleanupPreparation: { _ in
            calls += 1
            if calls == 2 { secondPreparation?.fulfill() }
            return (try? await cache.value(for: "remote") {
                loads.withLock { $0 += 1 }
                await gate.wait()
                return true
            }) ?? false
        })
        await app.startDictation()
        await fulfillment(of: [started], timeout: 2)
        let cancelled = expectation(description: "Cancel returns before the remote loader")
        let cancellation = Task { await app.cancelDictation(); cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 1)
        guard app.status == .idle else {
            await gate.release()
            await cancellation.value
            await app.shutdown()
            return
        }
        XCTAssertFalse(engine.capturing)
        XCTAssertFalse(app.isPreparingCleanupEngine)
        XCTAssertFalse(app.isCleanupEnginePrepared)
        let nextPreparation = expectation(description: "next recording joins the remote load")
        secondPreparation = nextPreparation
        await app.startDictation()
        await fulfillment(of: [nextPreparation], timeout: 2)
        XCTAssertEqual(app.status, .recording)
        XCTAssertTrue(engine.capturing, "Cancel must unlock the next recording without waiting for network work")
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while app.isPreparingCleanupEngine, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(app.isCleanupEnginePrepared)
        XCTAssertEqual(loads.withLock { $0 }, 1, "Cancelling a consumer must preserve the shared cache load")
        await cancellation.value
        await app.cancelDictation()
        await app.shutdown()
    }

    func testManualVocabularyPreparationWarmsSpeechOnceAndRejectsChangedConfiguration() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.prewarmEnginesAtStartup = false
        for changeSelection in [false, true] {
            settings.customVocabulary = ["Quilter"]
            let engine = StartupContextEngine()
            engine.isReady = false
            let started = expectation(description: "manual speech dependency preparation")
            let gate = StartupModelPreparationGate(started: started)
            engine.onPrepareAsync = { await gate.wait() }
            var calls = 0
            let app = app(engine: engine, capture: { _ in nil }, cleanupPreparation: { mode in
                XCTAssertEqual(mode, .fluidAudioVocabulary)
                XCTAssertTrue(engine.isReady)
                calls += 1
                return true
            })
            let preparing = Task { await app.prepareCleanupEngineIfNeeded(force: true) }
            await fulfillment(of: [started], timeout: 2)
            if changeSelection { settings.customVocabulary = ["Metal"] }
            await gate.release()
            await preparing.value
            XCTAssertEqual(engine.prepareCount, 1)
            XCTAssertTrue(engine.isReady)
            XCTAssertEqual(calls, changeSelection ? 0 : 1,
                           "One manual action must complete vocabulary preparation only for the requested configuration")
            XCTAssertEqual(app.isCleanupEnginePrepared, !changeSelection)
            await app.shutdown()
        }
    }

    func testCredentialRevisionInvalidatesPreparationDuringAnInFlightLoad() async {
        let settings = Settings.shared
        let savedModel = settings.openRouterModel
        let savedEnvironment = settings.openRouterAPIKeyEnvironmentVariable
        defer {
            settings.openRouterModel = savedModel
            settings.openRouterAPIKeyEnvironmentVariable = savedEnvironment
        }
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .openRouter
        settings.openRouterModel = "test/model"
        settings.openRouterAPIKeyEnvironmentVariable = "TEST_PREPARATION_CREDENTIAL_A"
        settings.prewarmEnginesAtStartup = true
        let started = expectation(description: "first credential revision started")
        let gate = StartupModelPreparationGate(started: started)
        var calls = 0
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return true
        })
        let firstKey = app.cleanupPreparationKey
        let first = Task { await app.prepareCleanupEngineIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        settings.openRouterAPIKeyEnvironmentVariable = "TEST_PREPARATION_CREDENTIAL_B"
        XCTAssertNotEqual(firstKey, app.cleanupPreparationKey)
        await gate.release()
        await first.value
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testAppleContextArrivalReplacesContextFreePreparation() async {
        guard #available(macOS 26, *) else { return }
        let settings = Settings.shared
        let savedContextAwareness = settings.dictationContextAwarenessEnabled
        defer { settings.dictationContextAwarenessEnabled = savedContextAwareness }
        settings.dictationContextAwarenessEnabled = true
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .appleIntelligence
        settings.prewarmEnginesAtStartup = true
        let captured = expectation(description: "context capture started")
        let contextGate = StartupContextGate(started: captured)
        let preparing = expectation(description: "context-free preparation started")
        let preparationGate = StartupModelPreparationGate(started: preparing)
        var calls = 0
        let app = app(engine: StartupContextEngine(), capture: { _ in await contextGate.capture() },
                      cleanupPreparation: { _ in
            calls += 1
            if calls == 1 { await preparationGate.wait() }
            return true
        })
        await app.startDictation()
        await fulfillment(of: [captured, preparing], timeout: 2)
        XCTAssertNil(app.cleanupPreparationKey.context)
        await contextGate.resolve(Self.context(pid: 1, word: "Quilter"))
        let deadline = ContinuousClock.now + .seconds(2)
        while app.cleanupPreparationKey.context == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(app.cleanupPreparationKey.context)
        await preparationGate.release()
        while (calls < 2 || app.isPreparingCleanupEngine), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(app.isCleanupEnginePrepared)
        await app.cancelDictation()
        await app.shutdown()
    }

    func testConcurrentCleanupPreparationsJoinAndShutdownWaitsForTheLoad() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .s1Mini
        settings.prewarmEnginesAtStartup = true
        let started = expectation(description: "cleanup preparation started")
        let gate = StartupModelPreparationGate(started: started)
        let engine = StartupContextEngine()
        engine.capturing = true
        var calls = 0
        let app = app(engine: engine, capture: { _ in nil }, cleanupPreparation: { _ in
            calls += 1
            await gate.wait()
            return true
        })
        let first = Task { await app.prepareCleanupEngineIfNeeded() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(app.isPreparingCleanupEngine)
        XCTAssertEqual(app.cleanupReadiness, .preparing)
        let second = Task { await app.prepareCleanupEngineIfNeeded() }
        let stopping = Task { await app.shutdown() }
        await Task.yield()
        XCTAssertTrue(engine.capturing, "Shutdown unloaded the engine while preparation was running")
        XCTAssertEqual(calls, 1)
        await gate.release()
        await first.value
        await second.value
        await stopping.value
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(engine.capturing)
        XCTAssertFalse(app.isPreparingCleanupEngine)
        XCTAssertFalse(app.isCleanupEnginePrepared)
    }

    func testManualCleanupPreparationReportsFailureAndCanRetryWithAutomaticPreparationDisabled() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .s1Mini
        settings.selectedLanguage = .english
        settings.prewarmEnginesAtStartup = false
        var succeeds = false
        var calls = 0
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { _ in
            calls += 1
            return succeeds
        })
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(calls, 0)
        await app.prepareCleanupEngineIfNeeded(force: true)
        guard case .failed = app.cleanupReadiness else { return XCTFail("Preparation failure must be visible") }
        succeeds = true
        await app.prepareCleanupEngineIfNeeded(force: true)
        XCTAssertEqual(app.cleanupReadiness, .ready)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(app.isCleanupEnginePrepared)
        settings.prewarmEnginesAtStartup = true
        XCTAssertEqual(app.cleanupReadiness, .ready, "Scheduling preference does not evict a prepared model")
        settings.prewarmEnginesAtStartup = false
        XCTAssertEqual(app.cleanupReadiness, .ready)
        await app.shutdown()
    }

    func testUnavailableAppleModelCannotInheritCachedPreparedReadiness() {
        guard #available(macOS 26, *) else { return }
        for availability in [SystemLanguageModel.Availability.unavailable(.deviceNotEligible),
                             .unavailable(.appleIntelligenceNotEnabled), .unavailable(.modelNotReady)] {
            XCTAssertFalse(AppState.appleCleanupReadiness(availability: availability, isPrepared: true).isReady)
        }
        XCTAssertEqual(AppState.appleCleanupReadiness(availability: .unavailable(.modelNotReady), isPrepared: true), .preparing)
        XCTAssertEqual(AppState.appleCleanupReadiness(availability: .available, isPrepared: false), .available)
        XCTAssertEqual(AppState.appleCleanupReadiness(availability: .available, isPrepared: true), .ready)
    }

    func testFirstUseRuntimeReadinessRespectsOptOutAndInvalidatesLostContext() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .s1Mini
        settings.selectedLanguage = .english
        settings.prewarmEnginesAtStartup = false
        var preparations = 0
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { _ in
            preparations += 1
            return true
        })
        let key = app.cleanupPreparationKey
        let installationStatus = app.cleanupReadiness
        XCTAssertFalse(installationStatus.isReady)
        app.recordS1MiniRuntimeReadiness(false, for: key)
        XCTAssertEqual(app.cleanupReadiness, installationStatus, "A transcript fallback must not claim runtime preparation")
        app.recordS1MiniRuntimeReadiness(true, for: key)
        XCTAssertEqual(app.cleanupReadiness, .ready)
        app.status = .recording
        XCTAssertEqual(app.cleanupReadiness, .ready)
        app.status = .idle
        await app.prepareCleanupEngineIfNeeded(force: true)
        XCTAssertEqual(preparations, 0, "A resident model does not need synthetic preparation after first use")
        app.recordS1MiniRuntimeReadiness(false, for: key)
        XCTAssertEqual(app.cleanupReadiness, installationStatus, "Discarding a failed inference context clears Ready")
        await app.shutdown()
        app.recordS1MiniRuntimeReadiness(true, for: key)
        XCTAssertFalse(app.isCleanupEnginePrepared)
    }

    func testFirstUseReadinessCannotAttachToAChangedCleanupSelection() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .s1Mini
        settings.selectedLanguage = .english
        let app = app(engine: StartupContextEngine(), capture: { _ in nil })
        let oldKey = app.cleanupPreparationKey
        settings.selectedLanguage = .german
        app.recordS1MiniRuntimeReadiness(true, for: oldKey)
        XCTAssertFalse(app.isCleanupEnginePrepared)
        guard case .unavailable = app.cleanupReadiness else { return XCTFail("Unsupported cleanup language must remain unavailable") }
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .none
        app.recordS1MiniRuntimeReadiness(true, for: oldKey)
        XCTAssertFalse(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testCancelledFirstUseCannotPublishReadyButCanClearLostContext() async {
        Settings.shared.engineChoice = .parakeet
        Settings.shared.transcriptPostProcessingMode = .s1Mini
        Settings.shared.selectedLanguage = .english
        let app = app(engine: StartupContextEngine(), capture: { _ in nil })
        let key = app.cleanupPreparationKey
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            app.recordS1MiniRuntimeReadiness(true, for: key)
        }.value
        XCTAssertFalse(app.isCleanupEnginePrepared)
        app.recordS1MiniRuntimeReadiness(true, for: key)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            app.recordS1MiniRuntimeReadiness(false, for: key)
        }.value
        XCTAssertFalse(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testS1ReadinessUsesTheActiveAppleSpeechLanguage() async {
        let settings = Settings.shared
        let previousAppleLanguage = settings.appleSpeechLanguage
        defer { settings.appleSpeechLanguage = previousAppleLanguage }
        settings.engineChoice = .appleSpeech
        settings.transcriptPostProcessingMode = .s1Mini
        settings.selectedLanguage = .german
        settings.appleSpeechLanguage = .english
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { _ in true })
        await app.prepareCleanupEngineIfNeeded(force: true)
        XCTAssertEqual(app.cleanupReadiness, .ready, "The inactive Parakeet language must not block English cleanup")
        settings.appleSpeechLanguage = .german
        guard case .unavailable = app.cleanupReadiness else { return XCTFail("The active unsupported language must override cached readiness") }
        XCTAssertFalse(app.canPrepareCleanupEngine)
        await app.shutdown()
    }

    func testRemotePreparationShowsConfiguredWithoutClaimingLocalReadiness() async {
        let settings = Settings.shared
        let previousModel = settings.ollamaModel
        defer { settings.ollamaModel = previousModel }
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .ollama
        settings.ollamaModel = "test-remote-model"
        settings.prewarmEnginesAtStartup = false
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { _ in true })
        XCTAssertEqual(app.cleanupReadiness, .configured)
        XCTAssertTrue(app.canPrepareCleanupEngine)
        await app.prepareCleanupEngineIfNeeded(force: true)
        XCTAssertTrue(app.isCleanupEnginePrepared)
        XCTAssertEqual(app.cleanupReadiness, .configured, "Remote discovery is not proof of an inference-ready local model")
        XCTAssertTrue(app.canPrepareCleanupEngine, "Manual preparation must remain available to refresh remote state")
        await app.shutdown()
    }

    func testCleanupChoiceChangedDuringPreparationIsPreparedAfterTheOldLoad() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .s1Mini
        settings.prewarmEnginesAtStartup = true
        let started = expectation(description: "first cleanup preparation started")
        let gate = StartupModelPreparationGate(started: started)
        var modes: [TranscriptPostProcessingMode] = []
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { mode in
            modes.append(mode)
            if mode == .s1Mini { await gate.wait() }
            return true
        })
        let first = Task { await app.prepareCleanupEngineIfNeeded() }
        await fulfillment(of: [started], timeout: 5)
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        let joining = expectation(description: "changed choice joins the active load")
        let changed = Task {
            joining.fulfill()
            await app.prepareCleanupEngineIfNeeded()
        }
        await fulfillment(of: [joining], timeout: 2)
        await gate.release()
        await first.value
        await changed.value
        XCTAssertEqual(modes, [.s1Mini, .fluidAudioVocabulary])
        XCTAssertTrue(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testIndependentSelectedEnginesBeginPreparationBeforeEitherCompletes() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .s1Mini
        settings.prewarmEnginesAtStartup = true
        let speechStarted = expectation(description: "speech preparation started")
        let cleanupStarted = expectation(description: "cleanup preparation started")
        let speechGate = StartupModelPreparationGate(started: speechStarted)
        let cleanupGate = StartupModelPreparationGate(started: cleanupStarted)
        let engine = StartupContextEngine()
        engine.isReady = false
        engine.onPrepareAsync = { await speechGate.wait() }
        let app = app(engine: engine, capture: { _ in nil }, cleanupPreparation: { _ in
            XCTAssertFalse(engine.isReady, "Independent cleanup must start before speech completes")
            await cleanupGate.wait()
            return true
        })
        let preparation = Task { await app.prepareSelectedEngines() }
        await fulfillment(of: [speechStarted, cleanupStarted], timeout: 2)
        XCTAssertFalse(engine.isReady)
        XCTAssertTrue(app.isPreparingCleanupEngine)
        await speechGate.release()
        await cleanupGate.release()
        await preparation.value
        XCTAssertTrue(engine.isReady)
        XCTAssertTrue(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testAppleLanguageFallbackResolvesBeforeIndependentCleanupEligibility() async {
        let settings = Settings.shared
        let savedAppleLanguage = settings.appleSpeechLanguage
        defer { settings.appleSpeechLanguage = savedAppleLanguage }
        settings.engineChoice = .appleSpeech
        settings.appleSpeechLanguage = .german
        settings.transcriptPostProcessingMode = .s1Mini
        settings.prewarmEnginesAtStartup = true
        let engine = StartupContextEngine()
        engine.isReady = false
        var cleanupCalls = 0
        var assetSnapshots = 0
        let app = AppState(
            permissions: Permissions(statusProvider: { (true, false) }),
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            appleSpeechAssetSnapshot: {
                assetSnapshots += 1
                return ([.english], [])
            },
            cleanupModelPreparation: { _ in
                cleanupCalls += 1
                XCTAssertEqual(settings.appleSpeechLanguage, .english)
                return true
            }
        )
        await app.prepareSelectedEngines()
        XCTAssertEqual(settings.appleSpeechLanguage, .english)
        XCTAssertEqual(cleanupCalls, 1, "English-only cleanup must see the resolved speech language")
        XCTAssertEqual(assetSnapshots, 1, "Resolve configuration once before loading both engines")
        XCTAssertEqual(engine.prepareCount, 1)
        XCTAssertTrue(app.isCleanupEnginePrepared)
        await app.shutdown()
    }

    func testVocabularyPreparationWaitsForSpeechAndOptOutDoesNotLoadCleanup() async {
        let settings = Settings.shared
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.prewarmEnginesAtStartup = true
        let speechStarted = expectation(description: "vocabulary speech load started")
        let speechGate = StartupModelPreparationGate(started: speechStarted)
        let engine = StartupContextEngine()
        engine.isReady = false
        engine.onPrepareAsync = { await speechGate.wait() }
        var calls = 0
        let app = app(engine: engine, capture: { _ in nil }, cleanupPreparation: { _ in
            calls += 1
            XCTAssertTrue(engine.isReady, "Vocabulary needs the selected speech weights")
            return true
        })
        let preparation = Task { await app.prepareSelectedEngines() }
        await fulfillment(of: [speechStarted], timeout: 2)
        XCTAssertEqual(calls, 0)
        await speechGate.release()
        await preparation.value
        XCTAssertEqual(calls, 1)
        await app.prepareSelectedEngines(prewarmModel: false)
        XCTAssertEqual(calls, 1)
        settings.prewarmEnginesAtStartup = false
        settings.transcriptPostProcessingMode = .s1Mini
        await app.prepareSelectedEngines()
        XCTAssertEqual(calls, 1)
        await app.shutdown()
    }

    func testConcurrentPreparationJoinsTheInFlightModelLoad() async {
        let started = expectation(description: "model preparation started")
        let gate = StartupModelPreparationGate(started: started)
        let engine = StartupContextEngine()
        engine.isReady = false
        engine.onPrepareAsync = { await gate.wait() }
        let app = app(engine: engine, capture: { _ in nil })

        let startup = Task { await app.prepareActiveEngine() }
        await fulfillment(of: [started], timeout: 5)
        let firstUse = Task { await app.prepareActiveEngine() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.prepareCount, 1)

        await gate.release()
        await startup.value
        await firstUse.value
        XCTAssertEqual(engine.prepareCount, 1)
        XCTAssertTrue(engine.isReady)
        await app.shutdown()
    }

    func testAppleCleanupPreparationTracksPromptVocabularyAndOptOut() async {
        guard #available(macOS 26, *) else { return }
        let settings = Settings.shared
        let savedPrompt = settings.aiPostProcessingPrompt
        let savedVocabulary = settings.customVocabulary
        defer { settings.aiPostProcessingPrompt = savedPrompt; settings.customVocabulary = savedVocabulary }
        settings.engineChoice = .parakeet
        settings.transcriptPostProcessingMode = .appleIntelligence
        settings.prewarmEnginesAtStartup = true
        var calls = 0
        let app = app(engine: StartupContextEngine(), capture: { _ in nil }, cleanupPreparation: { mode in
            XCTAssertEqual(mode, .appleIntelligence)
            calls += 1
            return true
        })
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertTrue(app.isCleanupEnginePrepared)
        settings.aiPostProcessingPrompt = "Keep all numbers."
        XCTAssertFalse(app.isCleanupEnginePrepared)
        await app.prepareCleanupEngineIfNeeded()
        settings.customVocabulary = ["Metal"]
        XCTAssertFalse(app.isCleanupEnginePrepared)
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(calls, 3)
        settings.prewarmEnginesAtStartup = false
        await app.prepareCleanupEngineIfNeeded()
        XCTAssertEqual(calls, 3)
        await app.shutdown()
    }

    func testApplePreparationOverlapsRecordingWithoutBlockingMicrophone() async {
        guard #available(macOS 26, *) else { return }
        Settings.shared.engineChoice = .parakeet
        Settings.shared.transcriptPostProcessingMode = .appleIntelligence
        Settings.shared.prewarmEnginesAtStartup = true
        let started = expectation(description: "Apple cleanup preparation began")
        let gate = StartupModelPreparationGate(started: started)
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in nil }, cleanupPreparation: { _ in
            XCTAssertTrue(engine.capturing, "Cleanup must not postpone microphone capture")
            await gate.wait()
            return true
        })
        await app.startDictation()
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(app.status, .recording)
        let cancellation = Task { await app.cancelDictation() }
        let deadline = ContinuousClock.now + .seconds(2)
        while engine.capturing, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(engine.capturing, "Cancellation must stop capture before waiting for preparation")
        XCTAssertEqual(app.status, .recording, "Local session preparation must finish before teardown permits reuse")
        XCTAssertFalse(app.canStopDictation)
        await gate.release()
        await cancellation.value
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    func testStartupAppliesInputSourceProfileBeforePrewarmingSpeechModel() async {
        let settings = Settings.shared
        let savedModel = settings.parakeetModelChoice
        let savedMappings = settings.inputSourceMappings
        let savedAutoSwitch = settings.inputSourceAutoSwitchEnabled
        let savedPrewarm = settings.prewarmEnginesAtStartup
        let savedUserChoice = settings.userHasChosenEngine
        let savedHotkeys = settings.hotkeyBindings
        let savedCancelShortcut = settings.cancelShortcut
        defer {
            settings.parakeetModelChoice = savedModel
            settings.inputSourceMappings = savedMappings
            settings.inputSourceAutoSwitchEnabled = savedAutoSwitch
            settings.prewarmEnginesAtStartup = savedPrewarm
            settings.userHasChosenEngine = savedUserChoice
            settings.hotkeyBindings = savedHotkeys
            settings.cancelShortcut = savedCancelShortcut
        }

        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .english
        settings.userHasChosenEngine = true
        settings.prewarmEnginesAtStartup = true
        settings.inputSourceAutoSwitchEnabled = true
        settings.inputSourceMappings = [InputSourceMapping(
            id: UUID(), inputSourceID: "startup-profile-test", inputSourceDisplayName: "Test",
            engine: .parakeet, parakeetModel: .multilingual, language: .german
        )]
        settings.hotkeyBindings = []
        settings.cancelShortcut = HotkeyBinding(
            id: UUID(), keyCode: nil, modifiersRawValue: 0,
            displayName: "", mode: .handsFreeToggle
        )

        let prepared = expectation(description: "speech model prepared")
        let engine = StartupContextEngine()
        engine.isReady = false
        engine.onPrepare = { prepared.fulfill() }
        let app = AppState(
            permissions: Permissions(statusProvider: { (true, true) }),
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            inputSourceID: { "startup-profile-test" },
            profileModelAvailable: { _ in true },
            appleSpeechAssetSnapshot: { ([], []) }
        )

        app.start()
        await fulfillment(of: [prepared], timeout: 10)
        XCTAssertEqual(engine.languageAtPreparation, .german)
        XCTAssertEqual(engine.prepareCount, 1)
        await app.shutdown()
    }

    func testLocalFinalizationOverlapsContextButDeliveryWaitsForContext() async {
        let captured = expectation(description: "context capture began")
        let gate = StartupContextGate(started: captured)
        let engine = StartupContextEngine()
        engine.requiresContextBeforeFinalization = false
        let finalized = expectation(description: "local decoding completed before context")
        engine.onFinalized = { finalized.fulfill() }
        var delivered: [String] = []
        let app = app(engine: engine, capture: { _ in await gate.capture() }, delivery: {
            delivered.append($0)
            return .copiedOnly
        })
        await app.startDictation()
        await fulfillment(of: [captured], timeout: 2)
        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [finalized], timeout: 2)
        XCTAssertFalse(engine.capturing)
        XCTAssertNil(engine.contextAtFinalization)
        XCTAssertTrue(delivered.isEmpty)
        let context = Self.context(pid: 123, word: "Zephyr")
        await gate.resolve(context)
        await stopping.value
        XCTAssertTrue(engine.appliedContexts.contains(context))
        XCTAssertEqual(delivered, ["Recorded words."])
        await app.shutdown()
    }

    func testCancellingLocalFinalizationDropsLateContextAndDelivery() async {
        let captured = expectation(description: "context capture began")
        let gate = StartupContextGate(started: captured)
        let engine = StartupContextEngine()
        engine.requiresContextBeforeFinalization = false
        let finalized = expectation(description: "local decoding completed")
        engine.onFinalized = { finalized.fulfill() }
        var delivered: [String] = []
        let app = app(engine: engine, capture: { _ in await gate.capture() }, delivery: {
            delivered.append($0)
            return .copiedOnly
        })
        await app.startDictation()
        await fulfillment(of: [captured], timeout: 2)
        let stopping = Task { await app.stopDictation() }
        await fulfillment(of: [finalized], timeout: 2)
        await app.cancelDictation()
        await gate.resolve(Self.context(pid: 123, word: "Stale"))
        await stopping.value
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(Settings.shared.transcriptHistory.isEmpty)
        XCTAssertNil(engine.context)
        XCTAssertEqual(app.status, .idle)
        await app.shutdown()
    }

    func testSlowContextDoesNotDelayListeningAndStopClosesMicrophoneBeforeWaiting() async {
        let captured = expectation(description: "context capture began")
        let gate = StartupContextGate(started: captured)
        let engine = StartupContextEngine()
        var delivered: [String] = []
        let app = app(engine: engine, capture: { _ in await gate.capture() }, delivery: {
            delivered.append($0)
            return .copiedOnly
        })
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

    func testSameLengthLiveCorrectionReachesDisplayedTranscript() async {
        let engine = StartupContextEngine()
        let app = app(engine: engine, capture: { _ in nil })
        await app.startDictation()
        engine.currentTranscript = "cats"
        await waitForTranscript("cats", in: app)
        engine.currentTranscript = "dogs"
        await waitForTranscript("dogs", in: app)
        XCTAssertEqual(app.currentTranscript, "dogs")
        await app.cancelDictation()
        await app.shutdown()
    }

    private func waitForTranscript(_ text: String, in app: AppState) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while app.currentTranscript != text, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.currentTranscript, text)
    }

    #if DEBUG
    func testEveryFinishPathRestoresSavedOutputRegardlessOfCurrentSetting() async throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled trace emission")
        for flow in ["success", "empty", "failure", "cancel"] {
            for didMute in [false, true] {
                let events = TraceCompletions()
                PerfTrace.onIntervalCompleted = { name, _, metadata in
                    events.record(name: name, metadata: metadata)
                }
                let engine = StartupContextEngine()
                engine.finalTranscript = flow == "empty" ? "" : "Recorded words."
                engine.lastTranscriptionError = flow == "failure" ? "Recognition failed" : nil
                let app = app(engine: engine, capture: { _ in nil })
                Settings.shared.muteSystemAudioDuringRecordingEnabled = false
                await app.startDictation()
                app.volumeController.installOutputMuteStateForTesting(didMuteForRecording: didMute)
                if flow == "cancel" {
                    await app.cancelDictation()
                } else {
                    await app.stopDictation()
                }
                XCTAssertEqual(app.status, .idle, flow)
                XCTAssertFalse(app.volumeController.hasOutputStateToRestore, flow)
                XCTAssertEqual(
                    events.names.filter { $0 == "audio.restoreSettle" }.count,
                    didMute ? 1 : 0, flow
                )
                XCTAssertEqual(events.names.filter { $0 == "audio.systemRestore" }.count, 1, flow)
                await app.shutdown()
                PerfTrace.onIntervalCompleted = nil
            }
        }
    }

    func testEveryFinishPathSkipsSettleWhenNoOutputStateWasSaved() async throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled trace emission")
        for flow in ["success", "empty", "failure", "cancel"] {
            let events = TraceCompletions()
            PerfTrace.onIntervalCompleted = { name, _, metadata in
                events.record(name: name, metadata: metadata)
            }
            let engine = StartupContextEngine()
            engine.finalTranscript = flow == "empty" ? "" : "Recorded words."
            engine.lastTranscriptionError = flow == "failure" ? "Recognition failed" : nil
            let app = app(engine: engine, capture: { _ in nil })
            Settings.shared.muteSystemAudioDuringRecordingEnabled = false
            await app.startDictation()
            Settings.shared.muteSystemAudioDuringRecordingEnabled = true
            if flow == "cancel" {
                await app.cancelDictation()
            } else {
                await app.stopDictation()
            }
            XCTAssertEqual(app.status, .idle, flow)
            XCTAssertFalse(events.names.contains("audio.restoreSettle"), flow)
            await app.shutdown()
            PerfTrace.onIntervalCompleted = nil
        }
    }

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
nonisolated private final class TraceCompletions: @unchecked Sendable {
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

private actor StartupModelPreparationGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class StartupContextEngine: TranscriptionEngine {
    var recoveryCapture: RecoveryAudioCapture?
    var isReady = true
    var requiresContextBeforeFinalization = true
    var currentTranscript = ""
    var audioSamples: [Float] = []
    var capturing = false
    var context: DictationContext?
    var contextAtFinalization: DictationContext?
    var vocabulary: [String] = []
    var vocabularyAtFinalization: [String] = []
    var appliedContexts: [DictationContext] = []
    var finalizationCount = 0
    var prepareCount = 0
    var languageAtPreparation: SupportedLanguage?
    var onPrepare: (() -> Void)?
    var onPrepareAsync: (() async -> Void)?
    var finalTranscript = "Recorded words."
    var lastTranscriptionError: String?
    var onCaptureStopped: (() -> Void)?
    var onFinalized: (() -> Void)?

    func levelSamples(count: Int) -> [Float] { [] }
    func prepare() async throws {
        prepareCount += 1
        languageAtPreparation = Settings.shared.selectedLanguage
        await onPrepareAsync?()
        isReady = true
        onPrepare?()
    }
    func startRecording(deviceID: AudioDeviceID?) async throws { capturing = true }
    func stopAudioCapture() async {
        guard capturing else { return }
        capturing = false
        onCaptureStopped?()
    }
    func stopRecording() async -> String {
        finalizationCount += 1
        contextAtFinalization = context
        vocabularyAtFinalization = vocabulary
        onFinalized?()
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
