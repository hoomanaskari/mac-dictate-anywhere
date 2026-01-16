import Foundation
import AVFoundation
import CoreAudio

@Observable
final class MicrophoneManager {
    // MARK: - Singleton

    static let shared = MicrophoneManager()

    // MARK: - Types

    struct Microphone: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool

        static func == (lhs: Microphone, rhs: Microphone) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    // MARK: - Properties

    var availableMicrophones: [Microphone] = []
    var selectedMicrophone: Microphone?

    /// Background queue for CoreAudio operations to avoid blocking MainActor
    private let audioQueue = DispatchQueue(label: "com.dictate-anywhere.microphone-manager", qos: .userInitiated)

    // MARK: - Initialization

    private init() {
        // Refresh microphones in background to avoid blocking MainActor on startup
        audioQueue.async { [weak self] in
            self?.refreshMicrophonesSync()
        }
        setupDeviceChangeListener()
    }

    // MARK: - Public Methods

    /// Refreshes the list of available microphones (runs CoreAudio queries off MainActor)
    func refreshMicrophones() {
        audioQueue.async { [weak self] in
            self?.refreshMicrophonesSync()
        }
    }

    /// Synchronous version for background queue use only
    private func refreshMicrophonesSync() {
        let devices = getInputDevices()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.availableMicrophones = devices

            // Select default microphone if none selected
            if self.selectedMicrophone == nil {
                self.selectedMicrophone = devices.first(where: { $0.isDefault })
                    ?? devices.first
            }

            // Verify selected microphone still exists
            if let selected = self.selectedMicrophone,
               !devices.contains(where: { $0.id == selected.id }) {
                self.selectedMicrophone = devices.first(where: { $0.isDefault })
                    ?? devices.first
            }
        }
    }

    /// Selects a microphone by ID
    func selectMicrophone(_ microphone: Microphone) {
        selectedMicrophone = microphone
    }

    /// Gets the device ID for the selected microphone (for use with audio capture)
    var selectedDeviceID: AudioDeviceID? {
        selectedMicrophone?.id
    }

    // MARK: - Private Methods

    private func getInputDevices() -> [Microphone] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        // Get default input device
        let defaultInputID = getDefaultInputDeviceID()

        // Filter to only physical input devices (exclude virtual/aggregate)
        var microphones: [Microphone] = []

        for deviceID in deviceIDs {
            if hasInputChannels(deviceID: deviceID),
               isPhysicalDevice(deviceID: deviceID),
               let name = getDeviceName(deviceID: deviceID) {
                let isDefault = deviceID == defaultInputID
                microphones.append(Microphone(id: deviceID, name: name, isDefault: isDefault))
            }
        }

        // Sort with default first, then alphabetically
        return microphones.sorted { mic1, mic2 in
            if mic1.isDefault != mic2.isDefault {
                return mic1.isDefault
            }
            return mic1.name < mic2.name
        }
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : 0
    }

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)

        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)

        guard status == noErr else { return false }

        let bufferList = bufferListPointer.pointee
        return bufferList.mNumberBuffers > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)

        guard status == noErr, let cfString = name?.takeRetainedValue() else {
            return nil
        }

        return cfString as String
    }

    /// Checks if device is a physical microphone (not virtual or aggregate)
    private func isPhysicalDevice(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportType)

        guard status == noErr else {
            // If we can't determine transport type, include the device
            return true
        }

        // Filter out virtual and aggregate devices
        // kAudioDeviceTransportTypeVirtual = 'virt' = 0x76697274
        // kAudioDeviceTransportTypeAggregate = 'grup' = 0x67727570
        let virtualType: UInt32 = 0x76697274  // 'virt'
        let aggregateType: UInt32 = 0x67727570  // 'grup'

        return transportType != virtualType && transportType != aggregateType
    }

    // MARK: - Device Change Listener

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        listenerBlock = { [weak self] _, _ in
            // Refresh in background queue (which will then update main)
            self?.refreshMicrophones()
        }

        if let block = listenerBlock {
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                block
            )
        }

        // Also listen for default device changes
        var defaultPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultPropertyAddress,
            DispatchQueue.main,
            listenerBlock!
        )
    }

    deinit {
        // Remove listeners
        if let block = listenerBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                block
            )
        }
    }
}
