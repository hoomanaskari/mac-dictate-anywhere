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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcript Processing")
        .task(id: ollamaTaskID(settings: settings)) {
            ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
            await refreshOllamaAvailabilityIfNeeded(settings: settings)
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
                ollamaStatusView()
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
            Text("Optional. Default cleanup is punctuation, capitalization, grammar, and formatting, but this prompt can request extra safe cleanup such as removing filler words or normalizing domain terms.")
        }

        vocabularySection(
            settings: settings,
            footer: "These terms are sent to Ollama to preserve product names, names, and domain-specific wording during post-processing."
        )
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
    private func ollamaStatusView() -> some View {
        if isCheckingOllama {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Ollama...")
                    .foregroundStyle(.secondary)
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

    private func ollamaTaskID(settings: Settings) -> String {
        [
            settings.transcriptPostProcessingMode.rawValue,
            settings.ollamaBaseURL,
            settings.ollamaModel,
            String(appState.ollamaModelActionsRevision),
        ].joined(separator: "|")
    }

    private func refreshOllamaAvailabilityIfNeeded(settings: Settings) async {
        await refreshOllamaAvailability(settings: settings, debounce: true)
    }

    private func refreshOllamaAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .ollama else {
            isCheckingOllama = false
            ollamaAvailability = nil
            ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
            ollamaStatusMessage = nil
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
