//
//  SettingsView.swift
//  Dictate Anywhere
//
//  General app settings: launch, language, audio.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            // MARK: - General

            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)

                Picker("App Appears In", selection: $settings.appAppearanceMode) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("General")
            }

            // MARK: - Language

            Section {
                Picker("Transcription Language", selection: $settings.selectedLanguage) {
                    ForEach(SupportedLanguage.allCases) { lang in
                        Text(lang.displayWithFlag).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Language")
            } footer: {
                Text("Parakeet auto-detects language for dictation.")
            }

            // MARK: - Audio

            Section {
                Picker("Microphone", selection: Binding<String?>(
                    get: { settings.selectedMicrophoneUID },
                    set: { settings.selectedMicrophoneUID = $0 }
                )) {
                    Text("System Default").tag(nil as String?)
                    ForEach(appState.audioDeviceManager.availableInputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Boost microphone volume during recording", isOn: $settings.boostMicrophoneVolumeEnabled)
                Toggle("Mute system audio during recording", isOn: $settings.muteSystemAudioDuringRecordingEnabled)

                Toggle("Sound Effects", isOn: $settings.soundEffectsEnabled)

                if settings.soundEffectsEnabled {
                    HStack {
                        Image(systemName: "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.soundEffectsVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Raises low mic input and mutes system audio during dictation.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
