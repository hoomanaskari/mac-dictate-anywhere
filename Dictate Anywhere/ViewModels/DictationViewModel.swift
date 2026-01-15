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
    let transcriptionService = TranscriptionService()
    let keyboardMonitor = KeyboardMonitorService()
    let microphoneManager = MicrophoneManager()
    let modelManager = ModelManager()

    // Services for auto-insert and overlay
    let audioLevelMonitor = AudioLevelMonitor()
    let textInsertionService = TextInsertionService.shared
    let overlayController = OverlayWindowController.shared

    // MARK: - Private

    private var setupTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        setupKeyboardCallbacks()
    }

    deinit {
        setupTask?.cancel()
        audioLevelTask?.cancel()
        keyboardMonitor.stopMonitoring()
    }

    // MARK: - Setup

    /// Sets up keyboard monitoring callbacks
    private func setupKeyboardCallbacks() {
        keyboardMonitor.onFnKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.startDictation()
            }
        }

        keyboardMonitor.onFnKeyUp = { [weak self] in
            Task { @MainActor in
                await self?.stopDictation()
            }
        }
    }

    /// Initializes the app: checks permissions, downloads model, initializes WhisperKit
    func initialize() {
        setupTask?.cancel()
        setupTask = Task { @MainActor in
            await performSetup()
        }
    }

    private func performSetup() async {
        // Stay in .loading state while doing quick checks
        // This ensures user sees "Loading..." before any specific screen

        // Step 1: Check permissions (quick)
        permissionChecker.checkPermissions()

        // Step 2: Check if model exists on disk
        modelManager.checkModelStatus()

        // Now decide which screen to show based on checks

        // Step 3: If permissions missing, show permissions screen
        if !permissionChecker.allPermissionsGranted {
            state = .permissionsMissing
            return
        }

        // Step 4: If no model downloaded, show model settings screen
        if !modelManager.isModelDownloaded {
            state = .modelManagement
            return
        }

        // Step 5: Sync transcription service with the model
        transcriptionService.setModelVariant(WhisperModel.defaultModel.whisperKitVariant)
        transcriptionService.isModelDownloaded = true

        // Step 6: Initialize WhisperKit
        state = .initializingModel

        do {
            try await transcriptionService.initializeWhisperKit()
        } catch {
            state = .error("Failed to initialize: \(error.localizedDescription)")
            return
        }

        // Step 7: Start keyboard monitoring
        keyboardMonitor.startMonitoring()

        // Ready!
        state = .ready
    }

    // MARK: - Dictation Control

    /// Starts dictation (recording and live transcription)
    func startDictation() async {
        guard case .ready = state else { return }

        state = .listening
        currentTranscript = ""

        // Show overlay with loading state
        overlayController.show(state: .loading)

        // Start recording
        await transcriptionService.startRecording(deviceID: microphoneManager.selectedDeviceID)

        // Start audio level monitoring
        audioLevelMonitor.startMonitoring(samplesProvider: transcriptionService)

        // Update overlay to listening state with empty transcript
        overlayController.show(state: .listening(level: 0, transcript: ""))

        // Start combined audio level + transcript update loop for overlay (~30 FPS)
        audioLevelTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.transcriptionService.isRecording && !Task.isCancelled {
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

        state = .processing

        // Stop audio level monitoring
        audioLevelMonitor.stopMonitoring()
        audioLevelTask?.cancel()
        audioLevelTask = nil

        // Show processing state
        overlayController.show(state: .processing)

        // Get final transcript
        let finalTranscript = await transcriptionService.stopRecording()
        currentTranscript = finalTranscript

        // Insert text into focused input (uses clipboard + Cmd+V)
        if !finalTranscript.isEmpty {
            _ = await textInsertionService.insertText(finalTranscript)
        }

        // Show success state
        overlayController.show(state: .success)

        // Hide overlay after delay (0.5 seconds)
        overlayController.hide(afterDelay: 0.5)

        state = .ready
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

        // Sync transcription service with the model
        transcriptionService.setModelVariant(WhisperModel.defaultModel.whisperKitVariant)
        transcriptionService.isModelDownloaded = true

        do {
            try await transcriptionService.initializeWhisperKit()

            // Start keyboard monitoring if not already started
            keyboardMonitor.startMonitoring()

            state = .ready
        } catch {
            state = .error("Failed to initialize model: \(error.localizedDescription)")
        }
    }
}
