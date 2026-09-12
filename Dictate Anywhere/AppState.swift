//
//  AppState.swift
//  Dictate Anywhere
//
//  Central observable state. Owns all services and orchestrates dictation flow.
//

import Foundation
import AppKit
import CoreAudio
import os
import FoundationModels

@Observable
@MainActor
final class AppState {
    // MARK: - Dictation Status

    enum DictationStatus: Equatable {
        case idle
        case recording
        case processing
        case error(String)
    }

    struct OllamaDownloadState: Equatable {
        let model: String
        let status: String
        let fractionCompleted: Double?
        let completed: Int64?
        let total: Int64?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppState"
    )

    var status: DictationStatus = .idle {
        didSet { updateCancellationAvailability() }
    }
    var currentTranscript = ""
    var lastTranscript = ""
    var selectedPage: SidebarPage = .models
    var ollamaDownloadState: OllamaDownloadState?
    var ollamaDeletingModel: String?
    var ollamaModelActionError: String?
    var ollamaModelActionsRevision = 0
    var enginePreparationError: String?

    /// Static accessor for AppDelegate menu bar (avoids circular dependency)
    nonisolated(unsafe) static var lastTranscriptForMenuBar = ""

    // MARK: - Services

    let permissions: Permissions
    let settings = Settings.shared
    let hotkeyService = HotkeyService()
    let audioMonitor = AudioMonitor()
    let volumeController = VolumeController()
    let textInserter = TextInserter()
    let overlay = OverlayWindow()
    let audioDeviceManager = AudioDeviceManager()
    let parakeetEngine = ParakeetEngine()
    let appleSpeechEngine = AppleSpeechEngine()
    let s1MiniModelManager = S1MiniModelManager()
    let inputSourceMonitor = InputSourceMonitor()
    let recoveryStore: DictationRecoveryStore
    private var recoveryCapture: RecoveryAudioCapture?
    private var completedRecognitionTranscript: String?
    private var processingTask: Task<Void, Never>?
    private var processingOperationID: UUID?
    private var isCancelling = false
    private var isDeliveringTranscript = false
    private(set) var recoveringEntryID: UUID?
    private(set) var continuingEntryID: UUID?
    private var transcriptPrefix = ""
    private var previousRecordingDuration: TimeInterval = 0
    private var continuationTargetBundleIdentifier: String?
    private let engineOverride: TranscriptionEngine?
    private let transcriptDeliveryOverride: ((String) async -> TextInsertionResult)?

    var canCancelDictation: Bool {
        (status == .recording || status == .processing)
            && !isCancelling && !isDeliveringTranscript && recoveringEntryID == nil
    }

    var canStopDictation: Bool { status == .recording && !isTransitioning }

    private func updateCancellationAvailability() {
        hotkeyService.isCancellationEnabled = canCancelDictation
    }
    var appleSpeechSupportedLanguages: [SupportedLanguage] = []
    var appleSpeechInstalledLanguages: [SupportedLanguage] = []
    private var isShowingMigrationAlert = false

    /// Whether the app is transitioning between states (simple guard)
    private var isTransitioning = false

    /// Set when a hold-to-record key-up arrives during a transition (race condition guard)
    private var pendingHoldRelease = false

    private(set) var isHoldToRecordKeyDown = false

    /// True while prepareActiveEngine is running (suppresses transient "not ready" warnings)
    var isPreparingEngine = false

    /// Audio level polling loop
    private var audioLevelTask: Task<Void, Never>?

    /// App that was frontmost when dictation started (used as paste target)
    private var insertionTargetApp: NSRunningApplication?
    private var sessionDictationContext: DictationContext?

    /// Engine pinned for the active dictation session (start -> stop/cancel).
    private var sessionEngine: TranscriptionEngine?
    private var sessionHotkeyMode: HotkeyMode?
    private var activeRecordingStartupID: UUID?
    private var startupTask: Task<Void, Never>?
    private var hasStarted = false
    private var isShuttingDown = false

    /// Serializes profile applies; a change arriving mid-apply queues behind it.
    private var inputSourceApplyTask: Task<Void, Never>?

    /// Optional test hook for suspending the first microphone permission request.
    private let microphonePermissionRequester: (@MainActor @Sendable () async -> Bool)?

    // MARK: - Active Engine

    var activeEngine: TranscriptionEngine {
        if let engineOverride { return engineOverride }
        switch settings.engineChoice {
        case .parakeet:
            return parakeetEngine
        case .appleSpeech:
            return AppleSpeechEngine.isSupported ? appleSpeechEngine : parakeetEngine
        }
    }

    var availableEngineChoices: [TranscriptionEngineChoice] {
        TranscriptionEngineChoice.allCases
    }

    // MARK: - Initialization

    init(
        permissions: Permissions? = nil,
        microphonePermissionRequester: (@MainActor @Sendable () async -> Bool)? = nil,
        recoveryStore: DictationRecoveryStore? = nil,
        engine: TranscriptionEngine? = nil,
        transcriptDelivery: ((String) async -> TextInsertionResult)? = nil
    ) {
        self.permissions = permissions ?? Permissions()
        self.microphonePermissionRequester = microphonePermissionRequester
        self.recoveryStore = recoveryStore ?? DictationRecoveryStore()
        self.engineOverride = engine
        self.transcriptDeliveryOverride = transcriptDelivery
        setupHotkeyCallbacks()
        setupPermissionCallbacks()
        setupInputSourceCallbacks()
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyService.onKeyDown = { [weak self] binding in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch binding.mode {
                case .holdToRecord:
                    self.isHoldToRecordKeyDown = true
                    await self.startDictation(mode: binding.mode)
                case .handsFreeToggle:
                    if self.status == .recording {
                        await self.stopDictation()
                    } else {
                        await self.startDictation(mode: binding.mode)
                    }
                }
            }
        }

