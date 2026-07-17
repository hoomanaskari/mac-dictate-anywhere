//
//  SettingsView.swift
//  Dictate Anywhere
//
//  "General" page: launch, language, audio.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        let parakeetModelChoice = settings.parakeetModelChoice

        DSPage {
            DSSectionHeader(
                title: "General",
                subtitle: "How Dictate Anywhere starts, sounds, and listens."
            )

            DSSection(overline: "Startup") {
                DSInfoRow(label: "Launch at login") {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.dsSwitch)
                }
                DSDivider()
                DSInfoRow(label: "App appears in") {
                    DSDropdown(
                        selection: $settings.appAppearanceMode,
                        options: AppAppearanceMode.allCases,
                        title: \.displayName
                    )
                }
            }

            DSSection(overline: "Language") {
                if settings.engineChoice == .appleSpeech {
                    DSDetailRow(
                        label: "Transcription language",
                        caption: "Apple Speech downloads and uses the matching on-device language model."
                    ) {
                        DSDropdown(
                            selection: Binding(
                                get: { settings.appleSpeechLanguage },
                                set: { language in
                                    Task { await appState.handleAppleSpeechLanguageChange(language) }
                                }
                            ),
                            options: appState.appleSpeechSupportedLanguages.isEmpty
                                ? [settings.appleSpeechLanguage]
                                : appState.appleSpeechSupportedLanguages,
                            title: \.displayWithFlag
                        )
                    }
                } else {
                    DSDetailRow(
                        label: "Transcription language",
                        caption: parakeetModelChoice.languageSettingsFooter
                    ) {
                        if parakeetModelChoice.isEnglishOnly {
                            Text("English")
                                .font(DS.Fonts.ui(13.5))
                                .foregroundStyle(DS.Colors.textSecondary)
                        } else {
                            DSDropdown(
                                selection: $settings.selectedLanguage,
                                options: Array(SupportedLanguage.allCases),
                                title: \.displayWithFlag
                            )
                        }
                    }
                }
            }

            DSSection(overline: "Audio") {
                DSInfoRow(label: "Microphone") {
                    DSDropdown(
                        selection: Binding<String?>(
                            get: { settings.selectedMicrophoneUID },
                            set: { settings.selectedMicrophoneUID = $0 }
                        ),
                        options: [nil] + appState.audioDeviceManager.availableInputDevices.map { $0.uid },
                        title: { uid in
                            guard let uid else { return "System Default" }
                            return appState.audioDeviceManager.availableInputDevices
                                .first { $0.uid == uid }?.name ?? uid
                        }
                    )
                }
                DSDivider()
                DSInfoRow(label: "Boost microphone volume during recording") {
                    Toggle("", isOn: $settings.boostMicrophoneVolumeEnabled)
                        .labelsHidden()
                        .toggleStyle(.dsSwitch)
                }
                DSDivider()
                DSInfoRow(label: "Mute system audio during recording") {
                    Toggle("", isOn: $settings.muteSystemAudioDuringRecordingEnabled)
                        .labelsHidden()
                        .toggleStyle(.dsSwitch)
                }
                DSDivider()
                DSInfoRow(label: "Sound effects") {
                    Toggle("", isOn: $settings.soundEffectsEnabled)
                        .labelsHidden()
                        .toggleStyle(.dsSwitch)
                }
                if settings.soundEffectsEnabled {
                    DSDivider()
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textSecondary)
                        DSSlider(value: Binding(
                            get: { Double(settings.soundEffectsVolume) },
                            set: { settings.soundEffectsVolume = Float($0) }
                        ))
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                }
            }

            DSHint(text: "Boosting raises low mic input, and muting keeps system audio out of your dictation.")
        }
    }
}
