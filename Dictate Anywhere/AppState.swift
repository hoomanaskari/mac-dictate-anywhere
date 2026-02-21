//
//  AppState.swift
//  Dictate Anywhere
//
//  Central observable state. Owns all services and orchestrates dictation flow.
//

import Foundation
import AppKit
import CoreAudio

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
    private(set) var appleSpeechEngine: AppleSpeechEngine?

    /// Whether the app is transitioning between states (simple guard)
    private var isTransitioning = false

    /// Audio level polling loop
    private var audioLevelTask: Task<Void, Never>?

    /// App that was frontmost when dictation started (used as paste target)
    private var insertionTargetApp: NSRunningApplication?

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

    // MARK: - Engine Lifecycle

    func prepareActiveEngine() async {
        if case .error = status { status = .idle }
        if !activeEngine.isReady {
            try? await activeEngine.prepare()
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

        // Show overlay
        overlay.show(state: .listening(level: 0, transcript: ""))

        // Start recording
        do {
            try await activeEngine.startRecording(deviceID: deviceID)
        } catch {
            status = .error("Failed to start recording: \(error.localizedDescription)")
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 2.0)
            insertionTargetApp = nil
            volumeController.restoreMicrophoneVolume()
            if settings.muteSystemAudioDuringRecordingEnabled {
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

        // Insert text
        NotificationCenter.default.post(name: .dismissMenusForPaste, object: nil)
        await reactivateInsertionTargetIfNeeded()
        let result = await textInserter.insertText(finalText)
        insertionTargetApp = nil

        // Restore mic volume and recording audio state after text insertion.
        // gives Bluetooth audio routing time to settle back to playback mode.
        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
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

        await activeEngine.cancel()

        volumeController.restoreMicrophoneVolume()
        if settings.muteSystemAudioDuringRecordingEnabled {
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

    private func startAudioLevelPolling() {
        audioLevelTask = Task { [weak self] in
            var displayTranscript = ""
            var transcriptPollTick = 0
            while !Task.isCancelled {
                guard let self, self.status == .recording else { break }
                let samples = self.activeEngine.audioSamples
                self.audioMonitor.update(samples: samples)
                let level = self.audioMonitor.smoothedLevel
                transcriptPollTick += 1

                // Reading/transferring huge transcript strings every frame is expensive on long sessions.
                if transcriptPollTick >= 6 {
                    transcriptPollTick = 0
                    displayTranscript = self.activeEngine.currentTranscript
                    self.currentTranscript = displayTranscript
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
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name as String
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
            var deviceUID: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, &deviceUID) == noErr,
               (deviceUID as String) == uid {
                return id
            }
        }
        return nil
    }
}
