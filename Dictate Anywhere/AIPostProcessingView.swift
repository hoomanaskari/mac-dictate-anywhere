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

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            if #available(macOS 26, *) {
                availableContent(settings: settings)
            } else {
                Section {
                    Label {
                        Text("Requires macOS 26 or later")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("AI Post Processing uses Apple Intelligence, which requires macOS 26 or later.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Post Processing")
    }

    @available(macOS 26, *)
    @ViewBuilder
    private func availableContent(settings: Settings) -> some View {
        let availability = AIPostProcessingService.availability

        switch availability {
        case .available:
            @Bindable var settings = settings

            Section {
                Toggle("Enable AI post-processing", isOn: $settings.aiPostProcessingEnabled)
            } footer: {
                Text("When enabled, transcribed text is processed by Apple Intelligence before pasting.")
            }

            if settings.aiPostProcessingEnabled {
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
                    Text("This prompt tells the AI how to transform your transcribed text. The transcribed text is appended after your prompt.")
                }

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
                    Text("These terms are applied only by AI post-processing to preserve product names, names, and domain-specific wording.")
                }
            }

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

    private func addVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !appState.settings.customVocabulary.contains(term) else { return }
        appState.settings.customVocabulary.append(term)
        newVocabularyTerm = ""
    }
}
