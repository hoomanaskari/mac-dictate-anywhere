import Foundation
import SwiftUI
import AppKit
import CoreAudio
import os

// MARK: - Dictation Operation Actor

/// Actor to manage dictation operation state atomically and prevent race conditions
private actor DictationOperationManager {
    enum OperationState {
        case idle
        case starting
        case active
        case stopping
    }

    private var state: OperationState = .idle
    private var operationID: UInt64 = 0

    /// Attempts to start a new dictation operation. Returns operation ID if successful, nil if already in progress.
    func tryStart() -> UInt64? {
        guard state == .idle else { return nil }
        state = .starting
        operationID += 1
        return operationID
    }

    /// Marks the operation as fully active (recording started successfully)
    func setActive() {
        if state == .starting {
            state = .active
        }
    }

    /// Attempts to stop the current operation. Returns true if this call should handle the stop.
    func tryStop() -> Bool {
        guard state == .starting || state == .active else { return false }
        state = .stopping
        return true
    }

    /// Resets to idle state
    func reset() {
        state = .idle
    }

    /// Returns current state for checking
    func currentState() -> OperationState {
        return state
    }

    /// Checks if a given operation ID is still the current one
    func isCurrentOperation(_ id: UInt64) -> Bool {
        return operationID == id
    }

    /// Force reset for emergency recovery - always succeeds
    func forceReset() {
        state = .idle
    }
}

@Observable
final class DictationViewModel {
    // MARK: - State

    enum AppState: Equatable {
        case loading              // Initial loading while deciding what to show
        case checkingPermissions
        case permissionsMissing
        case downloadingModel
        case initializingModel
        case ready
        case listening
        case processing
        case modelManagement      // Model settings screen
        case settings             // Keyboard settings screen
        case error(String)

        var statusText: String {
            switch self {
            case .loading:
                return "Loading..."
            case .checkingPermissions:
                return "Checking permissions..."
            case .permissionsMissing:
                return "Permissions required"
            case .downloadingModel:
                return "Downloading model..."
            case .initializingModel:
                return "Initializing..."
            case .ready:
                return "Ready"
            case .listening:
                return "Listening..."
            case .processing:
                return "Processing..."
            case .modelManagement:
                return "Model Settings"
            case .settings:
                return "Settings"
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }

    var state: AppState = .loading
    var currentTranscript: String = ""

    /// Download progress - delegates to ModelManager for single source of truth
    var downloadProgress: Double {
        modelManager.downloadProgress
    }

    // MARK: - Services

    let permissionChecker = PermissionChecker()
    let transcriptionService = FluidTranscriptionService()
    let keyboardMonitor = KeyboardMonitorService()
    let microphoneManager = MicrophoneManager.shared
    let modelManager = FluidModelManager()
    let settings = SettingsManager.shared

    // Services for auto-insert and overlay
    let audioLevelMonitor = AudioLevelMonitor()
    let textInsertionService = TextInsertionService.shared
    let overlayController = OverlayWindowController.shared

    // MARK: - Private

    private var setupTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var windowCloseObserver: Any?

    /// Tracked task for hotkey-triggered dictation to prevent accumulation
    private var hotkeyTask: Task<Void, Never>?

    /// Tracks if the current dictation session is using hands-free mode
    private var isHandsFreeSession: Bool = false

    /// Actor-based lock to prevent concurrent start/stop operations causing race conditions
    private let operationManager = DictationOperationManager()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "DictationViewModel"
    )

    // MARK: - Low Volume Detection

    /// System microphone input volume threshold below which we show a warning (25%)
    private let systemVolumeWarningThreshold: Float = 0.25

    /// Tracks whether we're currently showing the low volume warning
    private var isShowingLowVolumeWarning = false

    /// Counter for periodic volume checks (every ~1 second at 30 FPS)
    private var volumeCheckCounter = 0
    private let volumeCheckInterval = 30  // Check every 30 frames (~1 second)

    // MARK: - Startup Recovery

    private struct StartupRouteAttempt {
        let label: String
        let deviceID: AudioDeviceID?
    }

