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
            await refreshOllamaAvailabilityIfNeeded(settings: settings)
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
                TextField(
                    "",
                    text: $settings.aiPostProcessingPrompt,
                    prompt: Text("Enter your prompt, e.g. \"Break into sentences, fix grammar, and remove filler words.\""),
                    axis: .vertical
                )
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .lineLimit(3...)
                .frame(minHeight: 80, alignment: .topLeading)
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

                            Button {
                                settings.ollamaModel = model
                            } label: {
                                Text(model)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } header: {
            Text("Ollama")
        } footer: {
            Text("Runs transcript cleanup through your local Ollama server. Use the server base URL and an installed model name. Larger models are noticeably better at following cleanup instructions and vocabulary normalization.")
        }

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
            TextField(
                "",
                text: Binding(
                    get: { settings.ollamaPostProcessingPrompt },
                    set: { settings.ollamaPostProcessingPrompt = $0 }
                ),
                prompt: Text("Optional: add style or cleanup instructions for Ollama."),
                axis: .vertical
            )
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .lineLimit(3...)
            .frame(minHeight: 80, alignment: .topLeading)
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
        ].joined(separator: "|")
    }

    private func refreshOllamaAvailabilityIfNeeded(settings: Settings) async {
        await refreshOllamaAvailability(settings: settings, debounce: true)
    }

    private func refreshOllamaAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .ollama else {
            isCheckingOllama = false
            ollamaAvailability = nil
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
