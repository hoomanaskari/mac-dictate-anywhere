//
//  VolumeController.swift
//  Dictate Anywhere
//
//  Mute/unmute system audio during recording.
//

import Foundation
import CoreAudio

final class VolumeController {
    // MARK: - Saved State

    private var savedOutputMuteState: OutputMuteState?
    private var savedInputVolume: InputVolumeState?

    deinit {
        restoreMicrophoneVolume()
        restoreAfterRecording()
    }

    // MARK: - Public

    /// Saves current audio state and mutes system output for recording.
    func adjustForRecording() {
        guard savedOutputMuteState == nil else { return }

        guard let outputID = getDefaultOutputDeviceID() else { return }
        guard !shouldBypassMuteForCurrentRoute(outputDeviceID: outputID) else { return }

        savedOutputMuteState = muteOutputForRecording(deviceID: outputID)
    }

    /// Saves current mic volume and boosts it to 80% for recording.
    /// - Parameter deviceID: Specific device to boost; falls back to system default if nil.
    func boostMicrophoneVolume(deviceID: AudioDeviceID? = nil) {
        guard savedInputVolume == nil else { return }
        guard let inputID = deviceID ?? getDefaultInputDeviceID() else { return }
        guard let currentVolume = getVolume(deviceID: inputID, scope: kAudioDevicePropertyScopeInput) else { return }
        let targetVolume: Float32 = 0.8
        if currentVolume < targetVolume {
            if setVolume(deviceID: inputID, scope: kAudioDevicePropertyScopeInput, volume: targetVolume) {
                savedInputVolume = InputVolumeState(deviceID: inputID, previousVolume: currentVolume)
            }
        }
    }

    /// Restores mic volume to its previous level.
    func restoreMicrophoneVolume() {
        guard let state = savedInputVolume else { return }
        if let currentInputID = getDefaultInputDeviceID(), currentInputID == state.deviceID {
            _ = setVolume(deviceID: state.deviceID, scope: kAudioDevicePropertyScopeInput, volume: state.previousVolume)
        }
        savedInputVolume = nil
    }

    /// Restores saved audio state after recording.
    func restoreAfterRecording() {
        if let outputMuteState = savedOutputMuteState {
            restoreOutputMute(state: outputMuteState)
        }

        savedOutputMuteState = nil
    }

    // MARK: - Output Adjustments

    private func muteOutputForRecording(deviceID: AudioDeviceID) -> OutputMuteState? {
        let uid = getDeviceUID(deviceID: deviceID)
        let candidates = [kAudioObjectPropertyElementMain] + getChannelElements(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )

        for element in candidates {
            guard let isMuted = getMute(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            ) else {
                continue
            }

            if isMuted {
                return OutputMuteState(
                    deviceID: deviceID,
                    deviceUID: uid,
                    element: element,
                    wasMuted: true,
                    didMuteForRecording: false
                )
            }

            if setMute(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput,
                element: element,
                muted: true
            ) {
                return OutputMuteState(
                    deviceID: deviceID,
                    deviceUID: uid,
                    element: element,
                    wasMuted: false,
                    didMuteForRecording: true
                )
            }
        }

        return nil
    }

    private func restoreOutputMute(state: OutputMuteState) {
        guard state.didMuteForRecording, !state.wasMuted else { return }
        let targetDeviceID = state.deviceUID.flatMap(deviceID(forUID:)) ?? state.deviceID
        if unmuteIfNeeded(
            deviceID: targetDeviceID,
            scope: kAudioDevicePropertyScopeOutput,
            element: state.element
        ) {
            return
        }

        _ = unmuteAcrossAllOutputElements(deviceID: targetDeviceID)
    }

    // MARK: - CoreAudio Helpers

    private struct InputVolumeState {
        let deviceID: AudioDeviceID
        let previousVolume: Float32
    }

    private struct OutputMuteState {
        let deviceID: AudioDeviceID
        let deviceUID: String?
        let element: AudioObjectPropertyElement
        let wasMuted: Bool
        let didMuteForRecording: Bool
    }

    private func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
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

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
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
            if getDeviceUID(deviceID: id) == uid {
                return id
            }
        }
        return nil
    }

    private func shouldBypassMuteForCurrentRoute(outputDeviceID: AudioDeviceID) -> Bool {
        if isHeadphoneLikeDevice(deviceID: outputDeviceID) {
            return true
        }

        if let inputID = getDefaultInputDeviceID(), isHeadphoneLikeDevice(deviceID: inputID) {
            return true
        }

        return false
    }

    private func isHeadphoneLikeDevice(deviceID: AudioDeviceID) -> Bool {
        if isBluetoothDevice(deviceID: deviceID) {
            return true
        }

        guard let name = getDeviceName(deviceID: deviceID)?.lowercased() else { return false }
        let headphoneTokens = ["airpods", "headphone", "headset", "earbud", "beats"]
        return headphoneTokens.contains { name.contains($0) }
    }

    private func isBluetoothDevice(deviceID: AudioDeviceID) -> Bool {
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
        return transportType == kAudioDeviceTransportTypeBluetooth
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
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

    private func getVolume(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    private func setVolume(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        volume: Float32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else { return false }
        var value = volume
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private func getMute(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }

        return value != 0
    }

    private func setMute(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        muted: Bool
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue else {
            return false
        }

        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        ) == noErr
    }

    private func getChannelElements(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return [] }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer) == noErr else {
            return []
        }

        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        var channelCount: UInt32 = 0
        for buffer in buffers {
            channelCount += buffer.mNumberChannels
        }

        guard channelCount > 0 else { return [] }
        return Array(1...channelCount)
    }

    private func unmuteIfNeeded(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        guard let isMuted = getMute(deviceID: deviceID, scope: scope, element: element) else {
            return false
        }

        guard isMuted else { return true }
        return setMute(deviceID: deviceID, scope: scope, element: element, muted: false)
    }

    private func unmuteAcrossAllOutputElements(deviceID: AudioDeviceID) -> Bool {
        let candidates = [kAudioObjectPropertyElementMain] + getChannelElements(
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )

        var didUnmute = false
        for element in candidates {
            guard let isMuted = getMute(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            ), isMuted else {
                continue
            }

            if setMute(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput,
                element: element,
                muted: false
            ) {
                didUnmute = true
            }
        }
        return didUnmute
    }

}
