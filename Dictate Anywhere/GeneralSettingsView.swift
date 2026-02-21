//
//  GeneralSettingsView.swift
//  Dictate Anywhere
//
//  General app settings: launch at login, appearance, language, sound.
//

import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        ScrollView {
            VStack(spacing: 24) {
                // App Behavior
                GroupBox("App Behavior") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Launch at Login", isOn: $settings.launchAtLogin)

                        Picker("App Appears In", selection: $settings.appAppearanceMode) {
                            ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }
                    .padding(8)
                }

                // Language
                GroupBox("Language") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Transcription Language", selection: $settings.selectedLanguage) {
                            ForEach(SupportedLanguage.allCases) { lang in
                                Text(lang.displayWithFlag).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Parakeet auto-detects language. This setting helps Apple Speech engine.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                }

                // Sound Effects
                GroupBox("Sound Effects") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Sound Effects", isOn: $settings.soundEffectsEnabled)

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
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
        .navigationTitle("General")
    }
}