        hotkeyService.onKeyUp = { [weak self] binding in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard binding.mode == .holdToRecord else { return }
                self.isHoldToRecordKeyDown = false
                if self.status == .recording, !self.isTransitioning {
                    await self.stopDictation()
                } else if self.isTransitioning {
                    // Key released while startDictation() is still running;
                    // startDictation will check this flag after its transition.
                    self.pendingHoldRelease = true
                }
            }
        }

        hotkeyService.onCancel = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancelDictation()
            }
        }
        hotkeyService.onCancelProgress = { [weak self] progress in
            self?.overlay.setCancellationProgress(progress)
        }
    }

    private func setupPermissionCallbacks() {
        permissions.onAccessibilityPermissionChanged = { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.handleAccessibilityPermissionChanged(granted)
            }
        }
    }

    private func setupInputSourceCallbacks() {
        inputSourceMonitor.onSelectedInputSourceChanged = { [weak self] inputSourceID in
            self?.enqueueInputSourceProfileApply(for: inputSourceID)
        }
    }

    func start() {
        guard !hasStarted, !isShuttingDown else { return }
        hasStarted = true
        do { try recoveryStore.reload() } catch { recoveryStore.errorMessage = error.localizedDescription }

        Task { [weak self] in
            await self?.s1MiniModelManager.refreshInstallationState()
        }
        startupTask = Task { [weak self] in
            await self?.runStartupSequence()
        }
    }

    /// Stops process-lifetime services before AppKit tears down the process.
    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        startupTask?.cancel()
        startupTask = nil
        inputSourceApplyTask?.cancel()
        inputSourceApplyTask = nil
        activeRecordingStartupID = nil
        processingTask?.cancel()
        stopAudioLevelPolling()
        inputSourceMonitor.stopMonitoring()
        hotkeyService.stopMonitoring()
        permissions.stopPolling()

        // A cancelled finish task must unwind before its engine can be unloaded.
        await processingTask?.value
        processingTask = nil
        processingOperationID = nil

        let engine = sessionEngine ?? activeEngine
        await engine.cancel()
        if engine !== parakeetEngine { await parakeetEngine.cancel() }
        if engine !== appleSpeechEngine { await appleSpeechEngine.cancel() }
        await appleSpeechEngine.invalidatePreparedSession()

        recoveryCapture = nil
        completedRecognitionTranscript = nil
        engine.recoveryCapture = nil
        engine.setSessionContextualVocabulary([])
        clearEndOfUtteranceHandler(for: engine)
        sessionEngine = nil
        sessionHotkeyMode = nil
        continuingEntryID = nil
        recoveringEntryID = nil
        transcriptPrefix = ""
        previousRecordingDuration = 0
        continuationTargetBundleIdentifier = nil
        insertionTargetApp = nil
        sessionDictationContext = nil
        currentTranscript = ""
        isDeliveringTranscript = false
        isCancelling = false
        isTransitioning = false
        status = .idle
        volumeController.restoreMicrophoneVolume()
        volumeController.restoreAfterRecording()
        overlay.hide(afterDelay: 0)
    }

    private func runStartupSequence() async {
        await permissions.check()
        guard !isShuttingDown else { return }
        updateAccessibilityIntegration(granted: permissions.accessibilityGranted, promptIfNeeded: true)
        await prepareActiveEngine()
        guard !isShuttingDown else { return }
        await refreshAppleSpeechAssetState()
        guard !isShuttingDown else { return }
        inputSourceMonitor.startMonitoring()
        if settings.inputSourceAutoSwitchEnabled,
           let inputSourceID = inputSourceMonitor.currentInputSourceID() {
            await enqueueInputSourceProfileApply(for: inputSourceID).value
        }
    }

    private func handleAccessibilityPermissionChanged(_ granted: Bool) {
        updateAccessibilityIntegration(granted: granted, promptIfNeeded: false)
    }

    private func updateAccessibilityIntegration(granted: Bool, promptIfNeeded: Bool) {
        guard !isShuttingDown else { return }
        if granted {
            permissions.stopPolling()
            if (settings.hasHotkey || settings.cancelShortcut.hasBinding) && !hotkeyService.isMonitoring {
                hotkeyService.startMonitoring()
            }
        } else {
            hotkeyService.stopMonitoring()
            if promptIfNeeded {
                permissions.promptForAccessibility()
            }
            permissions.startPolling()
        }
    }

    // MARK: - Engine Lifecycle

    func prepareActiveEngine() async {
        guard !isShuttingDown else { return }
        logger.info("prepareActiveEngine: called, engineChoice=\(String(describing: self.settings.engineChoice), privacy: .public), status=\(String(describing: self.status), privacy: .public)")
        if case .recording = status { return }
        if case .processing = status { return }
        if case .error = status { status = .idle }

        switch settings.engineChoice {
        case .parakeet:
            // Auto-default: if the user hasn't explicitly chosen an engine and
            // a speech model is downloaded, ensure FluidAudio is selected.
            await parakeetEngine.recheckAllModelsOnDisk()
            guard !isShuttingDown else { return }
            await parakeetEngine.handleSelectedModelChange()
            guard !isShuttingDown else { return }
            let hasSpeechModel = parakeetEngine.checkAnyModelOnDisk()
            if !settings.userHasChosenEngine, hasSpeechModel {
                settings.engineChoice = .parakeet
            }
            if hasSpeechModel {
                settings.legacyAppleSpeechMigrationPending = false
            }
        case .appleSpeech:
            await refreshAppleSpeechAssetState()
            guard !isShuttingDown else { return }
            if !appleSpeechSupportedLanguages.contains(settings.appleSpeechLanguage),
               let fallback = appleSpeechSupportedLanguages.first {
                settings.appleSpeechLanguage = fallback
            }
            settings.legacyAppleSpeechMigrationPending = false
        }

        let ready = activeEngine.isReady
        logger.info("prepareActiveEngine: activeEngine.isReady=\(ready, privacy: .public), willCallPrepare=\(!ready, privacy: .public)")
        if !ready {
            // Set synchronously so the UI sees it before any await yields
            isPreparingEngine = true
            enginePreparationError = nil
            do {
                try await activeEngine.prepare()
                guard !isShuttingDown else {
                    await activeEngine.cancel()
                    return
                }
            } catch {
                logger.error("prepareActiveEngine: prepare() failed on first attempt: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
                guard !isShuttingDown else { return }
                do {
                    try await activeEngine.prepare()
                    guard !isShuttingDown else {
                        await activeEngine.cancel()
                        return
                    }
                } catch {
                    logger.error("prepareActiveEngine: prepare() failed on retry: \(error.localizedDescription, privacy: .public)")
                    enginePreparationError = error.localizedDescription
                }
            }
            logger.info("prepareActiveEngine: prepare() completed, isReady=\(self.activeEngine.isReady, privacy: .public)")
        }
        // A just-completed prepare may have installed the Apple Speech asset
        // the input-source mapping hint is watching; refresh so the hint
        // clears without waiting for settings to reopen.
        if settings.engineChoice == .appleSpeech {
            appleSpeechInstalledLanguages = await AppleSpeechEngine.installedLanguages()
            guard !isShuttingDown else { return }
        }
        isPreparingEngine = false
    }

    func handleParakeetModelSelectionChange(userInitiated: Bool) async {
        guard status == .idle else { return }
        settings.engineChoice = .parakeet
        settings.userHasChosenEngine = userInitiated
        await parakeetEngine.handleSelectedModelChange()
        await prepareActiveEngine()
    }

    func handleEngineSelectionChange(_ choice: TranscriptionEngineChoice) async {
        guard status == .idle else { return }
        guard availableEngineChoices.contains(choice) else { return }
        guard choice != .appleSpeech || AppleSpeechEngine.isSupported else { return }

        if choice != .appleSpeech {
            await appleSpeechEngine.invalidatePreparedSession()
        }
        enginePreparationError = nil
        settings.engineChoice = choice
        settings.userHasChosenEngine = true
        await prepareActiveEngine()
    }

    func handleAppleSpeechLanguageChange(_ language: SupportedLanguage) async {
        guard status == .idle, settings.engineChoice == .appleSpeech else { return }
        guard appleSpeechSupportedLanguages.contains(language) else { return }
        settings.appleSpeechLanguage = language
        await appleSpeechEngine.invalidatePreparedSession()
        await prepareActiveEngine()
    }

    /// Refreshes both the supportable and the installed Apple Speech language
    /// sets. Installed state drives the input-source mapping UI, so it must be
    /// fresh even while FluidAudio is the active engine.
    func refreshAppleSpeechAssetState() async {
        appleSpeechSupportedLanguages = await AppleSpeechEngine.supportedLanguages()
        appleSpeechInstalledLanguages = await AppleSpeechEngine.installedLanguages()
    }

    // MARK: - Input Source Auto-Switch

    /// Serializes calls to `applyInputSourceProfile` so overlapping input
    /// source changes apply in order. Internal (not private) so callers
    /// outside AppState — e.g. the startup sequence and settings UI — also
    /// go through the queue instead of calling `applyInputSourceProfile`
    /// directly.
    @discardableResult
    func enqueueInputSourceProfileApply(
        for inputSourceID: String,
        showLoadingOverlay: Bool = false
    ) -> Task<Void, Never> {
        let previous = inputSourceApplyTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.applyInputSourceProfile(for: inputSourceID, showLoadingOverlay: showLoadingOverlay)
        }
        inputSourceApplyTask = task
        return task
    }

    func applyInputSourceProfile(for inputSourceID: String, showLoadingOverlay: Bool = false) async {
        guard !isShuttingDown else { return }
        // Looked up (and, for Apple Speech, awaited) before the idle guard so
        // no suspension point lands between the guard and the settings
        // writes below — an in-flight recording-start guard check must never
        // race a suspended apply.
        let mapping = settings.mapping(forInputSourceID: inputSourceID)
        let installedAppleSpeechLanguages = mapping?.engine == .appleSpeech
            ? await AppleSpeechEngine.installedLanguages()
            : []
        guard !isShuttingDown else { return }
        guard status == .idle else { return }
        if mapping?.engine == .appleSpeech {
            appleSpeechInstalledLanguages = installedAppleSpeechLanguages
        }
        let resolution = InputSourceProfileResolver.resolve(
            mapping: mapping,
            enabled: settings.inputSourceAutoSwitchEnabled,
            currentEngine: settings.engineChoice,
            currentParakeetModel: settings.parakeetModelChoice,
            currentFluidAudioLanguage: settings.selectedLanguage,
            currentAppleSpeechLanguage: settings.appleSpeechLanguage,
            appleSpeechSupported: AppleSpeechEngine.isSupported,
            // Availability = on disk AND runnable by this process (FluidAudio
            // hard-fails Nemotron multilingual under Rosetta/x86_64).
            isModelDownloaded: { parakeetEngine.checkModelOnDisk(for: $0) && $0.isAvailableOnThisMac },
            isAppleSpeechAssetInstalled: { installedAppleSpeechLanguages.contains($0) }
        )

        var targetEngine = "n/a"
        var targetModel = "n/a"
        if case .fullApply = resolution, let mapping {
            targetEngine = mapping.engine.rawValue
            targetModel = mapping.parakeetModel?.rawValue ?? "n/a"
        }
        logger.info(
            "applyInputSourceProfile: inputSourceID=\(inputSourceID, privacy: .public), resolution=\(String(describing: resolution), privacy: .public), targetEngine=\(targetEngine, privacy: .public), targetModel=\(targetModel, privacy: .public)"
        )

        switch resolution {
        case .none, .inactive:
            return

        case .noChange:
            // A source mapped to the already-active vocab-capable model must
            // still trigger the restore (e.g. a prior switch away stripped
            // `.fluidAudioVocabulary` and this source maps back to it).
            settings.restoreVocabularyModeAfterAutoSwitchIfPending()
            return

        case .languageOnly(let language):
            guard let mapping else { return }
            switch mapping.engine {
            case .parakeet:
                // Read at recording start; no engine reload needed.
                settings.selectedLanguage = language
            case .appleSpeech:
                if showLoadingOverlay { overlay.show(state: .preparingModel(name: "Apple Speech")) }
                await handleAppleSpeechLanguageChange(language)
                if showLoadingOverlay { overlay.hide(afterDelay: 0) }
            }
            settings.restoreVocabularyModeAfterAutoSwitchIfPending()

        case .fullApply:
            guard let mapping else { return }
            let profileName = mapping.engine == .parakeet
                ? (mapping.parakeetModel?.displayName ?? "model")
                : "Apple Speech"
            if showLoadingOverlay { overlay.show(state: .preparingModel(name: profileName)) }
            switch mapping.engine {
            case .parakeet:
                guard let model = mapping.parakeetModel else { break }
                let hadVocabularyMode = settings.transcriptPostProcessingMode == .fluidAudioVocabulary
                // Model before language: the model didSet coerces unsupported
                // languages back to English.
                settings.parakeetModelChoice = model
                settings.selectedLanguage = mapping.language
                await handleParakeetModelSelectionChange(userInitiated: true)
                settings.noteAutoSwitchModelChange(hadVocabularyMode: hadVocabularyMode)
                settings.restoreVocabularyModeAfterAutoSwitchIfPending()
            case .appleSpeech:
                // Pin the language before the engine switch so the one and only
                // prepare targets the gated, installed language (a stale
                // appleSpeechLanguage would otherwise download the wrong
                // assets). The explicit invalidate matters: a session prepared
                // earlier for a different language would satisfy the isReady
                // check in prepareActiveEngine and skip preparation entirely.
                // handleEngineSelectionChange only invalidates when switching
                // AWAY from Apple Speech, so it won't double-invalidate here,
                // and no second language-change call is needed — that was the
                // duplicate-preparation path.
                settings.appleSpeechLanguage = mapping.language
                await appleSpeechEngine.invalidatePreparedSession()
                await handleEngineSelectionChange(.appleSpeech)
            }
            if showLoadingOverlay { overlay.hide(afterDelay: 0) }
        }
    }

    // MARK: - Ollama Model Management

    func startOllamaModelDownload(_ model: String) async {
        guard ollamaDownloadState == nil, ollamaDeletingModel == nil else { return }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        ollamaModelActionError = nil
        ollamaDownloadState = OllamaDownloadState(
            model: trimmedModel,
            status: "Preparing model download...",
            fractionCompleted: nil,
            completed: nil,
            total: nil
        )

        do {
            for try await progress in OllamaPostProcessingService.pullModel(
                baseURL: settings.ollamaBaseURL,
                model: trimmedModel
            ) {
                guard !Task.isCancelled else { return }
                ollamaDownloadState = OllamaDownloadState(
                    model: trimmedModel,
                    status: progress.displayStatus,
                    fractionCompleted: progress.fractionCompleted,
                    completed: progress.overallCompleted ?? progress.completed,
                    total: progress.overallTotal ?? progress.total
                )
            }

            ollamaDownloadState = nil
            ollamaModelActionError = nil
            ollamaModelActionsRevision += 1
        } catch {
            guard !Task.isCancelled else { return }
            ollamaDownloadState = nil
            ollamaModelActionError = error.localizedDescription
        }
    }

    func deleteOllamaModel(_ model: String) async {
        guard ollamaDownloadState == nil, ollamaDeletingModel == nil else { return }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        ollamaDeletingModel = trimmedModel
        ollamaModelActionError = nil

        do {
            try await OllamaPostProcessingService.removeModel(
                baseURL: settings.ollamaBaseURL,
                model: trimmedModel
            )
            ollamaDeletingModel = nil
            ollamaModelActionError = nil
            ollamaModelActionsRevision += 1
        } catch {
            guard !Task.isCancelled else { return }
            ollamaDeletingModel = nil
            ollamaModelActionError = error.localizedDescription
        }
    }

    // MARK: - Dictation Flow

    func startDictation(mode: HotkeyMode? = nil) async {
        guard !isShuttingDown else { return }
        logger.info("startDictation: entry, status=\(String(describing: self.status), privacy: .public), isTransitioning=\(self.isTransitioning, privacy: .public), engineChoice=\(String(describing: self.settings.engineChoice), privacy: .public)")
        if case .error = status {
            status = .idle
        }
        guard status == .idle, !isTransitioning else { return }
        if !permissions.micGranted {
            let granted: Bool
            if let microphonePermissionRequester {
                granted = await microphonePermissionRequester()
            } else {
                granted = await permissions.requestMic()
            }

            guard granted else {
                status = .error("Microphone access is required to dictate. Enable it in System Settings, then try again.")
                return
            }

            permissions.micGranted = true
            return // The permission gesture must never become a recording gesture.
        }
        guard !isShuttingDown else { return }
        if settings.inputSourceAutoSwitchEnabled,
           let inputSourceID = inputSourceMonitor.currentInputSourceID() {
            // Backstop: the eager pre-warm usually already did this; going
            // through the queue serializes against an apply still in flight.
            await enqueueInputSourceProfileApply(for: inputSourceID, showLoadingOverlay: true).value
        }
        guard !isShuttingDown else { return }
        let engine = activeEngine
        switch settings.engineChoice {
        case .parakeet:
            if parakeetEngine.isDownloading {
                logger.warning("startDictation: selected model is still downloading")
                status = .error("\(settings.parakeetModelChoice.displayName) is still downloading. Try again when it finishes.")
                status = .idle
                return
            }

            if !(await parakeetEngine.refreshSelectedModelReadiness()) {
                await prepareActiveEngine()
            }

            guard await parakeetEngine.refreshSelectedModelReadiness(), engine.isReady else {
                logger.warning("startDictation: FluidAudio engine not ready, aborting")
                if settings.legacyAppleSpeechMigrationPending && !parakeetEngine.checkModelOnDisk() {
                    showLegacyAppleSpeechUnavailableAlert()
                }
                status = .error("\(settings.parakeetModelChoice.displayName) is not ready. Download it from Speech Model settings.")
                status = .idle
                return
            }
        case .appleSpeech:
            if !engine.isReady {
                await prepareActiveEngine()
            }
            guard engine.isReady else {
                logger.warning("startDictation: Apple Speech engine not ready, aborting")
                status = .error("Apple Speech is not ready. Open Speech Model settings to finish setup.")
                status = .idle
                return
            }
        }
        guard !isShuttingDown else { return }
        await captureInsertionTargetAppAndContext()
        guard !isShuttingDown else { return }
        await beginRecording(engine: engine, mode: mode)
    }

    private func beginRecording(engine: TranscriptionEngine, mode: HotkeyMode?) async {
        guard !isShuttingDown else { return }
        engine.setSessionContextualVocabulary(sessionDictationContext?.lexicalHints ?? [])

        isTransitioning = true
        pendingHoldRelease = false
        let recordingStartupID = UUID()
        activeRecordingStartupID = recordingStartupID
        sessionEngine = engine
        sessionHotkeyMode = mode
        configureEndOfUtteranceHandler(for: engine)

        completedRecognitionTranscript = nil
        isDeliveringTranscript = false
        prepareSessionRecovery(for: engine)
        if continuingEntryID != nil && recoveryCapture == nil {
            await discardSessionRecovery()
            clearEndOfUtteranceHandler(for: engine)
            engine.setSessionContextualVocabulary([])
            sessionEngine = nil
            sessionHotkeyMode = nil
            activeRecordingStartupID = nil
            insertionTargetApp = nil
            sessionDictationContext = nil
            isTransitioning = false
            status = .idle
            return
        }

        status = .recording
        currentTranscript = transcriptPrefix

        // Play start sound
        settings.playSound("Tink")

        // Resolve preferred input route up front; startup will retry with fallbacks if needed.
        let preferredDeviceID = MicrophoneHelper.effectiveDeviceID()
        let hasExplicitMicrophoneSelection = settings.selectedMicrophoneUID != nil

        // Boost mic volume if enabled
        if settings.boostMicrophoneVolumeEnabled {
            volumeController.boostMicrophoneVolume(deviceID: preferredDeviceID)
        }

        // Mute system audio if enabled
        if settings.muteSystemAudioDuringRecordingEnabled {
            volumeController.adjustForRecording()
        }

        // Start recording (must complete before showing overlay so the mic
        // is actually capturing audio when the user sees the "listening" UI)
        let startCandidates: [AudioDeviceID?] = {
            if hasExplicitMicrophoneSelection {
                return preferredDeviceID.map { [$0] } ?? []
            }
            var ids: [AudioDeviceID?] = [preferredDeviceID]
            let refreshedDefault = MicrophoneHelper.currentDefaultInputDeviceID()
            if refreshedDefault != preferredDeviceID {
                ids.append(refreshedDefault)
            }
            if !ids.contains(where: { $0 == nil }) {
                ids.append(nil)
            }
            return ids
        }()

        var lastStartError: Error? = hasExplicitMicrophoneSelection && preferredDeviceID == nil
            ? TranscriptionError.deviceSelectionFailed
            : nil
        var didStart = false
        for (index, candidateID) in startCandidates.enumerated() {
            guard !isShuttingDown, activeRecordingStartupID == recordingStartupID else { return }
            if index > 0 {
                logger.warning(
                    "startDictation: retrying startRecording attempt \(index + 1, privacy: .public) with deviceID=\(candidateID.map { String($0) } ?? "nil", privacy: .public)"
                )
                try? await Task.sleep(for: .milliseconds(220))
                guard !isShuttingDown, activeRecordingStartupID == recordingStartupID else { return }
            }

            do {
                try await engine.startRecording(deviceID: candidateID)
                guard !isShuttingDown, activeRecordingStartupID == recordingStartupID else { return }
                didStart = true
                logger.info(
                    "startDictation: startRecording succeeded on attempt \(index + 1, privacy: .public), deviceID=\(candidateID.map { String($0) } ?? "nil", privacy: .public)"
                )
                break
            } catch {
                guard !isShuttingDown, activeRecordingStartupID == recordingStartupID else { return }
                lastStartError = error
                logger.error(
                    "startDictation: startRecording attempt \(index + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard !isShuttingDown else { return }
        guard didStart else {
            let wasContinuing = continuingEntryID != nil
            await discardSessionRecovery()
            let message = lastStartError?.localizedDescription ?? "Unknown audio startup error"
            if wasContinuing {
                currentTranscript = ""
                recoveryStore.errorMessage = "Could not start the microphone. Your saved session is still available. \(message)"
            }
            status = .error("Failed to start recording: \(message)")
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 2.0)
            insertionTargetApp = nil
            sessionDictationContext = nil
            engine.setSessionContextualVocabulary([])
            volumeController.restoreMicrophoneVolume()
            if settings.muteSystemAudioDuringRecordingEnabled {
                volumeController.restoreAfterRecording()
            }
            isTransitioning = false
            pendingHoldRelease = false
            activeRecordingStartupID = nil
            clearEndOfUtteranceHandler(for: engine)
            sessionEngine = nil
            sessionHotkeyMode = nil
            status = .idle
            return
        }

        // Show overlay only after mic is confirmed active
        guard !isShuttingDown else { return }
        overlay.show(state: .listening(level: 0, transcript: currentTranscript))

        // Start audio level polling
        startAudioLevelPolling(engine: engine)

        activeRecordingStartupID = nil
        isTransitioning = false

        // If the user released a hold-to-record key while we were starting up, stop now.
        if pendingHoldRelease {
            pendingHoldRelease = false
            await stopDictation()
        }
    }

    func stopDictation() async {
        guard status == .recording, !isTransitioning else { return }
        isTransitioning = true
        status = .processing
        hotkeyService.resetCancellationGesture()
        let operationID = UUID()
        processingOperationID = operationID
        let task = Task { @MainActor in await self.finishDictation() }
        processingTask = task
        await task.value
        guard processingOperationID == operationID else { return }
        processingTask = nil
        processingOperationID = nil
        if !isCancelling { isTransitioning = false }
    }

    private func finishDictation() async {
        stopAudioLevelPolling()

        // Show processing overlay
        overlay.show(state: .processing)

        // Play stop sound
        settings.playSound("Pop")

        let engine = sessionEngine ?? activeEngine

        // Get final transcript
        let newTranscript = await engine.stopRecording()
        let transcript = CancelledDictation.joining(transcriptPrefix, newTranscript)
        // A cancelled decoder may return no new result. The restored prefix
        // alone must not mark the newest audio as already fully transcribed.
        completedRecognitionTranscript = newTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : transcript
        guard !Task.isCancelled else { return }
        engine.setSessionContextualVocabulary([])
        clearEndOfUtteranceHandler(for: engine)
        sessionHotkeyMode = nil

        // Apply filler word removal
        let cleaned = settings.removeFillerWords(from: transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let liveFallback = settings.removeFillerWords(from: currentTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = liveFallback.count > cleaned.count ? liveFallback : cleaned

        guard !finalText.isEmpty else {
            currentTranscript = ""
            volumeController.restoreMicrophoneVolume()
            // Restore recording audio state (brief pause lets BT audio routing settle)
            if settings.muteSystemAudioDuringRecordingEnabled {
                try? await Task.sleep(for: .milliseconds(200))
                volumeController.restoreAfterRecording()
            }
            guard !Task.isCancelled else { return }
            isDeliveringTranscript = true
            updateCancellationAvailability()
            await discardSessionRecovery(completed: true)
            sessionEngine = nil
            overlay.show(state: .success)
            overlay.hide(afterDelay: 0.5)
            status = .idle
            insertionTargetApp = nil
            sessionDictationContext = nil
            return
        }

        currentTranscript = finalText
        lastTranscript = finalText
        Self.lastTranscriptForMenuBar = finalText

        // Transcript post-processing
        var processedText = finalText
        logger.info(
            "postProcessing: mode=\(self.settings.transcriptPostProcessingMode.rawValue, privacy: .public), speechModel=\(self.settings.parakeetModelChoice.rawValue, privacy: .public), inputChars=\(finalText.count, privacy: .public)"
        )
        switch settings.transcriptPostProcessingMode {
        case .none:
            break
        case .fluidAudioVocabulary:
            if settings.parakeetModelChoice.usesTrueStreaming {
                logger.warning(
                    "postProcessing: FluidAudio Vocabulary is not available for true streaming model \(self.settings.parakeetModelChoice.rawValue, privacy: .public)"
                )
            }
        case .appleIntelligence:
            let context = postProcessingContext(for: .appleIntelligence)
            if !settings.aiPostProcessingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || context != nil {
                if #available(macOS 26, *) {
                    if case .available = AIPostProcessingService.availability {
                        do {
                            processedText = try await AIPostProcessingService.process(
                                text: finalText,
                                prompt: settings.aiPostProcessingPrompt,
                                vocabulary: settings.customVocabulary,
                                context: context
                            )
                        } catch {
                            logger.error("postProcessing: Apple Intelligence failed: \(error.localizedDescription, privacy: .public)")
                        }
                    } else {
                        logger.warning("postProcessing: Apple Intelligence is not available")
                    }
                }
            } else {
                logger.info("postProcessing: Apple Intelligence skipped because prompt is empty")
            }
        case .s1Mini:
            let activeLanguage = settings.engineChoice == .appleSpeech
                ? settings.appleSpeechLanguage
                : settings.selectedLanguage
            if activeLanguage != .english {
                logger.warning(
                    "postProcessing: S1-mini skipped because language is \(activeLanguage.rawValue, privacy: .public); S1-mini supports English only"
                )
            } else {
                do {
                    let modelURL = try await s1MiniModelManager.validatedModelURL()
                    let context = postProcessingContext(for: .s1Mini)
                    processedText = try await S1MiniPostProcessingService.process(
                        text: finalText,
                        modelURL: modelURL,
                        styling: settings.s1MiniStyling(for: context?.category),
                        structure: settings.s1MiniStructure,
                        contextSetting: settings.s1MiniContextSetting,
                        context: context
                    )
                } catch {
                    logger.error("postProcessing: S1-mini failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .ollama:
            do {
                let isLocalServer = OllamaPostProcessingService.isLocalServer(baseURL: settings.ollamaBaseURL)
                processedText = try await OllamaPostProcessingService.process(
                    text: finalText,
                    baseURL: settings.ollamaBaseURL,
                    model: settings.ollamaModel,
                    reasoning: settings.ollamaReasoningSetting,
                    prompt: settings.ollamaPostProcessingPrompt,
                    vocabulary: settings.customVocabulary,
                    context: postProcessingContext(
                        for: .ollama,
                        isConfiguredServerLocal: isLocalServer
                    )
                )
            } catch {
                logger.error("postProcessing: Ollama failed: \(error.localizedDescription, privacy: .public)")
            }
        case .openRouter:
            do {
                processedText = try await OpenRouterPostProcessingService.process(
                    text: finalText,
                    model: settings.openRouterModel,
                    prompt: settings.openRouterPostProcessingPrompt,
                    vocabulary: settings.customVocabulary,
                    apiKey: settings.openRouterAPIKey,
                    apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable,
                    context: postProcessingContext(for: .openRouter)
                )
            } catch {
                logger.error("postProcessing: OpenRouter failed: \(error.localizedDescription, privacy: .public)")
            }
        case .openAICompatible:
            do {
                let isLocalServer = OllamaPostProcessingService.isLocalServer(
                    baseURL: settings.openAICompatibleBaseURL
                )
                processedText = try await OpenAICompatiblePostProcessingService.process(
                    text: finalText,
                    baseURL: settings.openAICompatibleBaseURL,
                    model: settings.openAICompatibleModel,
                    apiKey: settings.openAICompatibleAPIKey,
                    prompt: settings.openAICompatiblePostProcessingPrompt,
                    vocabulary: settings.customVocabulary,
                    context: postProcessingContext(
                        for: .openAICompatible,
                        isConfiguredServerLocal: isLocalServer
                    )
                )
            } catch {
                logger.error("postProcessing: OpenAI Compatible failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard !Task.isCancelled else { return }
        if settings.transcriptPostProcessingMode != .none,
           settings.transcriptPostProcessingMode != .fluidAudioVocabulary {
            processedText = normalizePostProcessedTranscript(processedText)
        }
        logger.info(
            "postProcessing: completed changed=\(processedText != finalText, privacy: .public), outputChars=\(processedText.count, privacy: .public)"
        )

        guard !Task.isCancelled else { return }
        // Delivery is committed from this point; cancellation must never race a paste.
        isDeliveringTranscript = true
        updateCancellationAvailability()
        currentTranscript = processedText
        lastTranscript = processedText
        Self.lastTranscriptForMenuBar = processedText
        settings.addTranscriptHistoryEntry(processedText)

        // Insert text
        NotificationCenter.default.post(name: .dismissMenusForPaste, object: nil)
        await reactivateInsertionTargetIfNeeded()
        let insertionStyle = sessionDictationContext.map { settings.dictationWritingStyle(for: $0.category) }
        let result: TextInsertionResult
        if let transcriptDeliveryOverride {
            result = await transcriptDeliveryOverride(processedText)
        } else {
            // A continued session with no usable original destination must not
            // paste into History or an unrelated app that happens to be frontmost.
            let canPaste = continuingEntryID == nil || (insertionTargetApp != nil
                && insertionTargetApp?.isTerminated == false
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == insertionTargetApp?.processIdentifier)
            result = await textInserter.insertText(
                processedText, context: sessionDictationContext, style: insertionStyle,
                knownTerms: settings.customVocabulary, pasteAutomatically: canPaste
            )
        }
        insertionTargetApp = nil
        sessionDictationContext = nil

        // Restore mic volume and recording audio state after text insertion.
        // gives Bluetooth audio routing time to settle back to playback mode.
        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
            try? await Task.sleep(for: .milliseconds(200))
            volumeController.restoreAfterRecording()
        }

        switch result {
        case .success:
            overlay.show(state: .success)
        case .copiedOnly:
            overlay.show(state: .copiedOnly)
        case .failed:
            overlay.show(state: .copiedOnly)
        }

        overlay.hide(afterDelay: 1.0)
        await discardSessionRecovery(completed: true)
        sessionEngine = nil
        status = .idle
    }

    func cancelDictation() async {
        guard canCancelDictation else { return }

        isCancelling = true
        updateCancellationAvailability()
        let preview = currentTranscript
        processingTask?.cancel()

        activeRecordingStartupID = nil
        isTransitioning = true
        pendingHoldRelease = false
        isHoldToRecordKeyDown = false
        stopAudioLevelPolling()
        overlay.hide(afterDelay: 0)

        let engine = sessionEngine ?? activeEngine
        // Let a cancelled finish/cleanup unwind before reusing the same engine.
        // The task checks cancellation before saving or delivering its result.
        await processingTask?.value
        processingOperationID = nil
        processingTask = nil
        await engine.cancel()
        if let capture = recoveryCapture {
            do {
                let saved = try await recoveryStore.preserve(
                    capture, preview: preview, completedTranscript: completedRecognitionTranscript,
                    transcriptPrefix: transcriptPrefix.isEmpty ? nil : transcriptPrefix,
                    previousDuration: previousRecordingDuration,
                    targetBundleIdentifier: insertionTargetApp?.bundleIdentifier ?? continuationTargetBundleIdentifier
                )
                finishContinuation(removingSource: saved != nil && saved?.captureError == nil)
            } catch { recoveryStore.errorMessage = "The recovery copy could not be saved: \(error.localizedDescription)" }
        }
        finishContinuation(removingSource: false)
        recoveryCapture = nil
        engine.recoveryCapture = nil
        completedRecognitionTranscript = nil
        engine.setSessionContextualVocabulary([])
        clearEndOfUtteranceHandler(for: engine)
        sessionEngine = nil
        sessionHotkeyMode = nil

        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
            try? await Task.sleep(for: .milliseconds(200))
            volumeController.restoreAfterRecording()
        }

        currentTranscript = ""
        overlay.hide(afterDelay: 0)
        status = .idle
        insertionTargetApp = nil
        sessionDictationContext = nil
        isCancelling = false
        isTransitioning = false
        updateCancellationAvailability()
    }

    private func discardSessionRecovery(completed: Bool = false) async {
        if let capture = recoveryCapture {
            do { try await recoveryStore.discard(capture) }
            catch { recoveryStore.errorMessage = error.localizedDescription }
        }
        recoveryCapture = nil
        completedRecognitionTranscript = nil
        (sessionEngine ?? activeEngine).recoveryCapture = nil
        finishContinuation(removingSource: completed)
    }

    private func finishContinuation(removingSource: Bool) {
        if let id = continuingEntryID {
            recoveryStore.release(id: id)
            if removingSource {
                do { try recoveryStore.remove(id: id) }
                catch { recoveryStore.errorMessage = error.localizedDescription }
            }
        }
        continuingEntryID = nil
        transcriptPrefix = ""
        previousRecordingDuration = 0
        continuationTargetBundleIdentifier = nil
    }

    func prepareSessionRecovery(for engine: TranscriptionEngine) {
        // Continuing explicitly opts into retaining this existing session,
        // even if preservation has since been disabled for new dictations.
        if settings.preserveCancelledSessions || continuingEntryID != nil {
            do { recoveryCapture = try recoveryStore.beginCapture() }
            catch { recoveryStore.errorMessage = "Audio recovery is unavailable for this recording: \(error.localizedDescription)" }
        }
        engine.recoveryCapture = recoveryCapture
    }

    func recoverCancelledDictation(_ entry: CancelledDictation) async {
        guard status == .idle, !isTransitioning else { return }
        do {
            try recoveryStore.reload()
            guard recoveryStore.entries.contains(where: { $0.id == entry.id }) else { return }
            recoveringEntryID = entry.id
            recoveryStore.retain(id: entry.id)
            isTransitioning = true
            status = .processing
            defer {
                recoveringEntryID = nil
                recoveryStore.release(id: entry.id)
                isTransitioning = false
                status = .idle
            }
            let text = try await restoredTranscript(for: entry, engine: activeEngine)
            let cleaned = settings.removeFillerWords(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                recoveryStore.errorMessage = "No speech was recovered. The recording is still available; try a different speech model."
                return
            }
            settings.addTranscriptHistoryEntry(cleaned)
            lastTranscript = cleaned
            Self.lastTranscriptForMenuBar = cleaned
            recoveryStore.release(id: entry.id)
            try recoveryStore.remove(id: entry.id)
        } catch {
            recoveryStore.errorMessage = "Recovery failed. The saved session is still available. \(error.localizedDescription)"
        }
    }

    private func restoredTranscript(for entry: CancelledDictation, engine: TranscriptionEngine) async throws -> String {
        if let completed = entry.completedTranscript, !completed.isEmpty { return completed }
        if entry.hasAudio {
            if !engine.isReady { try await engine.prepare() }
            let text = try await engine.transcribeRecording(at: recoveryStore.audioURL(id: entry.id))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               entry.transcriptPrefix?.isEmpty == false {
                // The earlier words must not conceal a failed decode of the
                // newest audio and allow that audio to be replaced on cancel.
                throw NSError(domain: "DictationRecovery", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "No speech was recognized in the latest saved audio. It has been kept so you can try another speech model."])
            }
            return CancelledDictation.joining(entry.transcriptPrefix ?? "", text)
        }
        return entry.preview.isEmpty ? (entry.transcriptPrefix ?? "") : entry.preview
    }

    func continueCancelledDictation(_ entry: CancelledDictation) async {
        guard !isShuttingDown, status == .idle, !isTransitioning else { return }
        isTransitioning = true
        defer { if status != .recording { isTransitioning = false } }
        if !permissions.micGranted {
            let granted: Bool
            if let microphonePermissionRequester { granted = await microphonePermissionRequester() }
            else { granted = await permissions.requestMic() }
            permissions.micGranted = granted
            recoveryStore.errorMessage = granted
                ? "Microphone access is ready. Click Continue to resume your saved session."
                : "Microphone access is required to continue. Your saved session is still available."
            return
        }
        do {
            try recoveryStore.reload()
            guard let saved = recoveryStore.entries.first(where: { $0.id == entry.id }) else { return }
            recoveryStore.retain(id: saved.id)
            continuingEntryID = saved.id
            recoveringEntryID = saved.id
            status = .processing
            let engine = activeEngine
            if !engine.isReady { try await engine.prepare() }
            let restored = try await restoredTranscript(for: saved, engine: engine)
            try Task.checkCancellation()
            guard !isShuttingDown else { return }
            guard !restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "DictationRecovery", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "No speech was restored. Try Recover text with a different speech model."])
            }
            transcriptPrefix = restored
            previousRecordingDuration = saved.duration
            continuationTargetBundleIdentifier = saved.targetBundleIdentifier
            let target = saved.targetBundleIdentifier.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first { !$0.isTerminated }
            }
            await captureInsertionTargetAppAndContext(target: target, useFrontmost: false)
            await reactivateInsertionTargetIfNeeded()
            try Task.checkCancellation()
            guard !isShuttingDown else { return }
            recoveringEntryID = nil
            await beginRecording(engine: engine, mode: .handsFreeToggle)
        } catch {
            finishContinuation(removingSource: false)
            recoveringEntryID = nil
            insertionTargetApp = nil
            sessionDictationContext = nil
            status = .idle
            recoveryStore.errorMessage = "Could not continue. Your saved session is still available. \(error.localizedDescription)"
        }
    }

    // MARK: - Audio Level Polling

    private func captureInsertionTargetAppAndContext(target: NSRunningApplication? = nil, useFrontmost: Bool = true) async {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = useFrontmost ? NSWorkspace.shared.frontmostApplication : target,
              frontmost.processIdentifier != currentPID else {
            insertionTargetApp = nil
            sessionDictationContext = nil
            overlay.beginSession(targetProcessIdentifier: nil)
            return
        }
        insertionTargetApp = frontmost

        // The overlay follows the app the transcript will land in. Everything
        // after this point is awaited — context capture here, then audio
        // startup — and the user may bring another app forward while it runs,
        // so the display must be pinned to this app before any of it. It also
        // has to be pinned ahead of the guard below, which returns early for
        // most post-processing settings.
        overlay.beginSession(targetProcessIdentifier: frontmost.processIdentifier)

        // Only read the screen when a cleanup method exists that can use what
        // we read. `none` and FluidAudio Vocabulary never see the context.
        guard settings.dictationContextAwarenessEnabled,
              settings.transcriptPostProcessingMode.usesDictationContext else {
            sessionDictationContext = nil
            return
        }

        let processIdentifier = frontmost.processIdentifier
        let bundleIdentifier = frontmost.bundleIdentifier
        let appName = frontmost.localizedName ?? bundleIdentifier ?? "Unknown app"
        let rules = settings.dictationAppRules
        sessionDictationContext = await Task.detached(priority: .userInitiated) {
            DictationContextCapture.capture(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                rules: rules
            )
        }.value
    }

    private func postProcessingContext(includeCapturedText: Bool) -> DictationPostProcessingContext? {
        guard settings.dictationContextAwarenessEnabled,
              let context = sessionDictationContext else { return nil }
        return context.postProcessingContext(
            style: settings.dictationWritingStyle(for: context.category),
            includeCapturedText: includeCapturedText
        )
    }

    private func postProcessingContext(
        for mode: TranscriptPostProcessingMode,
        isConfiguredServerLocal: Bool = false
    ) -> DictationPostProcessingContext? {
        let support = mode.dictationContextSupport(
            isConfiguredServerLocal: isConfiguredServerLocal
        )
        return postProcessingContext(
            includeCapturedText: support.includesCapturedText(
                remoteSharingEnabled: settings.shareDictationContextWithRemoteProviders
            )
        )
    }

    private func reactivateInsertionTargetIfNeeded() async {
        guard let app = insertionTargetApp, !app.isTerminated else { return }
        if app.activate() {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func startAudioLevelPolling(engine: TranscriptionEngine) {
        audioLevelTask = Task { [weak self] in
            var displayTranscript = self?.transcriptPrefix ?? ""
            var transcriptPollTick = 0
            var lastTranscriptLength = 0
            while !Task.isCancelled {
                guard let self, self.status == .recording else { break }

                // Pull level samples from the lock-protected buffer (thread-safe)
                let samples = engine.levelSamples(count: 1600)
                self.audioMonitor.update(samples: samples)
                let level = self.audioMonitor.smoothedLevel
                transcriptPollTick += 1

                // Only copy transcript when it has actually changed
                if transcriptPollTick >= 6 {
                    transcriptPollTick = 0
                    let transcript = engine.currentTranscript
                    if transcript.count != lastTranscriptLength {
                        lastTranscriptLength = transcript.count
                        displayTranscript = CancelledDictation.joining(self.transcriptPrefix, transcript)
                        self.currentTranscript = displayTranscript
                    }
                }

                self.overlay.show(state: .listening(level: level, transcript: displayTranscript))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopAudioLevelPolling() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioMonitor.reset()
    }

    private func configureEndOfUtteranceHandler(for engine: TranscriptionEngine) {
        guard let parakeet = engine as? ParakeetEngine else { return }
        parakeet.endOfUtteranceHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.settings.autoStopAfterSpeechEndsEnabled else { return }
                guard self.settings.parakeetModelChoice.supportsEndOfUtterance else { return }
                guard self.sessionHotkeyMode == .handsFreeToggle else { return }
                guard self.status == .recording, !self.isTransitioning else { return }
                await self.stopDictation()
            }
        }
    }

    private func clearEndOfUtteranceHandler(for engine: TranscriptionEngine) {
        (engine as? ParakeetEngine)?.endOfUtteranceHandler = nil
    }

    private func showLegacyAppleSpeechUnavailableAlert() {
        guard !isShowingMigrationAlert else { return }
        isShowingMigrationAlert = true
        defer { isShowingMigrationAlert = false }

        let restorePolicy = settings.appAppearanceMode.activationPolicy
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            NSApp.setActivationPolicy(restorePolicy)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if AppleSpeechEngine.isOperatingSystemSupported {
            alert.messageText = "Apple Speech Isn’t Available on This Mac"
            alert.informativeText = """
            Dictate Anywhere has switched to FluidAudio. Download a FluidAudio speech model to \
            continue dictating.
            """
        } else {
            alert.messageText = "Apple Speech Requires macOS 26"
            alert.informativeText = """
            \(AppleSpeechEngine.operatingSystemDisplayName) does not support Apple Speech. Dictate \
            Anywhere has switched to FluidAudio. Download a FluidAudio speech model to continue dictating.
            """
        }
        alert.addButton(withTitle: "Open Speech Model")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        selectedPage = .models
        NotificationCenter.default.post(name: .requestShowMainWindow, object: nil)
    }
}

// MARK: - Audio Device Manager

@Observable
final class AudioDeviceManager {
    var availableInputDevices: [(uid: String, name: String)] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevices()
        installDeviceChangeListener()
    }

    deinit {
        removeDeviceChangeListener()
    }

    func refreshDevices() {
        availableInputDevices = Self.enumerateInputDevices()
    }

    // MARK: - Device Enumeration

    static func enumerateInputDevices() -> [(uid: String, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var result: [(uid: String, name: String)] = []
        for id in deviceIDs {
            guard isPhysicalDevice(deviceID: id),
                  hasInputChannels(deviceID: id),
                  let uid = deviceUID(for: id),
                  let name = deviceName(for: id) else { continue }
            result.append((uid: uid, name: name))
        }
        return result
    }

    private static func isPhysicalDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType) == noErr else {
            return false
        }
        // Block aggregate devices (e.g. CADefaultDeviceAggregate)
        if transportType == kAudioDeviceTransportTypeAggregate {
            return false
        }
        // Allow all non-virtual transports (built-in, USB, Bluetooth, etc.)
        if transportType != kAudioDeviceTransportTypeVirtual {
            return true
        }
        // Virtual transport: allow Continuity devices (iPhone/iPad), block the rest
        guard let name = deviceName(for: deviceID) else { return false }
        return name.contains("iPhone") || name.contains("iPad")
    }

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else {
            return false
        }
        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let result = uid?.takeUnretainedValue() else { return nil }
        return result as String
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let result = name?.takeUnretainedValue() else { return nil }
        return result as String
    }

    // MARK: - Device Change Listener

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshDevices()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        listenerBlock = nil
    }
}

// MARK: - Microphone Helper

enum MicrophoneHelper {
    static func effectiveDeviceID() -> AudioDeviceID? {
        guard let uid = Settings.shared.selectedMicrophoneUID else {
            return currentDefaultInputDeviceID()
        }
        return deviceID(forUID: uid)
    }

    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, &deviceUID) == noErr,
               let uidValue = deviceUID?.takeUnretainedValue(),
               (uidValue as String) == uid {
                return id
            }
        }
        return nil
    }
}
