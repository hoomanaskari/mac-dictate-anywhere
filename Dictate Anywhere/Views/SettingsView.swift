import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: DictationViewModel
    private let settings = SettingsManager.shared
    @State private var showLanguagePicker = false
    @State private var showCustomVocabularyDownloadConfirmation = false
    @State private var fillerWordsText: String = ""
    @State private var customVocabularyText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // App Behavior Section
                    appBehaviorSection

                    // Keyboard Shortcuts Section
                    keyboardShortcutsSection

                    // Language Section
                    languageSection

                    // Dictation Section (Auto-stop)
                    dictationSection

                    // ASR Accuracy Section
                    asrAccuracySection

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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        .alert("Download ASR Boost Model?", isPresented: $showCustomVocabularyDownloadConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Download & Enable") {
                settings.isCustomVocabularyEnabled = true
                Task {
                    await viewModel.prefetchVocabularyBoostModelsIfNeeded()
                    viewModel.scheduleAsrSettingsSync()
                }
            }
        } message: {
            Text("Custom Vocabulary needs an additional one-time download of about 130 MB.")
        }
        .frame(width: 500, height: 500)
        .appBackground()
    }

    // MARK: - App Behavior Section

    private var appBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("App Behavior")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
                .textCase(.uppercase)

            // Launch at Login Toggle
            settingsRow(
                icon: "power",
                title: "Launch at Login",
                description: "Open automatically when you sign in"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Divider()
                .background(AppTheme.divider)

            // App Appears In Picker
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "macwindow")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.textMediumEmphasis)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("App Appears In")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("Minimal footprint. Relaunch from Applications")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { settings.appAppearanceMode },
                    set: { settings.appAppearanceMode = $0 }
                )) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
            }

            Divider()
                .background(AppTheme.divider)

            // Help Improve Toggle
            settingsRow(
                icon: "chart.bar",
                title: "Help Improve",
                description: "Share anonymous usage data. No audio or text ever leaves your Mac"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.analyticsEnabled },
                    set: { settings.analyticsEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(16)
        .containerBackground()
    }

    // MARK: - Keyboard Shortcuts Section

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
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
                .background(AppTheme.divider)

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
        .containerBackground()
    }

    // MARK: - Language Section

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Language")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
                .textCase(.uppercase)

            // Language Picker Button
            Button(action: { showLanguagePicker = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.textMediumEmphasis)
                        .frame(width: 24)

                    HStack(spacing: 8) {
                        Text(settings.selectedLanguage.flag)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.selectedLanguage.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)

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
        .containerBackground()
    }

    // MARK: - Dictation Section

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Dictation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
                .textCase(.uppercase)

            // Hands-Free Mode Toggle
            settingsRow(
                icon: "hand.tap",
                title: "Hands-Free Mode",
                description: "Tap once to start, tap again or pause speaking to stop"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isHandsFreeEnabled },
                    set: { settings.isHandsFreeEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // Info tip when hands-free is enabled
            if settings.isHandsFreeEnabled {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)

                    Text("Press Escape to cancel without pasting")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                }
            }

            Divider()
                .background(AppTheme.divider)

            // Auto-Stop Toggle (always visible)
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
        .containerBackground()
    }

    // MARK: - Text Processing Section

    private var asrAccuracySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ASR Accuracy")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
                .textCase(.uppercase)

            settingsRow(
                icon: "waveform.badge.magnifyingglass",
                title: "Custom Vocabulary",
                description: "Improve recognition for names, acronyms, and domain terms"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isCustomVocabularyEnabled },
                    set: {
                        if $0 {
                            if viewModel.transcriptionService.isVocabularyBoostModelAvailable() {
                                settings.isCustomVocabularyEnabled = true
                                viewModel.scheduleAsrSettingsSync()
                            } else {
                                showCustomVocabularyDownloadConfirmation = true
                            }
                        } else {
                            settings.isCustomVocabularyEnabled = false
                            viewModel.scheduleAsrSettingsSync()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            if settings.isCustomVocabularyEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Terms to boost (comma or newline separated)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $customVocabularyText)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 72)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(AppTheme.buttonFill)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.border, lineWidth: 1)
                                }
                        }
                        .onAppear {
                            customVocabularyText = settings.customVocabularyTerms.joined(separator: ", ")
                        }
                        .onChange(of: customVocabularyText) { _, newValue in
                            settings.customVocabularyTerms = parseVocabularyTerms(newValue)
                            viewModel.scheduleAsrSettingsSync()
                        }

                    Text(customVocabularyHelperText)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textLowEmphasis)
                }
                .padding(.leading, 36)
            }

            if viewModel.transcriptionService.isVocabularyDownloadInProgress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading ASR boost model...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(viewModel.transcriptionService.vocabularyDownloadProgress * 100))%")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    ProgressView(value: viewModel.transcriptionService.vocabularyDownloadProgress)
                        .tint(AppTheme.textMediumEmphasis)
                }
                .padding(.leading, 36)
            }

            if let error = viewModel.transcriptionService.vocabularyDownloadErrorMessage, !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("Model download failed: \(error)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 36)
            }
        }
        .padding(16)
        .containerBackground()
    }

    private var textProcessingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Text Processing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
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

                    TextEditor(text: $fillerWordsText)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 60)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(AppTheme.buttonFill)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(AppTheme.border, lineWidth: 1)
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
                        .foregroundStyle(AppTheme.textLowEmphasis)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 36)
            }
        }
        .padding(16)
        .containerBackground()
    }

    // MARK: - Sound Effects Section

    private var soundEffectsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Sound Effects")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
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
                        .foregroundStyle(AppTheme.textSubtle)

                    Slider(
                        value: Binding(
                            get: { settings.soundEffectsVolume },
                            set: { settings.soundEffectsVolume = $0 }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(AppTheme.textMediumEmphasis)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSubtle)

                    Text("\(Int(settings.soundEffectsVolume * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.leading, 36)
            }
        }
        .padding(16)
        .containerBackground()
    }

    // MARK: - Overlay Section

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Overlay")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textLowEmphasis)
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
        .containerBackground()
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
                .foregroundStyle(AppTheme.textMediumEmphasis)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

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

    private func parseVocabularyTerms(_ input: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []

        let parts = input.split(whereSeparator: { $0 == "," || $0 == "\n" })
        for part in parts {
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            terms.append(trimmed)
        }

        return terms
    }

    private var customVocabularyHelperText: String {
        if viewModel.transcriptionService.isVocabularyDownloadInProgress {
            return "Downloading ASR boost model now. Keep this window open."
        }

        if let error = viewModel.transcriptionService.vocabularyDownloadErrorMessage, !error.isEmpty {
            return "Download failed. Toggle Custom Vocabulary off and on to retry."
        }

        if viewModel.transcriptionService.isVocabularyBoostModelAvailable() {
            return "ASR boost model is installed. Add terms to improve recognition."
        }

        return "A one-time ~130 MB ASR boost model will download after confirmation."
    }
}

#Preview {
    SettingsView(viewModel: DictationViewModel())
}
