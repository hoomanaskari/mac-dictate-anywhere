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

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppState"
    )

    var status: DictationStatus = .idle
    var currentTranscript = ""
    var lastTranscript = ""
    var selectedPage: SidebarPage = .models

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
    let audioDeviceManager = AudioDeviceManager()
    let parakeetEngine = ParakeetEngine()
    private var isShowingMigrationAlert = false

    /// Whether the app is transitioning between states (simple guard)
    private var isTransitioning = false

    /// Set when a hold-to-record key-up arrives during a transition (race condition guard)
    private var pendingHoldRelease = false

    /// True while prepareActiveEngine is running (suppresses transient "not ready" warnings)
    var isPreparingEngine = false

    /// Audio level polling loop
    private var audioLevelTask: Task<Void, Never>?

    /// App that was frontmost when dictation started (used as paste target)
    private var insertionTargetApp: NSRunningApplication?

    /// Engine pinned for the active dictation session (start -> stop/cancel).
    private var sessionEngine: TranscriptionEngine?

    // MARK: - Active Engine

    var activeEngine: TranscriptionEngine {
        parakeetEngine
    }

    // MARK: - Initialization

    init() {
        setupHotkeyCallbacks()
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyService.onKeyDown = { [weak self] binding in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch binding.mode {
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

        hotkeyService.onKeyUp = { [weak self] binding in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard binding.mode == .holdToRecord else { return }
                if self.status == .recording, !self.isTransitioning {
                    await self.stopDictation()
                } else if self.isTransitioning {
                    // Key released while startDictation() is still running;
                    // startDictation will check this flag after its transition.
                    self.pendingHoldRelease = true
                }
            }
        }

        hotkeyService.onEscape = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.cancelDictation()
            }
        }
    }

    // MARK: - Engine Lifecycle

    func prepareActiveEngine() async {
        logger.info("prepareActiveEngine: called, engineChoice=\(String(describing: self.settings.engineChoice), privacy: .public), status=\(String(describing: self.status), privacy: .public)")
        if case .recording = status { return }
        if case .processing = status { return }
        if case .error = status { status = .idle }

        // Auto-default: if user hasn't explicitly chosen an engine and
        // Parakeet model is downloaded, ensure Parakeet is selected.
        await parakeetEngine.recheckModelOnDisk()
        let hasParakeetModel = parakeetEngine.checkModelOnDisk()
        if !settings.userHasChosenEngine, hasParakeetModel {
            settings.engineChoice = .parakeet
        }
        if hasParakeetModel {
            settings.legacyAppleSpeechMigrationPending = false
        }

        let ready = activeEngine.isReady
        logger.info("prepareActiveEngine: activeEngine.isReady=\(ready, privacy: .public), willCallPrepare=\(!ready, privacy: .public)")
        if !ready {
            // Set synchronously so the UI sees it before any await yields
            isPreparingEngine = true
            try? await activeEngine.prepare()
            logger.info("prepareActiveEngine: prepare() completed, isReady=\(self.activeEngine.isReady, privacy: .public)")
        }
        isPreparingEngine = false
    }

    // MARK: - Dictation Flow

    func startDictation() async {
        logger.info("startDictation: entry, status=\(String(describing: self.status), privacy: .public), isTransitioning=\(self.isTransitioning, privacy: .public), engineChoice=\(String(describing: self.settings.engineChoice), privacy: .public)")
        if case .error = status {
            status = .idle
        }
        guard status == .idle, !isTransitioning else { return }
        let engine = activeEngine
        guard engine.isReady else {
            logger.warning("startDictation: engine not ready, aborting")
            if settings.legacyAppleSpeechMigrationPending && !parakeetEngine.checkModelOnDisk() {
                showLegacyEngineDiscontinuedAlert()
            }
            status = .error("Parakeet model not ready. Download it from Speech Model settings.")
            status = .idle
            return
        }
        captureInsertionTargetApp()

        isTransitioning = true
        pendingHoldRelease = false
        sessionEngine = engine

        status = .recording
        currentTranscript = ""

        // Play start sound
        settings.playSound("Tink")

        // Get device ID for recording
        let deviceID = MicrophoneHelper.effectiveDeviceID()

        // Boost mic volume if enabled
        if settings.boostMicrophoneVolumeEnabled {
            volumeController.boostMicrophoneVolume(deviceID: deviceID)
        }

        // Mute system audio if enabled
        if settings.muteSystemAudioDuringRecordingEnabled {
            volumeController.adjustForRecording()
        }

        // Start recording (must complete before showing overlay so the mic
        // is actually capturing audio when the user sees the "listening" UI)
        do {
            try await engine.startRecording(deviceID: deviceID)
            logger.info("startDictation: startRecording succeeded")

            // Show overlay only after mic is confirmed active
            overlay.show(state: .listening(level: 0, transcript: ""))
        } catch {
            logger.error("startDictation: startRecording failed: \(error.localizedDescription, privacy: .public)")
            status = .error("Failed to start recording: \(error.localizedDescription)")
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 2.0)
            insertionTargetApp = nil
            volumeController.restoreMicrophoneVolume()
            if settings.muteSystemAudioDuringRecordingEnabled {
                volumeController.restoreAfterRecording()
            }
            isTransitioning = false
            pendingHoldRelease = false
            sessionEngine = nil
            status = .idle
            return
        }

        // Start audio level polling
        startAudioLevelPolling(engine: engine)

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
        defer { isTransitioning = false }

        status = .processing
        stopAudioLevelPolling()

        // Show processing overlay
        overlay.show(state: .processing)

        // Play stop sound
        settings.playSound("Pop")

        // Get final transcript
        let engine = sessionEngine ?? activeEngine
        let transcript = await engine.stopRecording()
        sessionEngine = nil

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
            overlay.show(state: .success)
            overlay.hide(afterDelay: 0.5)
            status = .idle
            insertionTargetApp = nil
            return
        }

        currentTranscript = finalText
        lastTranscript = finalText
        Self.lastTranscriptForMenuBar = finalText

        // AI Post Processing
        var processedText = finalText
        if settings.aiPostProcessingEnabled,
           !settings.aiPostProcessingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if #available(macOS 26, *) {
                if case .available = AIPostProcessingService.availability {
                    do {
                        processedText = try await AIPostProcessingService.process(
                            text: finalText,
                            prompt: settings.aiPostProcessingPrompt,
                            vocabulary: settings.effectiveCustomVocabulary
                        )
                        currentTranscript = processedText
                        lastTranscript = processedText
                        Self.lastTranscriptForMenuBar = processedText
                    } catch {
                        // Silently fall back to original text on failure
                    }
                }
            }
        }

        // Insert text
        NotificationCenter.default.post(name: .dismissMenusForPaste, object: nil)
        await reactivateInsertionTargetIfNeeded()
        let result = await textInserter.insertText(processedText)
        insertionTargetApp = nil

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
        status = .idle
    }

    func cancelDictation() async {
        guard status == .recording || status == .processing else { return }

        stopAudioLevelPolling()

        let engine = sessionEngine ?? activeEngine
        await engine.cancel()
        sessionEngine = nil

        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
            try? await Task.sleep(for: .milliseconds(200))
            volumeController.restoreAfterRecording()
        }

        currentTranscript = ""
        overlay.hide(afterDelay: 0)
        status = .idle
        insertionTargetApp = nil
    }

    // MARK: - Audio Level Polling

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

    private func startAudioLevelPolling(engine: TranscriptionEngine) {
        audioLevelTask = Task { [weak self] in
            var displayTranscript = ""
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
                        displayTranscript = transcript
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

    private func showLegacyEngineDiscontinuedAlert() {
        guard !isShowingMigrationAlert else { return }
        isShowingMigrationAlert = true
        defer { isShowingMigrationAlert = false }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apple Speech Has Been Discontinued"
        alert.informativeText = """
        Dictate Anywhere no longer supports Apple Speech due to inconsistent transcription quality. \
        Download the Parakeet model to continue dictating.
        """
        alert.addButton(withTitle: "Open Speech Model")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        selectedPage = .models
        if let window = NSApp.windows.first(where: {
            $0.contentView != nil && !($0.contentView is NSVisualEffectView && $0.level == .floating)
        }) {
            window.makeKeyAndOrderFront(nil)
        }
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
        return deviceID(forUID: uid) ?? currentDefaultInputDeviceID()
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
