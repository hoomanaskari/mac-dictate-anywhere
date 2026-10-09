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
                subtitle: "How Dictate Anywhere starts, looks, sounds, and listens."
            )

            DSSection(overline: "Startup") {
                DSInfoRow(label: "Launch at login") {
                    DSSwitch(accessibilityName: "Launch at login", isOn: $settings.launchAtLogin)
                }
                if let error = settings.launchAtLoginError {
                    DSFieldMessage(text: error, tone: .error)
                        .padding(.horizontal, DS.Spacing.rowHorizontal)
                        .padding(.bottom, 10)
                }
                DSDivider()
                DSInfoRow(label: "App appears in") {
                    DSDropdown(
                        selection: $settings.appAppearanceMode,
                        options: AppAppearanceMode.allCases,
                        title: \.displayName,
                        accessibilityName: "App appearance"
                    )
                }
                DSDivider()
                DSDetailRow(
                    label: "Prepare models ahead of time",
                    caption: "Warm selected models at launch and when cleanup is enabled. Uses more memory to avoid first-use loading."
                ) {
                    DSSwitch(accessibilityName: "Prepare models ahead of time", isOn: $settings.prewarmEnginesAtStartup)
                }
            }

            DSSection(overline: "Display") {
                DSDetailRow(
                    label: "Theme",
                    caption: "System follows your Mac's appearance setting."
                ) {
                    DSDropdown(
                        selection: $settings.themeMode,
                        options: ThemeMode.allCases,
                        title: \.displayName,
                        accessibilityName: "Theme"
                    )
                }
            }

            if settings.engineChoice != .assemblyAI {
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
                                title: \.displayWithFlag,
                                accessibilityName: "Transcription language"
                            )
                        }
                    } else if settings.engineChoice == .parakeet {
                        DSDetailRow(
                            label: "Expected language",
                            caption: "Choose the expected language, then a compatible model on the Speech Model page. " + parakeetModelChoice.languageSettingsFooter
                        ) {
                            DSDropdown(
                                selection: $settings.selectedLanguage,
                                options: ParakeetModelChoice.catalogLanguageOptions(
                                    preserving: settings.selectedLanguage,
                                    hasNeuralEngine: Hardware.canUseAppleNeuralEngine),
                                title: \.displayWithFlag,
                                accessibilityName: "Expected speech language",
                                isEnabled: appState.status == .idle
                                    && !appState.isPreparingEngine
                                    && !appState.parakeetEngine.isDownloading
                            )
                        }
                        if let notice = parakeetModelChoice.languageSupportNotice(for: settings.selectedLanguage) {
                            DSFieldMessage(
                                text: notice + " Review your selection on the Speech Model page.",
                                tone: parakeetModelChoice.supportsLanguage(settings.selectedLanguage) ? .warning : .error
                            )
                            .padding(.horizontal, DS.Spacing.rowHorizontal)
                            .padding(.bottom, 10)
                        }
                    }
                }
            }

            if settings.engineChoice != .assemblyAI {
                InputSourceSettingsSection()
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
                                .first { $0.uid == uid }?.name ?? "Selected microphone unavailable"
                        },
                        accessibilityName: "Microphone"
                    )
                }
                if let uid = settings.selectedMicrophoneUID,
                   !appState.audioDeviceManager.availableInputDevices.contains(where: { $0.uid == uid }) {
                    DSFieldMessage(
                        text: "The selected microphone is disconnected or unavailable. Reconnect it, choose another microphone, or select System Default.",
                        tone: .warning
                    )
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
                }
                DSDivider()
                DSInfoRow(label: "Boost microphone volume during recording") {
                    DSSwitch(accessibilityName: "Boost microphone volume during recording", isOn: $settings.boostMicrophoneVolumeEnabled)
                }
                DSDivider()
                DSInfoRow(label: "Mute system audio during recording") {
                    DSSwitch(accessibilityName: "Mute system audio during recording", isOn: $settings.muteSystemAudioDuringRecordingEnabled)
                }
                DSDivider()
                DSInfoRow(label: "Sound effects") {
                    DSSwitch(accessibilityName: "Sound effects", isOn: $settings.soundEffectsEnabled)
                }
                if settings.soundEffectsEnabled {
                    DSDivider()
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .accessibilityHidden(true)
                        DSSlider(value: Binding(
                            get: { Double(settings.soundEffectsVolume) },
                            set: { settings.soundEffectsVolume = Float($0) }
                        ), label: "Sound effects volume")
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                }
            }

            DSHint(text: "Boosting raises low mic input, and muting keeps system audio out of your dictation.")
        }
        .task(id: appState.cleanupPreparationKey) {
            await appState.prepareCleanupEngineIfNeeded()
        }
        .onChange(of: settings.prewarmEnginesAtStartup) { _, enabled in
            if enabled {
                Task { await appState.prepareActiveEngine() }
            }
        }
    }
}
