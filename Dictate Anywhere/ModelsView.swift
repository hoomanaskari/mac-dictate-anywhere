//
//  ModelsView.swift
//  Dictate Anywhere
//
//  "Speech Model" page: download, delete, engine selector.
//

import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var appState

    @State private var modelPendingDeletion: ParakeetModelChoice?
    @State private var isDeletingModel = false
    @State private var modelActionError: String?

    var body: some View {
        @Bindable var settings = appState.settings
        let selectedModel = settings.parakeetModelChoice

        DSPage {
            DSSectionHeader(
                title: "Speech Model",
                subtitle: pageSubtitle(settings: settings)
            )

            DSSection(overline: "Active Engine") {
                DSDetailRow(label: "Engine", caption: settings.engineChoice.detail) {
                    DSDropdown(
                        selection: Binding(
                            get: { settings.engineChoice },
                            set: { newValue in
                                modelActionError = nil
                                if newValue == .appleSpeech, !AppleSpeechEngine.isSupported {
                                    appState.reportUnsupportedAppleSpeechSelection()
                                    return
                                }
                                Task { await appState.handleEngineSelectionChange(newValue) }
                            }
                        ),
                        options: appState.availableEngineChoices,
                        title: engineChoiceTitle,
                        accessibilityName: "Speech engine",
                        isEnabled: appState.status == .idle
                            && !appState.isPreparingEngine
                            && !appState.parakeetEngine.isDownloading
                            && !isDeletingModel
                    )
                }
            }

            if settings.engineChoice == .parakeet {
                DSSection(overline: "On-Device Speech") {
                    DSDetailRow(
                        label: "Expected language",
                        caption: "The model menu shows choices for this language and this Mac. Multilingual models can still recognize mixed speech."
                    ) {
                        DSDropdown(
                            selection: $settings.selectedLanguage,
                            options: expectedLanguageOptions(settings: settings),
                            title: \.displayWithFlag,
                            accessibilityName: "Expected speech language",
                            isEnabled: canChangeSpeechModel
                        )
                    }
                    DSDivider()
                    DSDetailRow(label: "Speech model", caption: selectedModel.detail) {
                        SpeechModelMenu(
                            selection: Binding(
                                get: { settings.parakeetModelChoice },
                                set: { newValue in
                                    guard newValue != settings.parakeetModelChoice else { return }
                                    modelActionError = nil
                                    settings.parakeetModelChoice = newValue
                                    Task {
                                        await appState.parakeetEngine.recheckModelOnDisk(for: newValue)
                                        await appState.handleParakeetModelSelectionChange(userInitiated: true)
                                    }
                                }
                            ),
                            language: settings.selectedLanguage,
                            isEnabled: canChangeSpeechModel
                        )
                    }
                    if let notice = selectedModel.languageSupportNotice(for: settings.selectedLanguage) {
                        DSFieldMessage(
                            text: notice,
                            tone: selectedModel.supportsLanguage(settings.selectedLanguage) ? .warning : .error
                        )
                        .padding(.horizontal, DS.Spacing.rowHorizontal)
                        .padding(.bottom, 14)
                    }
                    DSDivider()
                    DSInfoRow(
                        label: "Type",
                        value: selectedModel.usesTrueStreaming
                            ? "On-device true streaming speech-to-text"
                            : "On-device speech-to-text"
                    )
                    DSDivider()
                    DSInfoRow(label: "Underlying model", value: selectedModel.modelName)
                    DSDivider()
                    if selectedModel.isEnglishNemotron {
                        DSDetailRow(
                            label: "Streaming preset",
                            caption: "Fast preview uses a smaller audio buffer. Larger buffers delay the preview and improve processing throughput. Each preset has its own download."
                        ) {
                            DSDropdown(
                                selection: Binding(
                                    get: { settings.parakeetModelChoice },
                                    set: { preset in
                                        guard preset != settings.parakeetModelChoice else { return }
                                        modelActionError = nil
                                        settings.parakeetModelChoice = preset
                                        Task {
                                            await appState.parakeetEngine.recheckModelOnDisk(for: preset)
                                            await appState.handleParakeetModelSelectionChange(userInitiated: true)
                                        }
                                    }
                                ),
                                options: [.nemotron560, .nemotron1120, .nemotron2240],
                                title: \.streamingPresetTitle,
                                accessibilityName: "English Nemotron streaming preset",
                                isEnabled: canChangeSpeechModel
                            )
                        }
                        DSDivider()
                    }
                    DSInfoRow(label: "Languages", value: selectedModel.languageSummary)
                    DSDivider()
                    DSInfoRow(label: "Download size", value: selectedModel.sizeSummary)
                    if let alternateModel = alternateInstalledModel(excluding: selectedModel) {
                        DSDivider()
                        DSInfoRow(label: "Also installed", value: alternateModel.displayName)
                    }
                    if selectedModel.supportsEndOfUtterance {
                        DSDivider()
                        DSInfoRow(label: "Stop hands-free dictation after speech ends") {
                            DSSwitch(accessibilityName: "Stop hands-free dictation after speech ends", isOn: $settings.autoStopAfterSpeechEndsEnabled)
                        }
                    }
                    DSDivider()
                    statusRow
                    if appState.parakeetEngine.isModelDownloaded {
                        if !selectedModel.usesTrueStreaming {
                            DSDivider()
                            speechDetectionRow
                        }
                        DSDivider()
                        DSInfoRow(
                            label: selectedModel.isEnglishNemotron
                                ? "Remove the selected preset files from this Mac."
                                : "Remove the downloaded model files from this Mac.",
                            labelColor: DS.Colors.textSecondary,
                            labelWeight: .regular
                        ) {
                            Button(selectedModel.isEnglishNemotron ? "Delete Preset…" : "Delete Model…") {
                                modelPendingDeletion = selectedModel
                            }
                            .buttonStyle(.dsDestructive)
                            .disabled(appState.status != .idle || appState.isPreparingEngine || isDeletingModel
                                || appState.parakeetEngine.isDownloading)
                        }
                    }
                    if let error = modelActionError ?? appState.enginePreparationError {
                        DSDivider()
                        DSFieldMessage(text: error, tone: .error)
                            .padding(.vertical, 10)
                            .padding(.horizontal, DS.Spacing.rowHorizontal)
                    }
                }

                DSHint(text: selectedModel.speechModelFooter)
            } else if settings.engineChoice == .appleSpeech {
                DSSection(overline: "Apple Speech") {
                    DSInfoRow(label: "Model", value: "Apple Speech — managed by macOS")
                    DSDivider()
                    DSInfoRow(label: "Type", value: "On-device speech-to-text")
                    DSDivider()
                    DSInfoRow(label: "Language", value: settings.appleSpeechLanguage.displayName)
                    DSDivider()
                    DSInfoRow(label: "Model storage", value: "Downloaded and managed by macOS")
                    DSDivider()
                    appleSpeechStatusRow
                    if let error = appState.enginePreparationError {
                        DSDivider()
                        DSFieldMessage(text: error, tone: .error)
                            .padding(.vertical, 10)
                            .padding(.horizontal, DS.Spacing.rowHorizontal)
                    }
                }

                DSHint(
                    text:
                        "Apple Speech is available on supported Macs running macOS 26 or later. Audio and transcription stay on this Mac."
                )
            } else if settings.engineChoice == .assemblyAI {
                assemblyAIContent(settings: settings)
            }
        }
        .alert(
            "Delete \(modelPendingDeletion?.displayName ?? selectedModel.displayName)?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { model in
            Button("Delete", role: .destructive) {
                modelPendingDeletion = nil
                deleteModel(model)
            }
            Button("Cancel", role: .cancel) { modelPendingDeletion = nil }
        } message: { model in
            Text(model.isEnglishNemotron
                 ? "This will remove the \(model.streamingPresetTitle) download for \(model.displayName) (\(model.sizeSummary)). Other preset downloads are kept. You can download it again later."
                 : "This will remove the \(model.displayName) speech model (\(model.sizeSummary)). You can download it again later.")
        }
    }


    private var canChangeSpeechModel: Bool {
        appState.status == .idle && !appState.parakeetEngine.isDownloading
            && !appState.isPreparingEngine && !isDeletingModel
    }

    private func expectedLanguageOptions(settings: Settings) -> [SupportedLanguage] {
        // Keep a migrated selection visible with its notice; never silently
        // rewrite the user's preferred language to make the picker look valid.
        ParakeetModelChoice.catalogLanguageOptions(
            preserving: settings.selectedLanguage,
            hasNeuralEngine: Hardware.canUseAppleNeuralEngine)
    }

    private func deleteModel(_ model: ParakeetModelChoice) {
        guard appState.status == .idle, !appState.isPreparingEngine,
              !appState.parakeetEngine.isDownloading, !isDeletingModel,
              appState.settings.engineChoice == .parakeet,
              appState.settings.parakeetModelChoice == model else {
            modelActionError = "The selected model is busy or has changed. Review it and try deleting again."
            return
        }
        modelActionError = nil
        isDeletingModel = true
        Task {
            defer { isDeletingModel = false }
            do {
                try await appState.parakeetEngine.deleteModel()
                await appState.handleParakeetModelSelectionChange(userInitiated: false)
            } catch {
                modelActionError = error.localizedDescription
            }
        }
    }

    private func engineChoiceTitle(_ choice: TranscriptionEngineChoice) -> String {
        if choice == .appleSpeech, !AppleSpeechEngine.isOperatingSystemSupported {
            return "Apple Speech (Requires macOS 26)"
        }
        return choice.displayName
    }

    private func pageSubtitle(settings: Settings) -> String {
        settings.engineChoice == .assemblyAI
            ? "AssemblyAI processes audio in the cloud and returns text ready to paste."
            : "Everything runs on your Mac — your voice never leaves this device."
    }

    @ViewBuilder
    private func assemblyAIContent(settings: Settings) -> some View {
        @Bindable var settings = settings

        DSSection(overline: "AssemblyAI") {
            DSInfoRow(label: "Model", value: "AssemblyAI Dictation — provider-managed")
            DSDivider()
            DSDetailRow(
                label: "API key",
                caption:
                    "Stored in macOS Keychain. You can also launch the app with ASSEMBLYAI_API_KEY set."
            ) {
                HStack(spacing: 8) {
                    DSTextField(
                        placeholder: "Paste AssemblyAI API key",
                        text: Binding(
                            get: { settings.assemblyAIAPIKey },
                            set: { appState.updateAssemblyAIAPIKey($0) }
                        ),
                        isSecure: true,
                        accessibilityName: "AssemblyAI API key"
                    )
                    .frame(width: 280)
                    if !settings.assemblyAIAPIKey.isEmpty {
                        Button("Clear Stored Key") { appState.updateAssemblyAIAPIKey("") }
                            .buttonStyle(.dsDestructive)
                    }
                }
            }
            if let error = settings.assemblyAIAPIKeyError {
                DSFieldMessage(text: error, tone: .error)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
            }
            DSDivider()
            DSInfoRow(label: "Status") {
                if settings.resolvedAssemblyAIAPIKey.isEmpty {
                    DSStatusPill(
                        text: "API key required",
                        dotColor: DS.Colors.textSecondary,
                        textColor: DS.Colors.textSecondary,
                        fill: DS.Colors.bgInset
                    )
                } else {
                    DSStatusPill(text: "API key configured")
                }
            }
            DSDivider()
            DSDetailRow(
                label: "Processing region",
                caption:
                    "Global chooses the lowest-latency region. US and EU keep audio and transcription processing in that data zone."
            ) {
                DSDropdown(
                    selection: $settings.assemblyAIRegion,
                    options: AssemblyAIRegion.allCases,
                    title: \.displayName,
                    accessibilityName: "AssemblyAI processing region"
                )
            }
            DSDivider()
            DSInfoRow(label: "Price", value: "$0.62 per hour of audio")
        }

        DSSection(overline: "Dictation") {
            DSDetailRow(
                label: "Language",
                caption:
                    "Choose the expected language. The API can also recognize code-switching, but this first version sends one language per request."
            ) {
                DSDropdown(
                    selection: $settings.assemblyAILanguage,
                    options: AssemblyAILanguage.allCases,
                    title: \.displayName,
                    accessibilityName: "AssemblyAI language"
                )
            }
            DSDivider()
            DSDetailRow(
                label: "Live preview",
                caption:
                    "Uses an installed Apple Speech language on-device when available. The final pasted transcript always comes from AssemblyAI."
            ) {
                Text("Automatic")
                    .font(DS.Fonts.ui(13.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            DSDivider()
            DSDetailRow(
                label: "Output",
                caption: settings.assemblyAIOutputMode == .polished
                    ? "Removes filler, resolves clear self-corrections, and applies punctuation before pasting."
                    : "Pastes the verbatim transcript; AssemblyAI still returns both versions."
            ) {
                DSDropdown(
                    selection: $settings.assemblyAIOutputMode,
                    options: AssemblyAIOutputMode.allCases,
                    title: \.displayName,
                    accessibilityName: "AssemblyAI output"
                )
            }
        }

        DSSection(overline: "Internal Prompts") {
            DSDetailRow(
                label: "Customize prompts",
                caption: "Edit AssemblyAI recognition, cleanup, destination, writing-style, and field-context instructions."
            ) {
                Button("Customize…") {
                    appState.selectedPage = .internalPrompts
                }
                .buttonStyle(.dsSecondary)
            }
        }

        CustomVocabularySection(
            terms: $settings.customVocabulary,
            footer:
                "Up to 100 names, product terms, and domain-specific phrases are sent as AssemblyAI keyterms. With remote context sharing enabled, destination terms are added for the current dictation only."
        )

        DSSection(overline: "Context Awareness") {
            DSStackedRow(
                label: "Adapt to the current app and text field",
                caption:
                    "Classifies the destination and sends that category to AssemblyAI. Password fields and excluded apps are never read.",
                isOn: $settings.dictationContextAwarenessEnabled
            )
            if settings.dictationContextAwarenessEnabled {
                DSDivider()
                DSStackedRow(
                    label: "Share app details and surrounding text with AssemblyAI",
                    caption:
                        "Off by default. App name, nearby text, and extracted terms stay on this Mac unless enabled and are never shared from password fields or excluded apps.",
                    isOn: $settings.shareDictationContextWithRemoteProviders
                )
            }
        }

        if settings.dictationContextAwarenessEnabled,
            settings.assemblyAIOutputMode == .polished
        {
            DSSection(overline: "Writing Style") {
                assemblyAIWritingStyleRow(settings: settings, category: .email)
                DSDivider()
                assemblyAIWritingStyleRow(settings: settings, category: .workMessaging)
                DSDivider()
                assemblyAIWritingStyleRow(settings: settings, category: .personalMessaging)
                DSDivider()
                assemblyAIWritingStyleRow(settings: settings, category: .other)
            }
        }

        DSHint(
            text:
                "AssemblyAI requires an internet connection and accepts recordings up to 120 seconds. Dictate Anywhere deletes its temporary local recovery copy after success; failed requests remain in History when that copy is available."
        )
    }

    private func assemblyAIWritingStyleRow(
        settings: Settings,
        category: DictationContextCategory
    ) -> some View {
        DSDetailRow(label: category.displayName, caption: assemblyAIStyleCaption(for: category)) {
            DSDropdown(
                selection: assemblyAIWritingStyleBinding(settings: settings, category: category),
                options: DictationWritingStyle.options(for: category),
                title: \.displayName,
                accessibilityName: "AssemblyAI writing style for \(category.displayName)"
            )
        }
    }

    private func assemblyAIWritingStyleBinding(
        settings: Settings,
        category: DictationContextCategory
    ) -> Binding<DictationWritingStyle> {
        Binding(
            get: { settings.dictationWritingStyle(for: category) },
            set: { value in
                switch category {
                case .email: settings.emailDictationWritingStyle = value
                case .workMessaging: settings.workMessagingDictationWritingStyle = value
                case .personalMessaging: settings.personalMessagingDictationWritingStyle = value
                case .other: settings.otherDictationWritingStyle = value
                }
            }
        )
    }

    private func assemblyAIStyleCaption(for category: DictationContextCategory) -> String {
        switch category {
        case .email: return "Used in mail apps and webmail."
        case .workMessaging: return "Used in Slack, Teams, Discord, and similar work chat."
        case .personalMessaging:
            return "Used in Messages, WhatsApp, Telegram, and similar personal chat."
        case .other: return "Used when no email or messaging category matches."
        }
    }

    private var appleSpeechStatusRow: some View {
        let readiness: ModelReadiness = appState.isPreparingEngine ? .preparing
            : (appState.appleSpeechEngine.isReady ? .ready : .needsSetup)
        return DSModelReadinessRow(readiness: readiness,
            actionTitle: readiness == .needsSetup ? "Set Up Apple Speech" : nil,
            action: { Task { await appState.prepareActiveEngine() } })
            .disabled(appState.status != .idle || isDeletingModel)
    }

    private var speechReadiness: ModelReadiness {
        if isDeletingModel { return .deleting }
        if appState.parakeetEngine.isDownloading { return .downloading(appState.parakeetEngine.downloadProgress) }
        if appState.isPreparingEngine { return .preparing }
        if appState.parakeetEngine.isReady { return .ready }
        return appState.parakeetEngine.isModelDownloaded ? .downloaded : .notDownloaded
    }

    private var statusRow: some View {
        let readiness = speechReadiness
        let actionTitle = readiness == .notDownloaded ? "Download Model"
            : (readiness == .downloaded ? "Prepare Model" : nil)
        return DSModelReadinessRow(readiness: readiness, actionTitle: actionTitle, action: {
            modelActionError = nil
            Task {
                if appState.parakeetEngine.isModelDownloaded {
                    await appState.prepareActiveEngine()
                } else {
                    do {
                        try await appState.parakeetEngine.downloadModel()
                        applyParakeetSelection(userInitiated: true)
                    } catch { modelActionError = error.localizedDescription }
                }
            }
        })
        .disabled(appState.status != .idle || isDeletingModel)
    }

    private var speechDetectionRow: some View {
        let installed = appState.parakeetEngine.isSpeechDetectionDownloaded
        return DSDetailRow(label: "Speech detection", caption: installed
            ? "Helps recognize quiet speech and split recordings at pauses."
            : "Optional download for quiet speech and pause detection. Dictation works without it.") {
            if installed {
                Text("Installed")
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                Button("Download Speech Detection") {
                    modelActionError = nil
                    Task {
                        do { try await appState.parakeetEngine.downloadSpeechDetection() }
                        catch { modelActionError = error.localizedDescription }
                    }
                }
                .buttonStyle(.dsSecondary)
                .disabled(appState.status != .idle || appState.isPreparingEngine || isDeletingModel
                    || appState.parakeetEngine.isDownloading)
            }
        }
    }

    private func applyParakeetSelection(userInitiated: Bool) {
        guard appState.status == .idle else { return }
        Task { await appState.handleParakeetModelSelectionChange(userInitiated: userInitiated) }
    }

    private func alternateInstalledModel(excluding selectedModel: ParakeetModelChoice) -> ParakeetModelChoice? {
        // Files for a model this Mac can't run may survive a migration — don't
        // advertise one the picker won't offer.
        ParakeetModelChoice.availableCases.first {
            $0.catalogChoice != selectedModel.catalogChoice && appState.parakeetEngine.checkModelOnDisk(for: $0)
        }
    }
}