    private let startupTotalBudgetSec: TimeInterval = 3.0
    private let attemptStartTimeoutSec: TimeInterval = 0.75
    private let attemptAudioReadyTimeoutSec: TimeInterval = 0.20
    private let interAttemptDelaySec: TimeInterval = 0.05
    private let startupErrorOverlayDurationSec: TimeInterval = 2.0
    private var startupErrorVisibleUntil: Date?

    // MARK: - Initialization

    init() {
        setupKeyboardCallbacks()
        setupNotificationObservers()
    }

    deinit {
        setupTask?.cancel()
        audioLevelTask?.cancel()
        hotkeyTask?.cancel()
        keyboardMonitor.stopMonitoring()
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Sets up observers for app notifications
    private func setupNotificationObservers() {
        // Window close observer
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: .mainWindowWillClose,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowClose()
        }
    }

    /// Handles window close - exits settings/modelManagement to allow dictation
    private func handleWindowClose() {
        switch state {
        case .settings:
            hideSettings()
        case .modelManagement:
            // Only exit if model is downloaded and ready
            if modelManager.isModelDownloaded {
                state = .ready
            }
        default:
            break
        }
    }

    // MARK: - Setup

    /// Sets up keyboard monitoring callbacks
    private func setupKeyboardCallbacks() {
        keyboardMonitor.onFnKeyDown = { [weak self] in
            guard let self = self else { return }

            // Cancel any pending hotkey task to prevent accumulation
            self.hotkeyTask?.cancel()

            self.hotkeyTask = Task { @MainActor [weak self] in
                guard let self = self, !Task.isCancelled else { return }

                // In hands-free mode, a second press while listening stops dictation
                if self.settings.isHandsFreeEnabled && self.state == .listening {
                    await self.stopDictation()
                } else if self.state == .ready {
                    await self.startDictation()
                }
            }
        }

        keyboardMonitor.onFnKeyUp = { [weak self] in
            guard let self = self else { return }

            // Cancel any pending hotkey task to prevent accumulation
            self.hotkeyTask?.cancel()

            self.hotkeyTask = Task { @MainActor [weak self] in
                guard let self = self, !Task.isCancelled else { return }

                // In hands-free mode, ignore key release during dictation
                if self.settings.isHandsFreeEnabled && self.state == .listening {
                    return
                }

                await self.stopDictation()

                // Ensure overlay is hidden if we're not actively transcribing
                // This handles edge cases where state gets out of sync
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self.ensureOverlayHiddenIfInactive()
            }
        }

        // Escape key callback for hands-free mode cancellation
        keyboardMonitor.onEscapeKeyPressed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !Task.isCancelled else { return }

                // Only handle Escape during hands-free dictation
                if self.isHandsFreeSession && self.state == .listening {
                    await self.cancelDictation()
                }
            }
        }
    }

    /// Initializes the app: checks permissions, downloads model, initializes FluidAudio
    func initialize() {
        setupTask?.cancel()
        setupTask = Task { @MainActor in
            await performSetup()
        }
    }

    private func performSetup() async {
        // Check permissions (runs off MainActor)
        await permissionChecker.checkPermissionsAsync()

        // If permissions missing, show permissions screen
        if !permissionChecker.allPermissionsGranted {
            state = .permissionsMissing
            return
        }

        // Check if model already exists on disk (runs off MainActor)
        let modelExistsOnDisk = await modelManager.checkModelExistsOnDisk()

        // Show appropriate state based on whether model needs downloading
        if modelExistsOnDisk {
            state = .initializingModel
        } else {
            state = .downloadingModel
        }

        do {
            let models = try await modelManager.downloadAndLoadModels()

            // Initialize FluidAudio
            if state != .initializingModel {
                state = .initializingModel
            }

            try await transcriptionService.initialize(with: models)

            // Sync language setting
            transcriptionService.setLanguage(settings.selectedLanguage)

        } catch {
            state = .error("Failed to initialize: \(error.localizedDescription)")
            return
        }

        // Start keyboard monitoring
        keyboardMonitor.startMonitoring()

        // Ready!
        state = .ready
    }

    // MARK: - Dictation Control

    /// Starts dictation (recording and live transcription)
    func startDictation() async {
        // Atomically acquire the operation lock via actor
        guard let operationID = await operationManager.tryStart() else {
            // Another operation is in progress - ignore this request
            return
        }

        // Check app state
        guard case .ready = state else {
            await operationManager.reset()
            return
        }

        // Track if this is a hands-free session
        isHandsFreeSession = settings.isHandsFreeEnabled
        startupErrorVisibleUntil = nil

        state = .listening
        currentTranscript = ""

        // Show overlay with loading state
        overlayController.show(state: .loading)

        // In hands-free mode, start Escape key monitoring for cancellation
        if isHandsFreeSession {
            keyboardMonitor.startEscapeMonitoring()
        }

        // Configure EOU callback for auto-stop if enabled
        // This works the same in both hold mode and hands-free mode
        if settings.isAutoStopEnabled {
            transcriptionService.onEndOfUtterance = { [weak self] in
                Task { @MainActor [weak self] in
                    guard !Task.isCancelled else { return }
                    await self?.handleEndOfUtterance()
                }
            }
        } else {
            transcriptionService.onEndOfUtterance = nil
        }

        let startupDeadline = Date().addingTimeInterval(startupTotalBudgetSec)
        let startupAttempts = buildStartupAttempts()
        var startupFailureReason = "Microphone unavailable."
        var startedSuccessfully = false

        for (index, attempt) in startupAttempts.enumerated() {
            guard await isCurrentStartupOperation(operationID) else {
                await transcriptionService.forceCancel()
                await operationManager.reset()
                return
            }

            let remainingBudget = startupDeadline.timeIntervalSinceNow
            guard remainingBudget > 0 else {
                startupFailureReason = "Microphone startup timed out."
                break
            }

            let startTimeout = min(attemptStartTimeoutSec, remainingBudget)
            let attemptStart = Date()
            let deviceID = attempt.deviceID.map(String.init) ?? "system-default"

            logger.debug(
                "Mic startup attempt \(index + 1, privacy: .public)/\(startupAttempts.count, privacy: .public) route=\(attempt.label, privacy: .public) device=\(deviceID, privacy: .public) timeout=\(startTimeout, privacy: .public)s"
            )

            let startOutcome = await transcriptionService.startRecording(
                deviceID: attempt.deviceID,
                startTimeout: startTimeout
            )

            guard await isCurrentStartupOperation(operationID) else {
                await transcriptionService.forceCancel()
                await operationManager.reset()
                return
            }

            let attemptElapsed = Date().timeIntervalSince(attemptStart)

            switch startOutcome {
            case .started:
                let remainingAfterStart = startupDeadline.timeIntervalSinceNow
                let audioReadyTimeout = min(
                    attemptAudioReadyTimeoutSec,
                    max(remainingAfterStart, 0)
                )
                let audioReady = audioReadyTimeout > 0
                    ? await transcriptionService.waitForAudioReady(timeout: audioReadyTimeout)
                    : false

                if audioReady {
                    logger.debug(
                        "Mic startup succeeded route=\(attempt.label, privacy: .public) elapsed=\(attemptElapsed, privacy: .public)s"
                    )
                    startedSuccessfully = true
                    break
                }

                startupFailureReason = "Microphone started but no audio signal was detected."
                logger.debug(
                    "Mic startup produced no audio route=\(attempt.label, privacy: .public) elapsed=\(attemptElapsed, privacy: .public)s"
                )
                await transcriptionService.forceCancel()

            case .timedOut:
                startupFailureReason = "Microphone startup timed out."
                logger.error(
                    "Mic startup timeout route=\(attempt.label, privacy: .public) elapsed=\(attemptElapsed, privacy: .public)s"
                )
                await transcriptionService.forceCancel()

            case .failed(let message):
                startupFailureReason = message
                logger.error(
                    "Mic startup failed route=\(attempt.label, privacy: .public) reason=\(message, privacy: .public) elapsed=\(attemptElapsed, privacy: .public)s"
                )
                await transcriptionService.forceCancel()
            }

            if startedSuccessfully {
                break
            }

            let remainingAfterAttempt = startupDeadline.timeIntervalSinceNow
            if remainingAfterAttempt <= 0 {
                break
            }

            if index < startupAttempts.count - 1 {
                let interAttemptDelay = min(interAttemptDelaySec, remainingAfterAttempt)
                let delayNanoseconds = UInt64(max(0, interAttemptDelay) * 1_000_000_000)
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
            }
        }

        guard await isCurrentStartupOperation(operationID) else {
            await transcriptionService.forceCancel()
            await operationManager.reset()
            return
        }

        guard startedSuccessfully else {
            await handleMicrophoneStartupFailure(reason: startupFailureReason)
            return
        }

        // Mark operation as fully active
        await operationManager.setActive()

        // Start audio level monitoring
        audioLevelMonitor.startMonitoring(samplesProvider: transcriptionService)

        // Play sound to indicate microphone is ready
        settings.playSound("Funk")

        // Update overlay to listening state - microphone is confirmed ready
        overlayController.show(state: .listening(level: 0, transcript: ""))

        // Reset low volume detection state
        isShowingLowVolumeWarning = false
        volumeCheckCounter = 0

        // Check system mic volume immediately on start
        checkAndUpdateLowVolumeWarning()

        // Start combined audio level + transcript update loop for overlay (~30 FPS)
        // This task will self-terminate when state changes from .listening
        audioLevelTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.state == .listening && !Task.isCancelled {
                let level = self.audioLevelMonitor.smoothedLevel
                let transcript = self.transcriptionService.currentTranscript
                self.currentTranscript = transcript

                // Periodically check system mic volume (every ~1 second)
                self.volumeCheckCounter += 1
                if self.volumeCheckCounter >= self.volumeCheckInterval {
                    self.volumeCheckCounter = 0
                    self.checkAndUpdateLowVolumeWarning()
                }

                // Show appropriate overlay state based on volume warning status
                if self.isShowingLowVolumeWarning {
                    self.overlayController.show(state: .listeningLowVolume(level: level))
                } else {
                    self.overlayController.show(state: .listening(level: level, transcript: transcript))
                }

                try? await Task.sleep(for: .milliseconds(33))
            }
        }

        // NOTE: We no longer block here waiting for recording to complete.
        // The stopDictation() method will handle stopping the recording when user releases the key.
        // This prevents MainActor starvation from the blocking while loop.
    }

    /// Stops dictation and inserts transcript into focused input (or clipboard)
    func stopDictation() async {
        guard case .listening = state else { return }

        // Atomically try to acquire stop lock via actor
        let canStop = await operationManager.tryStop()
        if !canStop {
            // Operation not in a stoppable state - might be starting or already stopping
            // Use force stop as fallback
            await forceStopDictation()
            return
        }

        // Update state
        state = .processing

        // Stop Escape monitoring if in hands-free mode
        if isHandsFreeSession {
            keyboardMonitor.stopEscapeMonitoring()
        }

        // Stop monitoring and cancel audio level task
        overlayController.hide()
        audioLevelMonitor.stopMonitoring()
        audioLevelTask?.cancel()
        audioLevelTask = nil

        // Show processing overlay
        overlayController.show(state: .processing)

        // Get final transcript (stopRecording handles the case where recording already stopped)
        // This runs the transcription on a background thread via the service
        let rawTranscript = await transcriptionService.stopRecording()

        // Apply filler word removal if enabled
        let finalTranscript = settings.removeFillerWords(from: rawTranscript)
        currentTranscript = finalTranscript

        // Store for menu bar access (even if empty, so user knows dictation happened)
        ClipboardManager.shared.lastTranscript = finalTranscript

        // Insert text into focused input (uses clipboard + Cmd+V)
        var insertionResult: TextInsertionResult = .failed
        if !finalTranscript.isEmpty {
            // Dismiss any open menus to ensure paste goes to correct app
            dismissMenus()
            try? await Task.sleep(for: .milliseconds(50))
            insertionResult = await textInsertionService.insertText(finalTranscript)
            // Play sound to indicate completion
            settings.playSound("Pop")
        }

        // Show appropriate state based on insertion result
        if insertionResult.didAutoPaste || finalTranscript.isEmpty {
            // Auto-paste succeeded or nothing to paste
            overlayController.show(state: .success)
            overlayController.hide(afterDelay: 0.5)
        } else if insertionResult.didCopyToClipboard {
            // Text copied but auto-paste failed - show hint to user
            overlayController.show(state: .copiedOnly)
            overlayController.hide(afterDelay: 1.5)  // Longer delay so user sees the message
        } else {
            // Complete failure
            overlayController.show(state: .success)
            overlayController.hide(afterDelay: 0.5)
        }

        // Reset hands-free session flag
        isHandsFreeSession = false

        // Reset the operation lock
        await operationManager.reset()

        state = .ready
    }

    /// Called when end-of-utterance is detected (user stopped speaking)
    private func handleEndOfUtterance() async {
        guard case .listening = state else { return }

        // Small delay to catch any trailing words
        try? await Task.sleep(for: .milliseconds(300))

        // Auto-stop dictation
        await stopDictation()
    }

    /// Cancels dictation without pasting text (used for Escape in hands-free mode)
    func cancelDictation() async {
        guard case .listening = state else { return }

        // Stop Escape monitoring
        keyboardMonitor.stopEscapeMonitoring()

        // Stop monitoring and cancel tasks
        overlayController.hide()
        audioLevelMonitor.stopMonitoring()
        audioLevelTask?.cancel()
        audioLevelTask = nil

        // Force cancel transcription (discards audio, no final transcription)
        await transcriptionService.forceCancel()

        // Reset hands-free session flag
        isHandsFreeSession = false

        // Force reset the operation lock
        await operationManager.forceReset()

        // Return to ready state - no text insertion, no success overlay
        state = .ready
    }

    /// Force stops dictation regardless of current state - used as emergency recovery
    func forceStopDictation() async {
        // Cancel all tasks
        audioLevelTask?.cancel()
        audioLevelTask = nil
        hotkeyTask?.cancel()
        hotkeyTask = nil

        // Stop Escape monitoring (in case hands-free mode was active)
        keyboardMonitor.stopEscapeMonitoring()

        // Stop all services
        audioLevelMonitor.stopMonitoring()
        await transcriptionService.forceCancel()

        // Hide overlay immediately
        overlayController.hide(afterDelay: 0)

        // Reset hands-free session flag
        isHandsFreeSession = false

        // Force reset the operation lock
        await operationManager.forceReset()

        // Reset to ready state (only if we were in a dictation-related state)
        switch state {
        case .listening, .processing:
            state = .ready
        default:
            break
        }
    }

    /// Ensures overlay is hidden when not in active dictation states
    /// Called after key release to guarantee cleanup
    private func ensureOverlayHiddenIfInactive() {
        if let visibleUntil = startupErrorVisibleUntil {
            if Date() < visibleUntil {
                return
            }
            startupErrorVisibleUntil = nil
        }

        switch state {
        case .listening, .processing:
            // Still active, don't hide
            break
        default:
            // Not in active dictation, ensure overlay is hidden
            overlayController.hide(afterDelay: 0)
        }
    }

    // MARK: - Permission Actions

    /// Requests microphone permission
    func requestMicrophonePermission() async {
        _ = await permissionChecker.requestMicrophonePermission()

        // Re-check and potentially continue setup
        if permissionChecker.allPermissionsGranted {
            await performSetup()
        }
    }

    /// Opens accessibility settings
    func openAccessibilitySettings() {
        // First trigger the system prompt
        permissionChecker.requestAccessibilityPermission()
        // Then open System Settings to the Accessibility pane
        permissionChecker.openAccessibilitySettings()
    }

    /// Rechecks permissions (useful after user grants them in System Settings)
    /// Waits for the async check to complete before evaluating the result
    func recheckPermissions() async {
        await permissionChecker.checkPermissionsAsync()

        if permissionChecker.allPermissionsGranted && state == .permissionsMissing {
            initialize()
        }
    }

    // MARK: - Model Management

    /// Navigates to the model settings screen
    func showModelManagement() {
        guard case .ready = state else { return }
        state = .modelManagement
    }

    /// Initializes the transcription service after model download
    /// Called after user downloads the model from ModelsView
    func initializeAfterDownload() async {
        state = .initializingModel

        do {
            // Get the loaded models from the model manager
            guard let models = modelManager.getLoadedModels() else {
                // If not loaded yet, download and load
                let loadedModels = try await modelManager.downloadAndLoadModels()
                try await transcriptionService.initialize(with: loadedModels)
                transcriptionService.setLanguage(settings.selectedLanguage)
                keyboardMonitor.startMonitoring()
                state = .ready
                return
            }

            try await transcriptionService.initialize(with: models)

            // Sync language setting
            transcriptionService.setLanguage(settings.selectedLanguage)

            // Start keyboard monitoring if not already started
            keyboardMonitor.startMonitoring()

            state = .ready
        } catch {
            state = .error("Failed to initialize model: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings

    /// Navigates to the settings screen
    func showSettings() {
        guard case .ready = state else { return }
        state = .settings
    }

    /// Returns from settings and restarts keyboard monitoring with new settings
    func hideSettings() {
        // Restart keyboard monitoring with potentially new settings
        keyboardMonitor.stopMonitoring()
        keyboardMonitor.startMonitoring()

        state = .ready
    }

    // MARK: - Helpers

    /// Dismisses any open menus to ensure paste goes to the correct app
    private func dismissMenus() {
        // Post notification for AppDelegate to dismiss its menu
        NotificationCenter.default.post(name: .dismissMenusForPaste, object: nil)
    }

    private func buildStartupAttempts() -> [StartupRouteAttempt] {
        var attempts: [StartupRouteAttempt] = []
        var seenKeys = Set<String>()

        func appendAttempt(label: String, deviceID: AudioDeviceID?) {
            let key = deviceID.map { "id:\($0)" } ?? "id:nil"
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            attempts.append(StartupRouteAttempt(label: label, deviceID: deviceID))
        }

        let configuredDevice = microphoneManager.effectiveDeviceID
        appendAttempt(
            label: "Configured (\(microphoneManager.microphoneName(for: configuredDevice)))",
            deviceID: configuredDevice
        )

        appendAttempt(
            label: "System Default (Implicit)",
            deviceID: nil
        )

        if let builtInDevice = microphoneManager.builtInInputDeviceID() {
            appendAttempt(
                label: "Built-In (\(microphoneManager.microphoneName(for: builtInDevice)))",
                deviceID: builtInDevice
            )
        }

        return attempts
    }

    private func isCurrentStartupOperation(_ operationID: UInt64) async -> Bool {
        guard await operationManager.isCurrentOperation(operationID) else { return false }
        guard case .listening = state else { return false }
        return true
    }

    private func handleMicrophoneStartupFailure(reason: String) async {
        logger.error("Microphone startup failed after retries: \(reason, privacy: .public)")

        await transcriptionService.forceCancel()
        audioLevelMonitor.stopMonitoring()
        audioLevelTask?.cancel()
        audioLevelTask = nil
        keyboardMonitor.stopEscapeMonitoring()

        isHandsFreeSession = false
        await operationManager.reset()
        state = .ready

        startupErrorVisibleUntil = Date().addingTimeInterval(startupErrorOverlayDurationSec)
        overlayController.show(state: .error(message: "Mic unavailable. Check Sound Input."))
        overlayController.hide(afterDelay: startupErrorOverlayDurationSec)
    }

    /// Checks system microphone volume and updates warning state
    /// Only shows warning if volume is below threshold and device supports volume control
    private func checkAndUpdateLowVolumeWarning() {
        // Get system microphone input volume
        guard let systemVolume = microphoneManager.getSelectedMicrophoneInputVolume() else {
            // Device doesn't support volume control (USB mics, etc.) - no warning needed
            isShowingLowVolumeWarning = false
            return
        }

        // Update warning state based on threshold
        isShowingLowVolumeWarning = systemVolume < systemVolumeWarningThreshold
    }
}
