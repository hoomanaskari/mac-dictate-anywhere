//
//  AIPostProcessingView.swift
//  Dictate Anywhere
//
//  "Transcript Cleanup" page: AI post-processing settings.
//

import SwiftUI
import FoundationModels

struct AIPostProcessingView: View {
    @Environment(AppState.self) private var appState
    @State private var newFillerWord = ""
    @State private var newVocabularyTerm = ""
    @State private var ollamaAvailability: OllamaPostProcessingService.Availability?
    @State private var ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
    @State private var ollamaPendingDeletionModel: String?
    @State private var ollamaStatusMessage: String?
    @State private var isCheckingOllama = false
    @State private var openRouterAvailability: OpenRouterPostProcessingService.Availability?
    @State private var openRouterStatusMessage: String?
    @State private var isCheckingOpenRouter = false
    @State private var openAICompatibleAvailability: OpenAICompatiblePostProcessingService.Availability?
    @State private var openAICompatibleStatusMessage: String?
    @State private var isCheckingOpenAICompatible = false
    private let shouldAutoRefreshProviderAvailability: Bool

    init(
        initialOllamaAvailability: OllamaPostProcessingService.Availability? = nil,
        initialOllamaCLIAvailability: OllamaPostProcessingService.CLIAvailability = OllamaPostProcessingService.cliAvailability(),
        initialOllamaStatusMessage: String? = nil,
        initialOpenRouterAvailability: OpenRouterPostProcessingService.Availability? = nil,
        initialOpenRouterStatusMessage: String? = nil,
        initialOpenAICompatibleAvailability: OpenAICompatiblePostProcessingService.Availability? = nil,
        initialOpenAICompatibleStatusMessage: String? = nil,
        shouldAutoRefreshProviderAvailability: Bool = true
    ) {
        _ollamaAvailability = State(initialValue: initialOllamaAvailability)
        _ollamaCLIAvailability = State(initialValue: initialOllamaCLIAvailability)
        _ollamaStatusMessage = State(initialValue: initialOllamaStatusMessage)
        _openRouterAvailability = State(initialValue: initialOpenRouterAvailability)
        _openRouterStatusMessage = State(initialValue: initialOpenRouterStatusMessage)
        _openAICompatibleAvailability = State(initialValue: initialOpenAICompatibleAvailability)
        _openAICompatibleStatusMessage = State(initialValue: initialOpenAICompatibleStatusMessage)
        self.shouldAutoRefreshProviderAvailability = shouldAutoRefreshProviderAvailability
    }

    var body: some View {
        @Bindable var settings = appState.settings

        DSPage {
            DSSectionHeader(
                title: "Transcript Cleanup",
                subtitle: "Choose how your transcript is polished before it's pasted."
            )

            DSSection(overline: "AI Processing") {
                DSDetailRow(
                    label: "Transcript processing",
                    caption: "Choose how the final transcript is cleaned up before it is pasted."
                ) {
                    DSDropdown(
                        selection: $settings.transcriptPostProcessingMode,
                        options: TranscriptPostProcessingMode.allCases,
                        title: \.displayName
                    )
                }
            }

            localFillerWordCleanupContent(settings: settings)

            switch settings.transcriptPostProcessingMode {
            case .none:
                DSPanel(
                    text: "No AI cleanup will run. The raw FluidAudio transcript is pasted after the local filler-word cleanup above.",
                    icon: "sparkles"
                )
            case .fluidAudioVocabulary:
                fluidAudioVocabularyContent(settings: settings)
            case .appleIntelligence:
                if #available(macOS 26, *) {
                    appleIntelligenceContent(settings: settings)
                } else {
                    DSPanel(
                        text: "Apple Intelligence transcript processing requires macOS 26 or later.",
                        icon: "exclamationmark.triangle"
                    )
                }
            case .ollama:
                ollamaContent(settings: settings)
            case .openRouter:
                openRouterContent(settings: settings)
            case .openAICompatible:
                openAICompatibleContent(settings: settings)
            }
        }
        .task(id: providerTaskID(settings: settings)) {
            guard shouldAutoRefreshProviderAvailability else { return }
            ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
            await refreshProviderAvailabilityIfNeeded(settings: settings)
        }
        .alert(
            "Delete Ollama Model?",
            isPresented: Binding(
                get: { ollamaPendingDeletionModel != nil },
                set: { isPresented in
                    if !isPresented {
                        ollamaPendingDeletionModel = nil
                    }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let model = ollamaPendingDeletionModel else { return }
                ollamaPendingDeletionModel = nil
                Task {
                    await appState.deleteOllamaModel(model)
                }
            }
            Button("Cancel", role: .cancel) {
                ollamaPendingDeletionModel = nil
            }
        } message: {
            Text("This will remove \(ollamaPendingDeletionModel ?? "this model") from the configured Ollama server.")
        }
    }

    // MARK: - Shared row helpers

