//
//  AIPostProcessingView.swift
//  Dictate Anywhere
//
//  AI post-processing settings page.
//

import SwiftUI
import FoundationModels

struct AIPostProcessingView: View {
    @Environment(AppState.self) private var appState
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

        Form {
            Section {
                Picker("Transcript Processing", selection: $settings.transcriptPostProcessingMode) {
                    ForEach(TranscriptPostProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Choose how the final transcript is cleaned up before it is pasted.")
            }

            switch settings.transcriptPostProcessingMode {
            case .none:
                Section {
                    Text("The raw Parakeet transcript will be pasted as-is, after filler word removal if enabled.")
                        .foregroundStyle(.secondary)
                }
            case .fluidAudioVocabulary:
                fluidAudioVocabularyContent(settings: settings)
            case .appleIntelligence:
                if #available(macOS 26, *) {
                    appleIntelligenceContent(settings: settings)
                } else {
                    Section {
                        Label {
                            Text("Requires macOS 26 or later")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Apple Intelligence transcript processing requires macOS 26 or later.")
                    }
                }
            case .ollama:
                ollamaContent(settings: settings)
            case .openRouter:
                openRouterContent(settings: settings)
            case .openAICompatible:
                openAICompatibleContent(settings: settings)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcript Processing")
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

    @ViewBuilder
    private func fluidAudioVocabularyContent(settings: Settings) -> some View {
        vocabularySection(
            settings: settings,
            footer: "These terms are applied by FluidAudio's vocabulary rescoring on the final transcript only. Keep the list short and domain-specific for best precision."
        )
    }

    @available(macOS 26, *)
    @ViewBuilder
    private func appleIntelligenceContent(settings: Settings) -> some View {
        let availability = AIPostProcessingService.availability
        switch availability {
        case .available:
            @Bindable var settings = settings

            Section {
                SettingsMultilineTextArea(
                    text: $settings.aiPostProcessingPrompt,
                    placeholder: "Enter your prompt, e.g. \"Break into sentences, fix grammar, and remove filler words.\""
                )
                .labelsHidden()
            } header: {
                Text("Prompt")
            } footer: {
                Text("This prompt tells Apple Intelligence how to transform your transcribed text. The transcript is appended after your prompt.")
            }

            vocabularySection(
                settings: settings,
                footer: "These terms are applied only by Apple Intelligence post-processing to preserve product names, names, and domain-specific wording."
            )

        case .unavailable(.deviceNotEligible):
            Section {
                Label {
                    Text("Your Mac doesn't support Apple Intelligence")
                } icon: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("AI Post Processing requires a Mac that supports Apple Intelligence.")
            }

        case .unavailable(.appleIntelligenceNotEnabled):
            Section {
                Label {
                    Text("Apple Intelligence is not enabled")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Open Apple Intelligence Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Enable Apple Intelligence in System Settings to use AI Post Processing.")
            }

        case .unavailable(.modelNotReady):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Intelligence model is downloading...")
                        ProgressView()
                            .controlSize(.small)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
            } footer: {
                Text("The on-device model is being prepared. This may take a few minutes.")
            }

        case .unavailable(_):
            Section {
                Label {
                    Text("Apple Intelligence is currently unavailable")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Try again later.")
            }
        }
    }

    @ViewBuilder
    private func ollamaContent(settings: Settings) -> some View {
        if !ollamaCLIAvailability.isAvailable {
            ollamaInstallCard(settings: settings)
        }

        Section {
            TextField(
                "Server URL",
                text: Binding(
                    get: { settings.ollamaBaseURL },
                    set: { settings.ollamaBaseURL = $0 }
                ),
                prompt: Text(OllamaPostProcessingService.defaultBaseURL)
            )

            TextField(
                "Model",
                text: Binding(
                    get: { settings.ollamaModel },
                    set: { settings.ollamaModel = $0 }
                ),
                prompt: Text("llama3.2")
            )

            HStack(alignment: .top, spacing: 12) {
                ollamaStatusView(settings: settings)
                Spacer(minLength: 12)
                Button(isCheckingOllama ? "Checking..." : "Refresh Models") {
                    Task {
                        await refreshOllamaAvailability(settings: settings, debounce: false)
                    }
                }
                .disabled(isCheckingOllama)
            }

            if let availability = ollamaAvailability, !availability.installedModels.isEmpty {
                let installedModels = availability.installedModels

                VStack(alignment: .leading, spacing: 8) {
                    Text("Installed Models")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(installedModels, id: \.self) { (model: String) in
                            let isSelected = settings.ollamaModel == model
                            let isDeleting = appState.ollamaDeletingModel == model
                            let canDelete = ollamaCanDeleteModels
                            let isBusy = appState.ollamaDownloadState != nil || appState.ollamaDeletingModel != nil

                            HStack(spacing: 6) {
                                Button {
                                    settings.ollamaModel = model
                                } label: {
                                    Text(model)
                                        .font(.caption)
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .disabled(isDeleting)

                                if canDelete {
                                    Button {
                                        ollamaPendingDeletionModel = model
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        } header: {
            Text("Ollama")
        } footer: {
            Text("Runs transcript cleanup through your local Ollama server. Use the server base URL and an installed model name. Larger models are noticeably better at following cleanup instructions and vocabulary normalization.")
        }

        ollamaSuggestedModelsSection(settings: settings)

        if let capability = ollamaAvailability?.selectedModelReasoningCapability,
           capability.supportsReasoning {
            Section {
                Picker(
                    "Reasoning",
                    selection: Binding(
                        get: { settings.ollamaReasoningSetting.sanitized(for: capability) },
                        set: { settings.ollamaReasoningSetting = $0.sanitized(for: capability) }
                    )
                ) {
                    ForEach(OllamaReasoningSetting.options(for: capability), id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(ollamaReasoningFooter(for: capability))
            }
        }

        Section {
            SettingsMultilineTextArea(
                text: Binding(
                    get: { settings.ollamaPostProcessingPrompt },
                    set: { settings.ollamaPostProcessingPrompt = $0 }
                ),
                placeholder: "Optional: add style or cleanup instructions for Ollama."
            )
            .labelsHidden()
        } header: {
            Text("Prompt")
        } footer: {
            Text("Pre-filled with the recommended cleanup prompt. Customize it if you want different safe cleanup behavior for Ollama.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to Ollama to preserve product names, names, and domain-specific wording during post-processing."
        )
    }

    @ViewBuilder
    private func openRouterContent(settings: Settings) -> some View {
        Section {
            SecureField(
                "API Key",
                text: Binding(
                    get: { settings.openRouterAPIKey },
                    set: { settings.openRouterAPIKey = $0 }
                ),
                prompt: Text("Paste OpenRouter API key")
            )

            TextField(
                "API Key Environment Variable (Optional)",
                text: Binding(
                    get: { settings.openRouterAPIKeyEnvironmentVariable },
                    set: { settings.openRouterAPIKeyEnvironmentVariable = $0 }
                ),
                prompt: Text(OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable)
            )

            TextField(
                "Model",
                text: Binding(
                    get: { settings.openRouterModel },
                    set: { settings.openRouterModel = $0 }
                ),
                prompt: Text("openai/gpt-5-mini")
            )

            HStack(alignment: .top, spacing: 12) {
                openRouterStatusView(settings: settings)
                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    Button(isCheckingOpenRouter ? "Checking..." : "Refresh Models") {
                        Task {
                            await refreshOpenRouterAvailability(settings: settings, debounce: false)
                        }
                    }
                    .disabled(isCheckingOpenRouter)

                    Button("Browse Models") {
                        guard let url = URL(string: "https://openrouter.ai/models") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !settings.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear Stored Key", role: .destructive) {
                            settings.openRouterAPIKey = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("OpenRouter")
        } footer: {
            Text("Runs transcript cleanup through OpenRouter's cloud API. Paste a key directly to store it in Keychain, or leave the API key field blank and use the optional environment variable setting instead.")
        }

        if let availability = openRouterAvailability {
            openRouterModelSearchSection(settings: settings, availability: availability)
        }

        Section {
            SettingsMultilineTextArea(
                text: Binding(
                    get: { settings.openRouterPostProcessingPrompt },
                    set: { settings.openRouterPostProcessingPrompt = $0 }
                ),
                placeholder: "Optional: add style or cleanup instructions for OpenRouter."
            )
            .labelsHidden()
        } header: {
            Text("Prompt")
        } footer: {
            Text("Pre-filled with the recommended cleanup prompt. Customize it if you want different safe cleanup behavior for OpenRouter.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to OpenRouter to preserve product names, names, and domain-specific wording during post-processing."
        )
    }

    @ViewBuilder
    private func openAICompatibleContent(settings: Settings) -> some View {
        Section {
            TextField(
                "Server URL",
                text: Binding(
                    get: { settings.openAICompatibleBaseURL },
                    set: { settings.openAICompatibleBaseURL = $0 }
                ),
                prompt: Text(OpenAICompatiblePostProcessingService.defaultBaseURL)
            )

            SecureField(
                "API Key (Optional)",
                text: Binding(
                    get: { settings.openAICompatibleAPIKey },
                    set: { settings.openAICompatibleAPIKey = $0 }
                ),
                prompt: Text("Leave blank for local servers without auth")
            )

            TextField(
                "Model",
                text: Binding(
                    get: { settings.openAICompatibleModel },
                    set: { settings.openAICompatibleModel = $0 }
                ),
                prompt: Text("local-model")
            )

            HStack(alignment: .top, spacing: 12) {
                openAICompatibleStatusView(settings: settings)
                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    Button(isCheckingOpenAICompatible ? "Checking..." : "Refresh Models") {
                        Task {
                            await refreshOpenAICompatibleAvailability(settings: settings, debounce: false)
                        }
                    }
                    .disabled(isCheckingOpenAICompatible)

                    if !settings.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Clear Stored Key", role: .destructive) {
                            settings.openAICompatibleAPIKey = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let availability = openAICompatibleAvailability, !availability.models.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Models")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(availability.models, id: \.self) { model in
                            let isSelected = settings.openAICompatibleModel.caseInsensitiveCompare(model) == .orderedSame
                            Button {
                                settings.openAICompatibleModel = model
                            } label: {
                                Text(model)
                                    .font(.caption)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        } header: {
            Text("OpenAI Compatible")
        } footer: {
            Text("Runs transcript cleanup through a local or self-hosted OpenAI-compatible chat completions server, such as LM Studio, llama.cpp, vLLM, or LocalAI. Use the base URL and model name reported by that server.")
        }

        Section {
            SettingsMultilineTextArea(
                text: Binding(
                    get: { settings.openAICompatiblePostProcessingPrompt },
                    set: { settings.openAICompatiblePostProcessingPrompt = $0 }
                ),
                placeholder: "Optional: add style or cleanup instructions for this server."
            )
            .labelsHidden()
        } header: {
            Text("Prompt")
        } footer: {
            Text("Pre-filled with the recommended cleanup prompt. Customize it if you want different safe cleanup behavior for this server.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to the OpenAI-compatible server to preserve product names, names, and domain-specific wording during post-processing."
        )
    }

    @ViewBuilder
    private func ollamaInstallCard(settings: Settings) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shippingbox.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Install Ollama for local transcript cleanup")
                            .font(.headline)

                        Text("Ollama lets Dictate Anywhere clean up transcripts with a local language model on your Mac. It can improve punctuation, grammar, formatting, and term normalization without relying on a hosted API.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Run post-processing on your machine", systemImage: "lock.shield")
                    Label("Use local models for stronger cleanup and normalization", systemImage: "sparkles.rectangle.stack")
                    Label("Download recommended models directly from this app once installed", systemImage: "arrow.down.circle")
                }
                .font(.subheadline)

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        guard let url = URL(string: "https://ollama.com/download") else { return }
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Download Ollama", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Text("You can still connect to a remote Ollama server by entering its URL below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Ollama is optional. Install it if you want fully local AI transcript cleanup and in-app model downloads.")
        }
    }

    @ViewBuilder
    private func ollamaSuggestedModelsSection(settings: Settings) -> some View {
        Section {
            ForEach(OllamaPostProcessingService.suggestedModels) { suggestion in
                ollamaSuggestedModelRow(suggestion, settings: settings)
            }

            if let error = appState.ollamaModelActionError {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Suggested Models")
        } footer: {
            Text(ollamaSuggestedModelsFooter(settings: settings))
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

        VStack(alignment: .leading, spacing: 10) {
            Text(suggestion.name)
                .font(.body.weight(.medium))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            FlowLayout(spacing: 6) {
                ollamaBadge(
                    text: suggestion.badge,
                    foreground: .accentColor,
                    background: Color.accentColor.opacity(0.14)
                )

                if isInstalled {
                    ollamaBadge(
                        text: "Installed",
                        foreground: .green,
                        background: Color.green.opacity(0.14)
                    )
                }

                if isSelected {
                    ollamaBadge(
                        text: "Selected",
                        foreground: .primary,
                        background: Color.secondary.opacity(0.14)
                    )
                }

                if let downloadSizeLabel {
                    ollamaBadge(
                        text: downloadSizeLabel,
                        foreground: .secondary,
                        background: Color.secondary.opacity(0.12)
                    )
                }

                if let parameterSizeLabel {
                    ollamaBadge(
                        text: parameterSizeLabel,
                        foreground: .secondary,
                        background: Color.secondary.opacity(0.12)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(suggestion.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer(minLength: 0)

                if isInstalled {
                    HStack(spacing: 8) {
                        if isSelected {
                            Button("Selected") {
                                settings.ollamaModel = resolvedInstalledModel ?? suggestion.name
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(true)
                        } else {
                            Button("Use") {
                                settings.ollamaModel = resolvedInstalledModel ?? suggestion.name
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isDownloading || isDeleting)
                        }

                        if canDelete {
                            Button(isDeleting ? "Deleting..." : "Delete", role: .destructive) {
                                ollamaPendingDeletionModel = resolvedInstalledModel ?? suggestion.name
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isDeleting || isDownloading || isAnotherDownloadRunning || isAnotherDeleteRunning)
                        }
                    }
                } else if canDownload {
                    if isDownloading {
                        Button("Downloading...") {}
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(true)
                    } else {
                        Button("Download") {
                            Task {
                                await appState.startOllamaModelDownload(suggestion.name)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isAnotherDownloadRunning || isAnotherDeleteRunning || isCheckingOllama)
                    }
                } else {
                    Button("Use Name") {
                        settings.ollamaModel = suggestion.name
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAnotherDownloadRunning || isAnotherDeleteRunning)
                }
            }

            if let downloadState = appState.ollamaDownloadState, downloadState.model == suggestion.name {
                VStack(alignment: .leading, spacing: 6) {
                    if let fractionCompleted = downloadState.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    Text(ollamaDownloadCaption(downloadState))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func vocabularySection(settings: Settings, footer: String) -> some View {
        @Bindable var settings = settings

        Section {
            FlowLayout(spacing: 6) {
                ForEach(settings.customVocabulary, id: \.self) { term in
                    HStack(spacing: 4) {
                        Text(term)
                            .font(.caption)
                        Button {
                            settings.customVocabulary.removeAll { $0 == term }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(Capsule())
                }
            }

            HStack {
                TextField("", text: $newVocabularyTerm, prompt: Text("Add word or phrase..."))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addVocabularyTerm() }

                Button("Add") { addVocabularyTerm() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(newVocabularyTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .labelsHidden()
        } header: {
            Text("Custom Vocabulary")
        } footer: {
            Text(footer)
        }
    }

    private func addVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !appState.settings.customVocabulary.contains(term) else { return }
        appState.settings.customVocabulary.append(term)
        newVocabularyTerm = ""
    }

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

        return Section {
            if matchingModels.isEmpty {
                Text(openRouterModelSearchEmptyState(settings: settings))
                    .foregroundStyle(.secondary)
            } else {
                OpenRouterModelMatchesView(
                    models: matchingModels,
                    selectedModel: currentOpenRouterModel(settings: settings)
                ) { modelID in
                    settings.openRouterModel = modelID
                }
            }
        } header: {
            Text("Model Search")
        } footer: {
            Text(openRouterModelSearchFooter(availability: availability))
        }
    }

    @ViewBuilder
    private func ollamaBadge(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
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

    @ViewBuilder
    private func ollamaStatusView(settings: Settings) -> some View {
        if isCheckingOllama {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Ollama...")
                    .foregroundStyle(.secondary)
            }
        } else if !ollamaCLIAvailability.isAvailable &&
                    OllamaPostProcessingService.isLocalServer(baseURL: settings.ollamaBaseURL) {
            Label {
                Text("Ollama is not installed on this Mac yet. Install it to run transcript cleanup locally, or enter a remote Ollama server URL.")
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
            }
        } else if let message = ollamaStatusMessage {
            Label {
                Text(message)
            } icon: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
        } else if let availability = ollamaAvailability {
            if availability.installedModels.isEmpty {
                Label {
                    Text("Connected, but no Ollama models are installed yet.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if availability.selectedModel.isEmpty {
                Label {
                    Text("Connected. Choose an installed model below or enter one manually.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            } else if availability.selectedModelIsInstalled {
                Label {
                    Text("Connected. \(availability.resolvedSelectedModel ?? availability.selectedModel) is available.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            } else {
                Label {
                    Text("Connected, but \(availability.selectedModel) is not installed on this Ollama server.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Label {
                Text("Enter your Ollama server URL to check connectivity.")
            } icon: {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }
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
                Text("Checking OpenRouter...")
                    .foregroundStyle(.secondary)
            }
        } else if let message = openRouterStatusMessage {
            Label {
                Text(message)
            } icon: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
        } else if case .missing = apiKeyStatus.source {
            Label {
                Text("No OpenRouter API key is configured yet. Paste one above or set \(apiKeyStatus.environmentVariableName) in the app environment.")
            } icon: {
                Image(systemName: "key.slash")
                    .foregroundStyle(.orange)
            }
        } else if let resolvedModel {
            Label {
                Text(
                    openRouterAvailableModelStatusMessage(
                        selectedModel: selectedModel,
                        resolvedModel: resolvedModel,
                        apiKeyStatus: apiKeyStatus
                    )
                )
            } icon: {
                Image(systemName: resolvedModel.supportsStructuredOutputs ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(resolvedModel.supportsStructuredOutputs ? .green : .orange)
            }
        } else if !selectedModel.isEmpty {
            Label {
                Text("\(openRouterCredentialSourceMessage(apiKeyStatus)) \(selectedModel) was not found in the latest OpenRouter model refresh.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } else if openRouterAvailability != nil {
            Label {
                Text("\(openRouterCredentialSourceMessage(apiKeyStatus)) Enter a model id above or search the fetched catalog below.")
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } else {
            Label {
                Text("Refresh models to validate your OpenRouter setup and search the available catalog.")
            } icon: {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
            }
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
                Text("Checking server...")
                    .foregroundStyle(.secondary)
            }
        } else if let message = openAICompatibleStatusMessage {
            Label {
                Text(message)
            } icon: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
        } else if let availability = openAICompatibleAvailability {
            if availability.models.isEmpty {
                Label {
                    Text("Connected, but the server did not report any models.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if selectedModel.isEmpty {
                Label {
                    Text("Connected. Choose a model below or enter one manually.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            } else if availability.selectedModelIsAvailable {
                Label {
                    Text("Connected. \(selectedModel) is available.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            } else {
                Label {
                    Text("Connected, but \(selectedModel) was not listed by this server.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Label {
                Text("Enter a server URL and refresh models to check connectivity.")
            } icon: {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
            }
        }
    }

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
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        if !model.supportsStructuredOutputs {
                            Text("Prompt-only fallback")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.supportsAudioInput {
                            Text("Audio input available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 12)

                    if isSelected {
                        Text("Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
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
        appState.settings.ollamaModel = "mistral-small3.2:latest"
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
