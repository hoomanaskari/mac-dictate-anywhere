import Foundation
import SwiftUI

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

    /// Tracks if the current dictation session is using hands-free mode
    private var isHandsFreeSession: Bool = false

    // MARK: - Initialization

    init() {
        setupKeyboardCallbacks()
        setupNotificationObservers()
    }

    deinit {
        setupTask?.cancel()
        audioLevelTask?.cancel()
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
            Task { @MainActor in
                guard let self = self else { return }

                // In hands-free mode, a second press while listening stops dictation
                if self.settings.isHandsFreeEnabled && self.state == .listening {
                    await self.stopDictation()
                } else if self.state == .ready {
                    await self.startDictation()
                }
            }
        }

        keyboardMonitor.onFnKeyUp = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }

                // In hands-free mode, ignore key release during dictation
                if self.settings.isHandsFreeEnabled && self.state == .listening {
                    return
                }

                await self.stopDictation()

                // Ensure overlay is hidden if we're not actively transcribing
                // This handles edge cases where state gets out of sync
                try? await Task.sleep(for: .milliseconds(100))
                self.ensureOverlayHiddenIfInactive()
            }
        }

        // Escape key callback for hands-free mode cancellation
        keyboardMonitor.onEscapeKeyPressed = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }

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
        // Check permissions
        permissionChecker.checkPermissions()

        // If permissions missing, show permissions screen
        if !permissionChecker.allPermissionsGranted {
            state = .permissionsMissing
            return
        }

        // Check if model already exists on disk
        let modelExistsOnDisk = modelManager.checkModelExistsOnDisk()

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
        guard case .ready = state else { return }

        // Track if this is a hands-free session
        isHandsFreeSession = settings.isHandsFreeEnabled

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
                Task { @MainActor in
                    await self?.handleEndOfUtterance()
                }
            }
        } else {
            transcriptionService.onEndOfUtterance = nil
        }

        // Start recording
        await transcriptionService.startRecording(deviceID: microphoneManager.selectedDeviceID)

        // Wait for microphone to actually start capturing audio
        let audioReady = await transcriptionService.waitForAudioReady(timeout: 2.0)

        // Check if user released FN key while we were waiting
        guard case .listening = state else { return }

        guard audioReady else {
            // Timeout waiting for audio - something may be wrong with the microphone
            await transcriptionService.forceCancel()
            overlayController.hide()
            state = .ready
            return
        }

        // Start audio level monitoring
        audioLevelMonitor.startMonitoring(samplesProvider: transcriptionService)

        // Play sound to indicate microphone is ready
        settings.playSound("Funk")

        // Update overlay to listening state - microphone is confirmed ready
        overlayController.show(state: .listening(level: 0, transcript: ""))

        // Start combined audio level + transcript update loop for overlay (~30 FPS)
        audioLevelTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.state == .listening && !Task.isCancelled {
                let level = self.audioLevelMonitor.smoothedLevel
                let transcript = self.transcriptionService.currentTranscript
                self.currentTranscript = transcript
                self.overlayController.show(state: .listening(level: level, transcript: transcript))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }

        // Wait for recording to complete
        while transcriptionService.isRecording {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Stops dictation and inserts transcript into focused input (or clipboard)
    func stopDictation() async {
        guard case .listening = state else { return }

        // IMMEDIATELY update state to prevent race with watchdog
        state = .processing

        // Stop Escape monitoring if in hands-free mode
        if isHandsFreeSession {
            keyboardMonitor.stopEscapeMonitoring()
        }

        // Stop monitoring and cancel watchdog task
        overlayController.hide()
        audioLevelMonitor.stopMonitoring()
        audioLevelTask?.cancel()
        audioLevelTask = nil

        // Show processing overlay
        overlayController.show(state: .processing)

        // Get final transcript (stopRecording handles the case where recording already stopped)
        let rawTranscript = await transcriptionService.stopRecording()

        // Apply filler word removal if enabled
        let finalTranscript = settings.removeFillerWords(from: rawTranscript)
        currentTranscript = finalTranscript

        // Store for menu bar access (even if empty, so user knows dictation happened)
        ClipboardManager.shared.lastTranscript = finalTranscript

        // Insert text into focused input (uses clipboard + Cmd+V)
        if !finalTranscript.isEmpty {
            // Dismiss any open menus to ensure paste goes to correct app
            dismissMenus()
            try? await Task.sleep(for: .milliseconds(50))
            _ = await textInsertionService.insertText(finalTranscript)
            // Play sound to indicate completion
            settings.playSound("Pop")
        }

        // Show success state
        overlayController.show(state: .success)

        // Hide overlay after delay (0.5 seconds)
        overlayController.hide(afterDelay: 0.5)

        // Reset hands-free session flag
        isHandsFreeSession = false

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

        // Return to ready state - no text insertion, no success overlay
        state = .ready
    }

    /// Force stops dictation regardless of current state - used as emergency recovery
    func forceStopDictation() async {
        // Cancel all tasks
        audioLevelTask?.cancel()
        audioLevelTask = nil

        // Stop all services
        audioLevelMonitor.stopMonitoring()
        await transcriptionService.forceCancel()

        // Hide overlay immediately
        overlayController.hide(afterDelay: 0)

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
    func recheckPermissions() {
        permissionChecker.checkPermissions()

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
}