    /// Labeled single-line field row inside a card.
    @ViewBuilder
    private func fieldRow<Field: View>(
        label: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Text(label)
                .font(DS.Fonts.ui(13.5, .medium))
                .foregroundStyle(DS.Colors.ink)
            Spacer(minLength: 0)
            field()
                .frame(width: 320)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    /// Secondary caption line inside a card.
    @ViewBuilder
    private func cardCaption(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.ui(12.5))
            .lineSpacing(12.5 * 0.5 - 3)
            .foregroundStyle(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    @ViewBuilder
    private func cardPadded<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    // MARK: - Local filler word removal

    @ViewBuilder
    private func localFillerWordCleanupContent(settings: Settings) -> some View {
        @Bindable var settings = settings

        DSSection(overline: "Local Filler Word Removal") {
            DSStackedRow(
                label: "Remove selected filler words",
                caption: settings.parakeetModelChoice.usesTrueStreaming
                    ? "Runs locally on this Mac before any AI processing — no AI involved. Helpful for streaming models that transcribe filler words literally."
                    : "Runs locally on this Mac before any AI processing — no AI involved. It removes only the editable words listed here.",
                isOn: $settings.isFillerWordRemovalEnabled
            )

            if settings.isFillerWordRemovalEnabled {
                DSDivider()
                cardPadded {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Words:")
                            .font(DS.Fonts.ui(12.5, .medium))
                            .foregroundStyle(DS.Colors.textSecondary)
                        FlowLayout(spacing: 6) {
                            ForEach(settings.fillerWordsToRemove, id: \.self) { word in
                                DSChip(text: word) {
                                    settings.fillerWordsToRemove.removeAll { $0 == word }
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        DSTextField(placeholder: "Add word…", text: $newFillerWord)
                            .frame(width: 220)
                            .onSubmit { addFillerWord() }

                        Button("Add") { addFillerWord() }
                            .buttonStyle(.dsSecondary)
                            .disabled(newFillerWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer(minLength: 0)

                        Button("Reset to Defaults") {
                            settings.fillerWordsToRemove = Settings.defaultFillerWords
                        }
                        .buttonStyle(.dsSecondary)
                    }
                }
            }
        }
    }

    private func addFillerWord() {
        let word = newFillerWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !appState.settings.fillerWordsToRemove.contains(word) else { return }
        appState.settings.fillerWordsToRemove.append(word)
        newFillerWord = ""
    }

    // MARK: - FluidAudio vocabulary

    @ViewBuilder
    private func fluidAudioVocabularyContent(settings: Settings) -> some View {
        if settings.parakeetModelChoice.usesTrueStreaming {
            DSPanel(
                text: "FluidAudio Vocabulary is only available with Parakeet TDT models. Choose Multilingual, English Only, or English Compact to use vocabulary rescoring. For streaming models, use Apple Intelligence, Ollama, OpenRouter, or OpenAI Compatible cleanup.",
                icon: "exclamationmark.triangle"
            )
        } else {
            vocabularySection(
                settings: settings,
                footer: "These terms are applied by FluidAudio's vocabulary rescoring on Parakeet TDT final transcripts only. Keep the list short and domain-specific for best precision."
            )
        }
    }

    // MARK: - Apple Intelligence

    @available(macOS 26, *)
    @ViewBuilder
    private func appleIntelligenceContent(settings: Settings) -> some View {
        let availability = AIPostProcessingService.availability
        switch availability {
        case .available:
            @Bindable var settings = settings

            DSSection(overline: "Prompt") {
                cardPadded {
                    SettingsMultilineTextArea(
                        text: $settings.aiPostProcessingPrompt,
                        placeholder: "Enter your prompt, e.g. \"Break into sentences, fix grammar, and remove filler words.\""
                    )
                    .labelsHidden()
                }
                DSDivider()
                cardCaption("This prompt tells Apple Intelligence how to transform your transcribed text. The transcript is appended after your prompt.")
            }

            vocabularySection(
                settings: settings,
                footer: "These terms are applied only by Apple Intelligence post-processing to preserve product names, names, and domain-specific wording."
            )

        case .unavailable(.deviceNotEligible):
            DSPanel(
                text: "Your Mac doesn't support Apple Intelligence. AI Post Processing requires a Mac that supports Apple Intelligence.",
                icon: "xmark.circle"
            )

        case .unavailable(.appleIntelligenceNotEnabled):
            DSSection(overline: "Apple Intelligence") {
                cardPadded {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(DS.Colors.accentDeep)
                        Text("Apple Intelligence is not enabled")
                            .font(DS.Fonts.ui(13.5, .medium))
                            .foregroundStyle(DS.Colors.ink)
                    }
                    Button("Open Apple Intelligence Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.dsPrimary)
                }
                DSDivider()
                cardCaption("Enable Apple Intelligence in System Settings to use AI Post Processing.")
            }

        case .unavailable(.modelNotReady):
            DSSection(overline: "Apple Intelligence") {
                cardPadded {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(DS.Colors.accent)
                        Text("Apple Intelligence model is downloading…")
                            .font(DS.Fonts.ui(13.5, .medium))
                            .foregroundStyle(DS.Colors.ink)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                DSDivider()
                cardCaption("The on-device model is being prepared. This may take a few minutes.")
            }

        case .unavailable(_):
            DSPanel(
                text: "Apple Intelligence is currently unavailable. Try again later.",
                icon: "exclamationmark.triangle"
            )
        }
    }

    // MARK: - Ollama

    @ViewBuilder
    private func ollamaContent(settings: Settings) -> some View {
        if !ollamaCLIAvailability.isAvailable {
            ollamaInstallCard(settings: settings)
        }

        DSSection(overline: "Ollama") {
            fieldRow(label: "Server URL") {
                DSTextField(
                    placeholder: OllamaPostProcessingService.defaultBaseURL,
                    text: Binding(
                        get: { settings.ollamaBaseURL },
                        set: { settings.ollamaBaseURL = $0 }
                    )
                )
            }
            DSDivider()
            fieldRow(label: "Model") {
                DSTextField(
                    placeholder: "gemma4:e4b",
                    text: Binding(
                        get: { settings.ollamaModel },
                        set: { settings.ollamaModel = $0 }
                    )
                )
            }
            DSDivider()
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    ollamaStatusView(settings: settings)
                    Spacer(minLength: 12)
                    Button(isCheckingOllama ? "Checking…" : "Refresh Models") {
                        Task {
                            await refreshOllamaAvailability(settings: settings, debounce: false)
                        }
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(isCheckingOllama)
                }

                if let availability = ollamaAvailability, !availability.installedModels.isEmpty {
                    let installedModels = availability.installedModels

                    Text("Installed Models")
                        .font(DS.Fonts.ui(12, .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)

                    FlowLayout(spacing: 6) {
                        ForEach(installedModels, id: \.self) { (model: String) in
                            let isSelected = settings.ollamaModel == model
                            let isDeleting = appState.ollamaDeletingModel == model
                            let canDelete = ollamaCanDeleteModels
                            let isBusy = appState.ollamaDownloadState != nil || appState.ollamaDeletingModel != nil

                            Button {
                                guard !isDeleting else { return }
                                settings.ollamaModel = model
                            } label: {
                                DSChip(
                                    text: model,
                                    isSelected: isSelected,
                                    onRemove: canDelete && !isBusy ? { ollamaPendingDeletionModel = model } : nil
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isDeleting)
                        }
                    }
                }
            }
            DSDivider()
            cardCaption("Runs transcript cleanup through your local Ollama server. Use the server base URL and an installed model name. Larger models are noticeably better at following cleanup instructions and vocabulary normalization.")
        }

        ollamaSuggestedModelsSection(settings: settings)

        if let capability = ollamaAvailability?.selectedModelReasoningCapability,
           capability.supportsReasoning {
            DSSection(overline: "Reasoning") {
                DSDetailRow(
                    label: "Reasoning",
                    caption: ollamaReasoningFooter(for: capability)
                ) {
                    DSDropdown(
                        selection: Binding(
                            get: { settings.ollamaReasoningSetting.sanitized(for: capability) },
                            set: { settings.ollamaReasoningSetting = $0.sanitized(for: capability) }
                        ),
                        options: OllamaReasoningSetting.options(for: capability),
                        title: \.displayName
                    )
                }
            }
        }

        DSSection(overline: "Prompt") {
            cardPadded {
                SettingsMultilineTextArea(
                    text: Binding(
                        get: { settings.ollamaPostProcessingPrompt },
                        set: { settings.ollamaPostProcessingPrompt = $0 }
                    ),
                    placeholder: "Optional: add style or cleanup instructions for Ollama."
                )
                .labelsHidden()
            }
            DSDivider()
            cardCaption("Pre-filled with the recommended cleanup prompt. Customize it if you want different safe cleanup behavior for Ollama.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to Ollama to preserve product names, names, and domain-specific wording during post-processing."
        )
    }

    // MARK: - OpenRouter

    @ViewBuilder
    private func openRouterContent(settings: Settings) -> some View {
        DSSection(overline: "OpenRouter") {
            fieldRow(label: "API Key") {
                DSTextField(
                    placeholder: "Paste OpenRouter API key",
                    text: Binding(
                        get: { settings.openRouterAPIKey },
                        set: { settings.openRouterAPIKey = $0 }
                    ),
                    isSecure: true
                )
            }
            DSDivider()
            fieldRow(label: "API Key Environment Variable (Optional)") {
                DSTextField(
                    placeholder: OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable,
                    text: Binding(
                        get: { settings.openRouterAPIKeyEnvironmentVariable },
                        set: { settings.openRouterAPIKeyEnvironmentVariable = $0 }
                    )
                )
            }
            DSDivider()
            fieldRow(label: "Model") {
                DSTextField(
                    placeholder: "openai/gpt-5-mini",
                    text: Binding(
                        get: { settings.openRouterModel },
                        set: { settings.openRouterModel = $0 }
                    )
                )
            }
            DSDivider()
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    openRouterStatusView(settings: settings)
                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button(isCheckingOpenRouter ? "Checking…" : "Refresh Models") {
                            Task {
                                await refreshOpenRouterAvailability(settings: settings, debounce: false)
                            }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(isCheckingOpenRouter)

                        Button("Browse Models") {
                            guard let url = URL(string: "https://openrouter.ai/models") else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.dsSecondary)

                        if !settings.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear Stored Key") {
                                settings.openRouterAPIKey = ""
                            }
                            .buttonStyle(.dsDestructive)
                        }
                    }
                }
            }
            DSDivider()
            cardCaption("Runs transcript cleanup through OpenRouter's cloud API. Paste a key directly to store it in Keychain, or leave the API key field blank and use the optional environment variable setting instead.")
        }

        if let availability = openRouterAvailability {
            openRouterModelSearchSection(settings: settings, availability: availability)
        }

        DSSection(overline: "Prompt") {
            cardPadded {
                SettingsMultilineTextArea(
                    text: Binding(
                        get: { settings.openRouterPostProcessingPrompt },
                        set: { settings.openRouterPostProcessingPrompt = $0 }
                    ),
                    placeholder: "Optional: add style or cleanup instructions for OpenRouter."
                )
                .labelsHidden()
            }
            DSDivider()
            cardCaption("Pre-filled with the recommended cleanup prompt. Customize it if you want different safe cleanup behavior for OpenRouter.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to OpenRouter to preserve product names, names, and domain-specific wording during post-processing."
        )
    }

    // MARK: - OpenAI Compatible

    @ViewBuilder
    private func openAICompatibleContent(settings: Settings) -> some View {
        DSSection(overline: "OpenAI Compatible") {
            fieldRow(label: "Server URL") {
                DSTextField(
                    placeholder: OpenAICompatiblePostProcessingService.defaultBaseURL,
                    text: Binding(
                        get: { settings.openAICompatibleBaseURL },
                        set: { settings.openAICompatibleBaseURL = $0 }
                    )
                )
            }
            DSDivider()
            fieldRow(label: "API Key (Optional)") {
                DSTextField(
                    placeholder: "Leave blank for local servers without auth",
                    text: Binding(
                        get: { settings.openAICompatibleAPIKey },
                        set: { settings.openAICompatibleAPIKey = $0 }
                    ),
                    isSecure: true
                )
            }
            DSDivider()
            fieldRow(label: "Model") {
                DSTextField(
                    placeholder: "local-model",
                    text: Binding(
                        get: { settings.openAICompatibleModel },
                        set: { settings.openAICompatibleModel = $0 }
                    )
                )
            }
            DSDivider()
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    openAICompatibleStatusView(settings: settings)
                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button(isCheckingOpenAICompatible ? "Checking…" : "Refresh Models") {
                            Task {
                                await refreshOpenAICompatibleAvailability(settings: settings, debounce: false)
                            }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(isCheckingOpenAICompatible)

                        if !settings.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear Stored Key") {
                                settings.openAICompatibleAPIKey = ""
                            }
                            .buttonStyle(.dsDestructive)
                        }
                    }
                }

                if let availability = openAICompatibleAvailability, !availability.models.isEmpty {
                    Text("Available Models")
                        .font(DS.Fonts.ui(12, .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)

                    FlowLayout(spacing: 6) {
                        ForEach(availability.models, id: \.self) { model in
                            let isSelected = settings.openAICompatibleModel.caseInsensitiveCompare(model) == .orderedSame
                            Button {
                                settings.openAICompatibleModel = model
                            } label: {
                                DSChip(text: model, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            DSDivider()
            cardCaption("Runs transcript cleanup through a local or self-hosted OpenAI-compatible chat completions server, such as LM Studio, llama.cpp, vLLM, or LocalAI. Use the base URL and model name reported by that server.")
        }

        DSSection(overline: "Prompt") {
            cardPadded {
                SettingsMultilineTextArea(
                    text: Binding(
                        get: { settings.openAICompatiblePostProcessingPrompt },
                        set: { settings.openAICompatiblePostProcessingPrompt = $0 }
                    ),
                    placeholder: "Optional: add style or cleanup instructions for this server."
                )
                .labelsHidden()
            }
            DSDivider()
            cardCaption("Pre-filled with the recommended cleanup prompt. Customize it if you want different safe cleanup behavior for this server.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to the OpenAI-compatible server to preserve product names, names, and domain-specific wording during post-processing."
        )
    }

    // MARK: - Ollama install card

    @ViewBuilder
    private func ollamaInstallCard(settings: Settings) -> some View {
        DSCard {
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shippingbox.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(DS.Colors.accent)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Install Ollama for local transcript cleanup")
                            .font(DS.Fonts.ui(14, .semibold))
                            .foregroundStyle(DS.Colors.ink)

                        Text("Ollama lets Dictate Anywhere clean up transcripts with a local language model on your Mac. It can improve punctuation, grammar, formatting, and term normalization without relying on a hosted API.")
                            .font(DS.Fonts.ui(12.5))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ollamaInstallBullet("Run post-processing on your machine", systemImage: "lock.shield")
                    ollamaInstallBullet("Use local models for stronger cleanup and normalization", systemImage: "sparkles.rectangle.stack")
                    ollamaInstallBullet("Download recommended models directly from this app once installed", systemImage: "arrow.down.circle")
                }

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        guard let url = URL(string: "https://ollama.com/download") else { return }
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Download Ollama", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.dsPrimary)

                    Text("You can still connect to a remote Ollama server by entering its URL below.")
                        .font(DS.Fonts.ui(12))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func ollamaInstallBullet(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 16)
            Text(text)
                .font(DS.Fonts.ui(13))
                .foregroundStyle(DS.Colors.ink)
        }
    }

    // MARK: - Ollama suggested models

    @ViewBuilder
    private func ollamaSuggestedModelsSection(settings: Settings) -> some View {
        DSSection(overline: "Suggested Models") {
            ForEach(Array(OllamaPostProcessingService.suggestedModels.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 {
                    DSDivider()
                }
                ollamaSuggestedModelRow(suggestion, settings: settings)
            }

            if let error = appState.ollamaModelActionError {
                DSDivider()
                Text(error)
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.destructive)
                    .padding(.vertical, 10)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
            }
            DSDivider()
            cardCaption(ollamaSuggestedModelsFooter(settings: settings))
        }
    }

    @ViewBuilder
    private func ollamaSuggestedModelRow(
        _ suggestion: OllamaPostProcessingService.SuggestedModel,
        settings: Settings
    ) -> some View {
        let installedModels = ollamaAvailability?.installedModels ?? []
        let resolvedInstalledModel = OllamaPostProcessingService.matchingInstalledModel(
            for: suggestion.name,
            in: installedModels
        )
        let isInstalled = resolvedInstalledModel != nil
        let isSelected = settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines) == suggestion.name
        let isDownloading = appState.ollamaDownloadState?.model == suggestion.name
        let isDeleting = appState.ollamaDeletingModel == suggestion.name
        let canDownload = ollamaCanDownloadSuggestedModels(settings: settings)
        let canDelete = ollamaCanDeleteModels
        let isAnotherDownloadRunning = appState.ollamaDownloadState != nil && !isDownloading
        let isAnotherDeleteRunning = appState.ollamaDeletingModel != nil && !isDeleting
        let installedMetadata = OllamaPostProcessingService.installedModelMetadata(
            for: resolvedInstalledModel ?? suggestion.name,
            in: ollamaAvailability
        )
        let downloadSizeLabel = installedMetadata.flatMap(ollamaDownloadSizeBadgeText) ?? suggestion.downloadSizeLabel
        let parameterSizeLabel = installedMetadata.flatMap(ollamaParameterSizeBadgeText) ?? suggestion.parameterSizeLabel

        cardPadded {
            Text(suggestion.name)
                .font(DS.Fonts.ui(13.5, .medium))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            FlowLayout(spacing: 6) {
                ollamaBadge(
                    text: suggestion.badge,
                    foreground: DS.Colors.accent,
                    background: DS.Colors.accentSoft
                )

                if isInstalled {
                    ollamaBadge(
                        text: "Installed",
                        foreground: DS.Colors.successText,
                        background: DS.Colors.successSoft
                    )
                }

                if isSelected {
                    ollamaBadge(
                        text: "Selected",
                        foreground: DS.Colors.ink,
                        background: DS.Colors.bgInset
                    )
                }

                if let downloadSizeLabel {
                    ollamaBadge(
                        text: downloadSizeLabel,
                        foreground: DS.Colors.textSecondary,
                        background: DS.Colors.bgInset
                    )
                }

                if let parameterSizeLabel {
                    ollamaBadge(
                        text: parameterSizeLabel,
                        foreground: DS.Colors.textSecondary,
                        background: DS.Colors.bgInset
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(suggestion.description)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer(minLength: 0)

                if isInstalled {
                    HStack(spacing: 8) {
                        if isSelected {
                            Button("Selected") {
                                settings.ollamaModel = resolvedInstalledModel ?? suggestion.name
                            }
                            .buttonStyle(.dsSecondary)
                            .disabled(true)
                        } else {
                            Button("Use") {
                                settings.ollamaModel = resolvedInstalledModel ?? suggestion.name
                            }
                            .buttonStyle(.dsPrimary)
                            .disabled(isDownloading || isDeleting)
                        }

                        if canDelete {
                            Button(isDeleting ? "Deleting…" : "Delete") {
                                ollamaPendingDeletionModel = resolvedInstalledModel ?? suggestion.name
                            }
                            .buttonStyle(.dsDestructive)
                            .disabled(isDeleting || isDownloading || isAnotherDownloadRunning || isAnotherDeleteRunning)
                        }
                    }
                } else if canDownload {
                    if isDownloading {
                        Button("Downloading…") {}
                            .buttonStyle(.dsSecondary)
                            .disabled(true)
                    } else {
                        Button("Download") {
                            Task {
                                await appState.startOllamaModelDownload(suggestion.name)
                            }
                        }
                        .buttonStyle(.dsPrimary)
                        .disabled(isAnotherDownloadRunning || isAnotherDeleteRunning || isCheckingOllama)
                    }
                } else {
                    Button("Use Name") {
                        settings.ollamaModel = suggestion.name
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(isAnotherDownloadRunning || isAnotherDeleteRunning)
                }
            }

            if let downloadState = appState.ollamaDownloadState, downloadState.model == suggestion.name {
                VStack(alignment: .leading, spacing: 6) {
                    if let fractionCompleted = downloadState.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .progressViewStyle(.linear)
                            .tint(DS.Colors.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(DS.Colors.accent)
                    }

                    Text(ollamaDownloadCaption(downloadState))
                        .font(DS.Fonts.ui(12))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
    }

    // MARK: - Vocabulary

    @ViewBuilder
    private func vocabularySection(settings: Settings, footer: String) -> some View {
        @Bindable var settings = settings

        DSSection(overline: "Custom Vocabulary") {
            cardPadded {
                if !settings.customVocabulary.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.customVocabulary, id: \.self) { term in
                            DSChip(text: term) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    settings.customVocabulary.removeAll { $0 == term }
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    DSTextField(placeholder: "Add word or phrase…", text: $newVocabularyTerm)
                        .frame(width: 260)
                        .onSubmit { addVocabularyTerm() }

                    Button("Add") { addVocabularyTerm() }
                        .buttonStyle(.dsSecondary)
                        .disabled(newVocabularyTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            DSDivider()
            cardCaption(footer)
        }
    }

    private func addVocabularyTerm() {
        let terms = VocabularyInputParser.terms(
            from: newVocabularyTerm,
            existingTerms: appState.settings.customVocabulary
        )
        guard !terms.isEmpty else { return }
        appState.settings.customVocabulary.append(contentsOf: terms)
        newVocabularyTerm = ""
    }

    // MARK: - OpenRouter helpers

    private func currentOpenRouterModel(settings: Settings) -> String {
        settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openRouterMatchingModels(
        settings: Settings,
        availability: OpenRouterPostProcessingService.Availability
    ) -> [OpenRouterModelMatch] {
        let query = currentOpenRouterModel(settings: settings)
        guard !query.isEmpty else { return [] }

        let catalogLookupQuery = OpenRouterPostProcessingService.catalogLookupModelID(for: query)
        let normalizedQuery = catalogLookupQuery.lowercased()
        let exactMatch = normalizedQuery

        return availability.models
            .filter { $0.id.lowercased().contains(normalizedQuery) }
            .sorted { lhs, rhs in
                let lhsExact = lhs.id.lowercased() == exactMatch
                let rhsExact = rhs.id.lowercased() == exactMatch
                if lhsExact != rhsExact {
                    return lhsExact && !rhsExact
                }

                let lhsPrefix = lhs.id.lowercased().hasPrefix(normalizedQuery)
                let rhsPrefix = rhs.id.lowercased().hasPrefix(normalizedQuery)
                if lhsPrefix != rhsPrefix {
                    return lhsPrefix && !rhsPrefix
                }

                if lhs.supportsStructuredOutputs != rhs.supportsStructuredOutputs {
                    return lhs.supportsStructuredOutputs && !rhs.supportsStructuredOutputs
                }

                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            .prefix(12)
            .map {
                OpenRouterModelMatch(
                    id: $0.id,
                    supportsStructuredOutputs: $0.supportsStructuredOutputs,
                    supportsAudioInput: $0.supportsAudioInput
                )
            }
    }

    private func openRouterModelSearchEmptyState(settings: Settings) -> String {
        let query = currentOpenRouterModel(settings: settings)
        if query.isEmpty {
            return "Type part of a model id to filter the fetched OpenRouter catalog, or use Browse Models to pick one from openrouter.ai."
        }
        return "No fetched OpenRouter models matched \(query). Try a broader search term or browse the full model directory."
    }

    private func openRouterModelSearchFooter(
        availability: OpenRouterPostProcessingService.Availability
    ) -> String {
        let structuredCount = availability.models.filter(\.supportsStructuredOutputs).count
        let audioInputCount = availability.models.filter(\.supportsAudioInput).count
        return "Fetched \(availability.models.count) OpenRouter models. \(structuredCount) currently advertise structured output support and \(audioInputCount) advertise audio input support."
    }

    private func openRouterModelSearchSection(
        settings: Settings,
        availability: OpenRouterPostProcessingService.Availability
    ) -> some View {
        let matchingModels: [OpenRouterModelMatch] = openRouterMatchingModels(
            settings: settings,
            availability: availability
        )

        return DSSection(overline: "Model Search") {
            if matchingModels.isEmpty {
                cardCaption(openRouterModelSearchEmptyState(settings: settings))
            } else {
                cardPadded {
                    OpenRouterModelMatchesView(
                        models: matchingModels,
                        selectedModel: currentOpenRouterModel(settings: settings)
                    ) { modelID in
                        settings.openRouterModel = modelID
                    }
                }
            }
            DSDivider()
            cardCaption(openRouterModelSearchFooter(availability: availability))
        }
    }

    @ViewBuilder
    private func ollamaBadge(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(DS.Fonts.ui(11, .semibold))
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private func ollamaCanDownloadSuggestedModels(settings: Settings) -> Bool {
        ollamaCLIAvailability.isAvailable && OllamaPostProcessingService.isLocalServer(baseURL: settings.ollamaBaseURL)
    }

    private var ollamaCanDeleteModels: Bool {
        ollamaCLIAvailability.isAvailable
    }

    private func ollamaSuggestedModelsFooter(settings: Settings) -> String {
        if !ollamaCLIAvailability.isAvailable {
            return "Suggested models can be selected here, but download and delete actions are shown only when the Ollama CLI is installed."
        }
        if !OllamaPostProcessingService.isLocalServer(baseURL: settings.ollamaBaseURL) {
            return "Downloads are available only when the server URL points at your local Ollama instance. Delete actions still use the configured Ollama server through the CLI."
        }
        return "Click Download to pull one of these recommended Ollama models locally, or Delete to remove an installed model through the Ollama CLI."
    }

    private func ollamaDownloadSizeBadgeText(
        _ metadata: OllamaPostProcessingService.InstalledModelMetadata
    ) -> String? {
        guard let size = metadata.size, size > 0 else { return nil }
        return "\(formattedOllamaModelSize(size)) download"
    }

    private func ollamaParameterSizeBadgeText(
        _ metadata: OllamaPostProcessingService.InstalledModelMetadata
    ) -> String? {
        guard let parameterSize = metadata.parameterSize?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !parameterSize.isEmpty else {
            return nil
        }
        return "\(parameterSize) params"
    }

    private func formattedOllamaModelSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private func ollamaDownloadCaption(_ state: AppState.OllamaDownloadState) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true

        if let completed = state.completed, let total = state.total, total > 0 {
            let progressText = formatter.string(fromByteCount: completed) + " of " + formatter.string(fromByteCount: total)
            let percentage = Int((state.fractionCompleted ?? 0) * 100)
            return "\(state.status) \(percentage)% (\(progressText))"
        }

        return state.status
    }

    // MARK: - Status views

    @ViewBuilder
    private func statusLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func ollamaStatusView(settings: Settings) -> some View {
        if isCheckingOllama {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Ollama…")
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        } else if !ollamaCLIAvailability.isAvailable &&
                    OllamaPostProcessingService.isLocalServer(baseURL: settings.ollamaBaseURL) {
            statusLabel(
                "Ollama is not installed on this Mac yet. Install it to run transcript cleanup locally, or enter a remote Ollama server URL.",
                systemImage: "info.circle",
                tint: DS.Colors.accent
            )
        } else if let message = ollamaStatusMessage {
            statusLabel(message, systemImage: "xmark.circle", tint: DS.Colors.destructive)
        } else if let availability = ollamaAvailability {
            if availability.installedModels.isEmpty {
                statusLabel(
                    "Connected, but no Ollama models are installed yet.",
                    systemImage: "exclamationmark.triangle",
                    tint: DS.Colors.accentDeep
                )
            } else if availability.selectedModel.isEmpty {
                statusLabel(
                    "Connected. Choose an installed model below or enter one manually.",
                    systemImage: "checkmark.circle",
                    tint: DS.Colors.success
                )
            } else if availability.selectedModelIsInstalled {
                statusLabel(
                    "Connected. \(availability.resolvedSelectedModel ?? availability.selectedModel) is available.",
                    systemImage: "checkmark.circle",
                    tint: DS.Colors.success
                )
            } else {
                statusLabel(
                    "Connected, but \(availability.selectedModel) is not installed on this Ollama server.",
                    systemImage: "exclamationmark.triangle",
                    tint: DS.Colors.accentDeep
                )
            }
        } else {
            statusLabel(
                "Enter your Ollama server URL to check connectivity.",
                systemImage: "bolt.horizontal.circle",
                tint: DS.Colors.textSecondary
            )
        }
    }

    @ViewBuilder
    private func openRouterStatusView(settings: Settings) -> some View {
        let apiKeyStatus = OpenRouterPostProcessingService.apiKeyStatus(
            apiKey: settings.openRouterAPIKey,
            apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
        )
        let selectedModel = currentOpenRouterModel(settings: settings)
        let resolvedModel = OpenRouterPostProcessingService.matchingAvailableModel(
            for: selectedModel,
            in: openRouterAvailability
        )

        if isCheckingOpenRouter {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking OpenRouter…")
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        } else if let message = openRouterStatusMessage {
            statusLabel(message, systemImage: "xmark.circle", tint: DS.Colors.destructive)
        } else if case .missing = apiKeyStatus.source {
            statusLabel(
                "No OpenRouter API key is configured yet. Paste one above or set \(apiKeyStatus.environmentVariableName) in the app environment.",
                systemImage: "key.slash",
                tint: DS.Colors.accentDeep
            )
        } else if let resolvedModel {
            statusLabel(
                openRouterAvailableModelStatusMessage(
                    selectedModel: selectedModel,
                    resolvedModel: resolvedModel,
                    apiKeyStatus: apiKeyStatus
                ),
                systemImage: resolvedModel.supportsStructuredOutputs ? "checkmark.circle" : "exclamationmark.triangle",
                tint: resolvedModel.supportsStructuredOutputs ? DS.Colors.success : DS.Colors.accentDeep
            )
        } else if !selectedModel.isEmpty {
            statusLabel(
                "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(selectedModel) was not found in the latest OpenRouter model refresh.",
                systemImage: "exclamationmark.triangle",
                tint: DS.Colors.accentDeep
            )
        } else if openRouterAvailability != nil {
            statusLabel(
                "\(openRouterCredentialSourceMessage(apiKeyStatus)) Enter a model id above or search the fetched catalog below.",
                systemImage: "checkmark.circle",
                tint: DS.Colors.success
            )
        } else {
            statusLabel(
                "Refresh models to validate your OpenRouter setup and search the available catalog.",
                systemImage: "network",
                tint: DS.Colors.textSecondary
            )
        }
    }

    private func openRouterAvailableModelStatusMessage(
        selectedModel: String,
        resolvedModel model: OpenRouterPostProcessingService.Model,
        apiKeyStatus: OpenRouterPostProcessingService.APIKeyStatus
    ) -> String {
        let selectedCatalogLookupModel = OpenRouterPostProcessingService.catalogLookupModelID(for: selectedModel)
        let usesDynamicVariant = !selectedModel.isEmpty
            && selectedModel.caseInsensitiveCompare(model.id) != .orderedSame
            && selectedCatalogLookupModel.caseInsensitiveCompare(model.id) == .orderedSame
        let modelReference: String

        if usesDynamicVariant {
            modelReference = "\(selectedModel) is valid on OpenRouter and uses the \(model.id) catalog entry"
        } else {
            modelReference = "\(model.id) is available on OpenRouter"
        }

        if model.supportsStructuredOutputs {
            if model.supportsAudioInput {
                return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), which advertises both structured output and audio input support."
            }
            return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), which advertises structured output support."
        }
        if model.supportsAudioInput {
            return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), which advertises audio input support, but it does not advertise structured outputs. Dictate Anywhere will fall back to prompt-based JSON parsing if needed."
        }
        return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), but it does not advertise structured outputs. Dictate Anywhere will fall back to prompt-based JSON parsing if needed."
    }

    private func openRouterCredentialSourceMessage(
        _ apiKeyStatus: OpenRouterPostProcessingService.APIKeyStatus
    ) -> String {
        switch apiKeyStatus.source {
        case .storedKey:
            return "OpenRouter API key is stored securely in Keychain."
        case .inlineValue:
            return "OpenRouter API key was pasted directly into the environment variable field."
        case .environmentVariable:
            return "OpenRouter API key was loaded from \(apiKeyStatus.environmentVariableName)."
        case .missing:
            return "No OpenRouter API key is configured."
        }
    }

    @ViewBuilder
    private func openAICompatibleStatusView(settings: Settings) -> some View {
        let selectedModel = settings.openAICompatibleModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if isCheckingOpenAICompatible {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking server…")
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        } else if let message = openAICompatibleStatusMessage {
            statusLabel(message, systemImage: "xmark.circle", tint: DS.Colors.destructive)
        } else if let availability = openAICompatibleAvailability {
            if availability.models.isEmpty {
                statusLabel(
                    "Connected, but the server did not report any models.",
                    systemImage: "exclamationmark.triangle",
                    tint: DS.Colors.accentDeep
                )
            } else if selectedModel.isEmpty {
                statusLabel(
                    "Connected. Choose a model below or enter one manually.",
                    systemImage: "checkmark.circle",
                    tint: DS.Colors.success
                )
            } else if availability.selectedModelIsAvailable {
                statusLabel(
                    "Connected. \(selectedModel) is available.",
                    systemImage: "checkmark.circle",
                    tint: DS.Colors.success
                )
            } else {
                statusLabel(
                    "Connected, but \(selectedModel) was not listed by this server.",
                    systemImage: "exclamationmark.triangle",
                    tint: DS.Colors.accentDeep
                )
            }
        } else {
            statusLabel(
                "Enter a server URL and refresh models to check connectivity.",
                systemImage: "network",
                tint: DS.Colors.textSecondary
            )
        }
    }

    // MARK: - Availability refresh

    private func providerTaskID(settings: Settings) -> String {
        [
            settings.transcriptPostProcessingMode.rawValue,
            settings.ollamaBaseURL,
            settings.ollamaModel,
            openRouterAvailabilityRefreshKey(settings: settings),
            settings.openAICompatibleBaseURL,
            settings.openAICompatibleModel,
            openAICompatibleAvailabilityRefreshKey(settings: settings),
            String(appState.ollamaModelActionsRevision),
        ].joined(separator: "|")
    }

    private func openRouterAvailabilityRefreshKey(settings: Settings) -> String {
        let hasStoredKey = !settings.openRouterAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let environmentValue = settings.openRouterAPIKeyEnvironmentVariable
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEnvironmentValue: String

        if environmentValue.isEmpty {
            normalizedEnvironmentValue = ""
        } else if environmentValue.lowercased().hasPrefix("sk-or-") {
            normalizedEnvironmentValue = "inline-key"
        } else {
            normalizedEnvironmentValue = environmentValue
        }

        return [
            hasStoredKey ? "stored-key" : "no-stored-key",
            normalizedEnvironmentValue,
        ].joined(separator: "|")
    }

    private func openAICompatibleAvailabilityRefreshKey(settings: Settings) -> String {
        let hasStoredKey = !settings.openAICompatibleAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return hasStoredKey ? "stored-key" : "no-stored-key"
    }

    private func refreshProviderAvailabilityIfNeeded(settings: Settings) async {
        switch settings.transcriptPostProcessingMode {
        case .ollama:
            resetOpenRouterAvailability()
            resetOpenAICompatibleAvailability()
            await refreshOllamaAvailability(settings: settings, debounce: true)
        case .openRouter:
            resetOllamaAvailability()
            resetOpenAICompatibleAvailability()
            await refreshOpenRouterAvailability(settings: settings, debounce: true)
        case .openAICompatible:
            resetOllamaAvailability()
            resetOpenRouterAvailability()
            await refreshOpenAICompatibleAvailability(settings: settings, debounce: true)
        case .none, .fluidAudioVocabulary, .appleIntelligence:
            resetOllamaAvailability()
            resetOpenRouterAvailability()
            resetOpenAICompatibleAvailability()
        }
    }

    private func refreshOllamaAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .ollama else {
            resetOllamaAvailability()
            return
        }

        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        let baseURL = settings.ollamaBaseURL
        let model = settings.ollamaModel

        ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
        isCheckingOllama = true
        defer { isCheckingOllama = false }

        do {
            let availability = try await OllamaPostProcessingService.availability(
                baseURL: baseURL,
                selectedModel: model
            )
            guard !Task.isCancelled else { return }
            ollamaAvailability = availability
            ollamaStatusMessage = nil
            if availability.selectedModelReasoningCapability.supportsReasoning {
                let sanitizedReasoning = settings.ollamaReasoningSetting
                    .sanitized(for: availability.selectedModelReasoningCapability)
                if sanitizedReasoning != settings.ollamaReasoningSetting {
                    settings.ollamaReasoningSetting = sanitizedReasoning
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            ollamaAvailability = nil
            ollamaStatusMessage = error.localizedDescription
        }
    }

    private func refreshOpenRouterAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .openRouter else {
            resetOpenRouterAvailability()
            return
        }

        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        isCheckingOpenRouter = true
        defer { isCheckingOpenRouter = false }

        do {
            let availability = try await OpenRouterPostProcessingService.availability(
                apiKey: settings.openRouterAPIKey,
                apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
            )
            guard !Task.isCancelled else { return }
            openRouterAvailability = availability
            openRouterStatusMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            openRouterAvailability = nil
            openRouterStatusMessage = error.localizedDescription
        }
    }

    private func refreshOpenAICompatibleAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .openAICompatible else {
            resetOpenAICompatibleAvailability()
            return
        }

        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        isCheckingOpenAICompatible = true
        defer { isCheckingOpenAICompatible = false }

        do {
            let availability = try await OpenAICompatiblePostProcessingService.availability(
                baseURL: settings.openAICompatibleBaseURL,
                apiKey: settings.openAICompatibleAPIKey,
                selectedModel: settings.openAICompatibleModel
            )
            guard !Task.isCancelled else { return }
            openAICompatibleAvailability = availability
            openAICompatibleStatusMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            openAICompatibleAvailability = nil
            openAICompatibleStatusMessage = error.localizedDescription
        }
    }

    private func resetOllamaAvailability() {
        isCheckingOllama = false
        ollamaAvailability = nil
        ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
        ollamaStatusMessage = nil
    }

    private func resetOpenRouterAvailability() {
        isCheckingOpenRouter = false
        openRouterAvailability = nil
        openRouterStatusMessage = nil
    }

    private func resetOpenAICompatibleAvailability() {
        isCheckingOpenAICompatible = false
        openAICompatibleAvailability = nil
        openAICompatibleStatusMessage = nil
    }

    private func ollamaReasoningFooter(for capability: OllamaReasoningCapability) -> String {
        switch capability {
        case .unsupported:
            return ""
        case .toggle:
            return "Shown only when the selected model reports Ollama thinking support. Automatic keeps the model default; Off disables reasoning to reduce latency."
        case .level:
            return "Shown only when the selected model supports configurable reasoning levels. Automatic keeps the model default; low, medium, and high trade speed for more reasoning."
        }
    }
}

private struct OpenRouterModelMatch: Identifiable, Hashable {
    let id: String
    let supportsStructuredOutputs: Bool
    let supportsAudioInput: Bool
}

private struct OpenRouterModelMatchesView: View {
    let models: [OpenRouterModelMatch]
    let selectedModel: String
    let onSelect: (String) -> Void

    var body: some View {
        SwiftUI.ForEach(models, id: \.id) { (model: OpenRouterModelMatch) in
            let isSelected = selectedModel.caseInsensitiveCompare(model.id) == .orderedSame

            Button {
                onSelect(model.id)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.id)
                            .font(DS.Fonts.ui(13))
                            .foregroundStyle(DS.Colors.ink)
                            .multilineTextAlignment(.leading)

                        if !model.supportsStructuredOutputs {
                            Text("Prompt-only fallback")
                                .font(DS.Fonts.ui(12))
                                .foregroundStyle(DS.Colors.textSecondary)
                        }

                        if model.supportsAudioInput {
                            Text("Audio input available")
                                .font(DS.Fonts.ui(12))
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }

                    Spacer(minLength: 12)

                    if isSelected {
                        Text("Selected")
                            .font(DS.Fonts.ui(12, .semibold))
                            .foregroundStyle(DS.Colors.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

#if DEBUG
@MainActor
private struct AIPostProcessingViewPreviewHost: View {
    @State private var appState: AppState
    private let cliAvailability: OllamaPostProcessingService.CLIAvailability

    init(cliAvailability: OllamaPostProcessingService.CLIAvailability) {
        self.cliAvailability = cliAvailability

        let appState = AppState()
        appState.settings.transcriptPostProcessingMode = .ollama
        appState.settings.ollamaBaseURL = OllamaPostProcessingService.defaultBaseURL
        appState.settings.ollamaModel = "gemma4:e4b"
        appState.settings.ollamaPostProcessingPrompt = Settings.recommendedTranscriptCleanupPrompt
        appState.settings.customVocabulary = ["Dictate Anywhere", "Parakeet", "Ollama"]
        _appState = State(initialValue: appState)
    }

    var body: some View {
        NavigationStack {
            AIPostProcessingView(
                initialOllamaCLIAvailability: cliAvailability,
                shouldAutoRefreshProviderAvailability: false
            )
        }
        .environment(appState)
        .frame(width: 760, height: 920)
    }
}

#Preview("Ollama Not Installed") {
    AIPostProcessingViewPreviewHost(
        cliAvailability: .init(executablePath: nil)
    )
}
#endif
