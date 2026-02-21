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

    var status: DictationStatus = .idle
    var currentTranscript = ""
    var lastTranscript = ""

    /// Static accessor for AppDelegate menu bar (avoids circular dependency)
    nonisolated(unsafe) static var lastTranscriptForMenuBar = ""

    // MARK: - Services

    let permissions = Permissions()
    let settings = Settings.shared
    let hotkeyService = HotkeyService()
    let audioMonitor = AudioMonitor()
    let volumeController = VolumeController()
    let textInserter = TextInserter()
    let overlay = OverlayWindow()
    let parakeetEngine = ParakeetEngine()
    private(set) var appleSpeechEngine: AppleSpeechEngine?

    /// Whether the app is transitioning between states (simple guard)
    private var isTransitioning = false

    /// Watchdog timer for stuck dictation sessions
    private var watchdogTask: Task<Void, Never>?
    private let watchdogTimeout: TimeInterval = 300

    /// Audio level polling loop
    private var audioLevelTask: Task<Void, Never>?

    /// App that was frontmost when dictation started (used as paste target)
    private var insertionTargetApp: NSRunningApplication?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppState"
    )

    // MARK: - Active Engine

    var activeEngine: TranscriptionEngine {
        switch settings.engineChoice {
        case .parakeet:
            return parakeetEngine
        case .appleSpeech:
            if appleSpeechEngine == nil {
                appleSpeechEngine = AppleSpeechEngine()
            }
            return appleSpeechEngine!
        }
    }

    // MARK: - Initialization

    init() {
        setupHotkeyCallbacks()
        setupEngineCallbacks()
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyService.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.settings.hotkeyMode {
                case .holdToRecord:
                    await self.startDictation()
                case .handsFreeToggle:
                    if self.status == .recording {
                        await self.stopDictation()
                    } else {
                        await self.startDictation()
                    }
                }
            }
        }

        hotkeyService.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settings.hotkeyMode == .holdToRecord && self.status == .recording {
                    await self.stopDictation()
                }
            }
        }

        hotkeyService.onEscape = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancelDictation()
            }
        }
    }

    private func setupEngineCallbacks() {
        parakeetEngine.onEndOfUtterance = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shouldAutoStopFromEndOfUtterance else { return }
                await self.stopDictation()
            }
        }
    }

    // MARK: - Dictation Flow

    func startDictation() async {
        guard status == .idle, !isTransitioning else { return }
        guard activeEngine.isReady else {
            status = .error("Engine not ready. Download or configure the speech model first.")
            return
        }
        captureInsertionTargetApp()

        isTransitioning = true
        defer { isTransitioning = false }

        status = .recording
        currentTranscript = ""

        // Play start sound
        settings.playSound("Tink")

        // Adjust volume if enabled
        if settings.autoVolumeEnabled {
            volumeController.adjustForRecording()
        }

        // Show overlay
        overlay.show(state: .listening(level: 0, transcript: ""))

        // Start watchdog
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.watchdogTimeout ?? 30))
            guard !Task.isCancelled else { return }
            await self?.cancelDictation()
        }

        // Configure EOU callback for Apple Speech engine
        if let apple = activeEngine as? AppleSpeechEngine {
            apple.onEndOfUtterance = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.shouldAutoStopFromEndOfUtterance else { return }
                    await self.stopDictation()
                }
            }
        }

        // Get device ID for recording
        let deviceID = MicrophoneHelper.effectiveDeviceID(settings: settings)

        // Start recording
        do {
            try await activeEngine.startRecording(deviceID: deviceID)
        } catch {
            status = .error("Failed to start recording: \(error.localizedDescription)")
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 2.0)
            watchdogTask?.cancel()
            insertionTargetApp = nil
            if settings.autoVolumeEnabled {
                volumeController.restoreAfterRecording()
            }
            return
        }

        // Start audio level polling
        startAudioLevelPolling()
    }

    func stopDictation() async {
        guard status == .recording, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        status = .processing
        watchdogTask?.cancel()
        stopAudioLevelPolling()

        // Show processing overlay
        overlay.show(state: .processing)

        // Play stop sound
        settings.playSound("Pop")

        // Get final transcript
        let engine = activeEngine
        let transcript = await engine.stopRecording()

        // Apply filler word removal
        let cleaned = settings.removeFillerWords(from: transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let liveFallback = settings.removeFillerWords(from: currentTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = cleaned.isEmpty ? liveFallback : cleaned

        // Restore volume
        if settings.autoVolumeEnabled {
            volumeController.restoreAfterRecording()
        }

        guard !finalText.isEmpty else {
            currentTranscript = ""
            overlay.show(state: .success)
            overlay.hide(afterDelay: 0.5)
            status = .idle
            insertionTargetApp = nil
            return
        }

        currentTranscript = finalText
        lastTranscript = finalText
        Self.lastTranscriptForMenuBar = finalText

        // Insert text
        NotificationCenter.default.post(name: .dismissMenusForPaste, object: nil)
        await reactivateInsertionTargetIfNeeded()
        let result = await textInserter.insertText(finalText)
        insertionTargetApp = nil

        switch result {
        case .success:
            overlay.show(state: .success)
        case .copiedOnly:
            overlay.show(state: .copiedOnly)
        case .failed:
            overlay.show(state: .copiedOnly)
        }

        overlay.hide(afterDelay: 1.0)
        status = .idle
    }

    func cancelDictation() async {
        guard status == .recording || status == .processing else { return }

        watchdogTask?.cancel()
        stopAudioLevelPolling()

        await activeEngine.cancel()

        if settings.autoVolumeEnabled {
            volumeController.restoreAfterRecording()
        }

        currentTranscript = ""
        overlay.hide(afterDelay: 0)
        status = .idle
        insertionTargetApp = nil
    }

    // MARK: - Audio Level Polling

    private var shouldAutoStopFromEndOfUtterance: Bool {
        settings.isAutoStopEnabled &&
        settings.hotkeyMode == .handsFreeToggle &&
        status == .recording
    }

    private func captureInsertionTargetApp() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != currentPID else {
            insertionTargetApp = nil
            return
        }
        insertionTargetApp = frontmost
    }

    private func reactivateInsertionTargetIfNeeded() async {
        guard let app = insertionTargetApp, !app.isTerminated else { return }
        if app.activate() {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func startAudioLevelPolling() {
        audioLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.status == .recording else { break }
                let samples = self.activeEngine.audioSamples
                self.audioMonitor.update(samples: samples)
                let level = self.audioMonitor.smoothedLevel
                let transcript = self.activeEngine.currentTranscript
                self.currentTranscript = transcript
                self.overlay.show(state: .listening(level: level, transcript: transcript))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopAudioLevelPolling() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioMonitor.reset()
    }
}

// MARK: - Microphone Helper

enum MicrophoneHelper {
    static func effectiveDeviceID(settings: Settings) -> AudioDeviceID? {
        if settings.useSystemDefaultMicrophone {
            return currentDefaultInputDeviceID()
        }
        // For manual selection we'd look up by UID - for now use default
        return currentDefaultInputDeviceID()
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
}
