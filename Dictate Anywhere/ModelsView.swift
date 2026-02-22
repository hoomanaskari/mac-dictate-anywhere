//
//  ModelsView.swift
//  Dictate Anywhere
//
//  Model management: download, delete, engine selector.
//

import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var appState

    @State private var showDeleteConfirm = false
    @State private var downloadError: String?

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            // Engine Picker
            Section("Active Engine") {
                Picker("Engine", selection: Binding(
                    get: { settings.engineChoice },
                    set: { choice in
                        applyEngineChoice(choice, userInitiated: true)
                    }
                )) {
                    ForEach(TranscriptionEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appState.status != .idle)
            }

            // Parakeet
            Section {
                LabeledContent("Type") {
                    Text("On-device speech-to-text")
                }

                LabeledContent("Size") {
                    Text("~500 MB")
                }

                if appState.parakeetEngine.isModelDownloaded {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Ready")
                        }
                    }

                    Button("Delete Model", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .controlSize(.small)
                    .disabled(appState.status != .idle)
                } else if appState.parakeetEngine.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: appState.parakeetEngine.downloadProgress)
                        Text("Downloading... \(Int(appState.parakeetEngine.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Status") {
                        Text("Not downloaded")
                            .foregroundStyle(.secondary)
                    }

                    Button("Download Model") {
                        downloadError = nil
                        Task {
                            do {
                                try await appState.parakeetEngine.downloadModel()
                                // Auto-switch to Parakeet after successful download
                                await MainActor.run {
                                    applyEngineChoice(.parakeet, userInitiated: false)
                                }
                            } catch {
                                downloadError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appState.status != .idle)
                }

                if let error = downloadError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Parakeet (FluidAudio)")
            }

            // Apple Speech
            Section {
                LabeledContent("Type") {
                    Text("Built-in on-device recognition")
                }

                LabeledContent("Download") {
                    Text("None required")
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Available")
                    }
                }
            } header: {
                Text("Apple Speech")
            } footer: {
                Text("Uses Apple's built-in speech recognition. Language support depends on your system settings.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speech Model")
        .alert("Delete Model?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.parakeetEngine.deleteModel()
                    // Fall back to Apple Speech after deletion
                    await MainActor.run {
                        applyEngineChoice(.appleSpeech, userInitiated: false)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the Parakeet model (~500 MB). You can download it again later.")
        }
    }

    private func applyEngineChoice(_ choice: TranscriptionEngineChoice, userInitiated: Bool) {
        guard appState.status == .idle else { return }
        appState.settings.engineChoice = choice
        appState.settings.userHasChosenEngine = userInitiated
        appState.isPreparingEngine = true
        Task { await appState.prepareActiveEngine() }
    }
}
