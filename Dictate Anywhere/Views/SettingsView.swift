import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: DictationViewModel
    private let settings = SettingsManager.shared
    @State private var showLanguagePicker = false
    @State private var fillerWordsText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Keyboard Shortcuts Section
                    keyboardShortcutsSection

                    // Language Section
                    languageSection

                    // Dictation Section (Auto-stop)
                    dictationSection

                    // Text Processing Section (Filler word removal)
                    textProcessingSection

                    // Sound Effects Section
                    soundEffectsSection

                    // Overlay Section
                    overlaySection

                    Spacer(minLength: 20)
                }
                .padding(24)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: {
                        viewModel.hideSettings()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }
            }
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(selectedLanguage: Binding(
                get: { settings.selectedLanguage },
                set: {
                    settings.selectedLanguage = $0
                    viewModel.transcriptionService.setLanguage($0)
                }
            ))
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    // MARK: - Keyboard Shortcuts Section

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Fn Key Toggle
            settingsRow(
                icon: "globe",
                title: "Fn Key",
                description: "Use the Fn/Globe key to activate dictation"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isFnKeyEnabled },
                    set: { settings.isFnKeyEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Custom Shortcut Toggle
            settingsRow(
                icon: "command",
                title: "Custom Shortcut",
                description: "Set a custom keyboard shortcut for dictation"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isCustomShortcutEnabled },
                    set: { settings.isCustomShortcutEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // Shortcut Recorder (shown when custom shortcut is enabled)
            if settings.isCustomShortcutEnabled {
                HStack {
                    Spacer()
                        .frame(width: 32) // Align with content above

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shortcut")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        ShortcutRecorderView()
                    }
                }
                .padding(.leading, 8)
            }

            // Warning if both are disabled
            if !settings.isFnKeyEnabled && !settings.isCustomShortcutEnabled {
                warningBanner
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Language")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Language Picker Button
            Button(action: { showLanguagePicker = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24)

                    HStack(spacing: 8) {
                        Text(settings.selectedLanguage.flag)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.selectedLanguage.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)

                            Text(settings.selectedLanguage.nativeName)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Dictation Section

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Dictation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Auto-Stop Toggle
            settingsRow(
                icon: "stop.circle",
                title: "Auto-Stop",
                description: "Automatically stop when you pause speaking"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isAutoStopEnabled },
                    set: { settings.isAutoStopEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Text Processing Section

    private var textProcessingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Text Processing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Filler Word Removal Toggle
            settingsRow(
                icon: "text.badge.minus",
                title: "Remove Filler Words",
                description: "Filter out um, uh, erm, etc. from transcriptions"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isFillerWordRemovalEnabled },
                    set: { settings.isFillerWordRemovalEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // Filler Words Editor (shown when enabled)
            if settings.isFillerWordRemovalEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Words to remove (comma-separated)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("um, uh, erm, er, hmm", text: $fillerWordsText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.05))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                }
                        }
                        .onAppear {
                            fillerWordsText = settings.fillerWordsToRemove.joined(separator: ", ")
                        }
                        .onChange(of: fillerWordsText) { _, newValue in
                            // Parse comma-separated words and update settings
                            let words = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                .filter { !$0.isEmpty }
                            settings.fillerWordsToRemove = words
                        }

                    // Reset to defaults button
                    Button(action: {
                        settings.fillerWordsToRemove = SettingsManager.defaultFillerWords
                        fillerWordsText = settings.fillerWordsToRemove.joined(separator: ", ")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                            Text("Reset to Defaults")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 36)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Sound Effects Section

    private var soundEffectsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Sound Effects")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Sound Effects Toggle
            settingsRow(
                icon: "speaker.wave.2",
                title: "Sound Effects",
                description: "Play sounds when dictation starts and stops"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.soundEffectsEnabled },
                    set: { settings.soundEffectsEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // Volume Slider (shown when sound effects enabled)
            if settings.soundEffectsEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))

                    Slider(
                        value: Binding(
                            get: { settings.soundEffectsVolume },
                            set: { settings.soundEffectsVolume = $0 }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(.white.opacity(0.6))

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))

                    Text("\(Int(settings.soundEffectsVolume * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.leading, 36)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Overlay Section

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Overlay")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Show Text Preview Toggle
            settingsRow(
                icon: "text.bubble",
                title: "Show Text Preview",
                description: "Display live transcription text in the overlay"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.showTextPreview },
                    set: { settings.showTextPreview = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Settings Row

    private func settingsRow<Content: View>(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing()
        }
    }

    // MARK: - Warning Banner

    private var warningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)

            Text("No keyboard trigger is enabled. You won't be able to start dictation.")
                .font(.system(size: 12))
                .foregroundStyle(.orange.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                }
        }
    }
}

#Preview {
    SettingsView(viewModel: DictationViewModel())
}
