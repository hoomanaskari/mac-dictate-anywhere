//
//  VolumeController.swift
//  Dictate Anywhere
//
//  Auto mic/system volume adjustment during recording.
//

import Foundation
import CoreAudio

final class VolumeController {
    // MARK: - Saved State

    private var savedMicVolume: Float?
    private var savedSystemVolume: Float?
    private var savedDeviceID: AudioDeviceID?

    /// Target mic volume when auto-adjusting
    private let targetMicVolume: Float = 0.80
    /// Target system audio volume during recording
    private let targetSystemVolume: Float = 0.05
    /// Minimum mic volume before we raise it
    private let minMicVolume: Float = 0.25

    // MARK: - Public

    /// Saves current volumes and adjusts for recording
    func adjustForRecording() {
        // Get default input device
        guard let inputID = getDefaultInputDeviceID() else { return }
        savedDeviceID = inputID

        // Save and adjust mic volume if needed
        if let currentMicVol = getVolume(deviceID: inputID, scope: kAudioDevicePropertyScopeInput) {
            savedMicVolume = currentMicVol
            if currentMicVol < minMicVolume {
                setVolume(deviceID: inputID, scope: kAudioDevicePropertyScopeInput, volume: targetMicVolume)
            }
        }

        // Save and lower system output volume
        if let outputID = getDefaultOutputDeviceID() {
            if let currentVol = getVolume(deviceID: outputID, scope: kAudioDevicePropertyScopeOutput) {
                savedSystemVolume = currentVol
                setVolume(deviceID: outputID, scope: kAudioDevicePropertyScopeOutput, volume: targetSystemVolume)
            }
        }
    }

    /// Restores saved volumes after recording
    func restoreAfterRecording() {
        // Restore mic volume
        if let deviceID = savedDeviceID, let vol = savedMicVolume {
            setVolume(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput, volume: vol)
        }

        // Restore system volume
        if let outputID = getDefaultOutputDeviceID(), let vol = savedSystemVolume {
            setVolume(deviceID: outputID, scope: kAudioDevicePropertyScopeOutput, volume: vol)
        }

        savedMicVolume = nil
        savedSystemVolume = nil
        savedDeviceID = nil
    }

    // MARK: - CoreAudio Helpers

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

    private func getVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        // Try main element first
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        // Try channel 1
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        return nil
    }

    private func setVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, volume: Float) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address) {
            var vol = volume
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            return
        }

        // Try channel 1
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address) {
            var vol = volume
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
    }
}
