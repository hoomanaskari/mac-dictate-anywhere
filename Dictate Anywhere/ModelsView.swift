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
        let selectedModel = settings.parakeetModelChoice

        Form {
            Section("Active Engine") {
                LabeledContent("Engine") {
                    Text(TranscriptionEngineChoice.parakeet.displayName)
                }
            }

            Section {
                Picker("Variant", selection: Binding(
                    get: { settings.parakeetModelChoice },
                    set: { newValue in
                        downloadError = nil
                        settings.parakeetModelChoice = newValue
                        Task {
                            await appState.handleParakeetModelSelectionChange(userInitiated: true)
                        }
                    }
                )) {
                    ForEach(ParakeetModelChoice.allCases, id: \.self) { modelChoice in
                        Text(modelChoice.displayName).tag(modelChoice)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.status != .idle || appState.parakeetEngine.isDownloading)

                Text(selectedModel.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent("Type") {
                    Text("On-device speech-to-text")
                }

                LabeledContent("Languages") {
                    Text(selectedModel.isEnglishOnly ? "English only" : "25 European languages")
                }

                LabeledContent("Size") {
                    Text("~500 MB")
                }

                if let alternateModel = alternateInstalledModel(excluding: selectedModel) {
                    LabeledContent("Also Installed") {
                        Text(alternateModel.displayName)
                    }
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
                                await MainActor.run {
                                    applyParakeetSelection(userInitiated: true)
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
            } footer: {
                Text("Choose Multilingual for automatic language detection across 25 supported languages, or English Only for stronger English accuracy when you never dictate in other languages.")
            }

        }
        .formStyle(.grouped)
        .navigationTitle("Speech Model")
        .alert("Delete \(selectedModel.displayName) Model?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.parakeetEngine.deleteModel()
                    await MainActor.run { applyParakeetSelection(userInitiated: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the \(selectedModel.displayName.lowercased()) Parakeet model (~500 MB). You can download it again later.")
        }
    }

    private func applyParakeetSelection(userInitiated: Bool) {
        guard appState.status == .idle else { return }
        Task { await appState.handleParakeetModelSelectionChange(userInitiated: userInitiated) }
    }

    private func alternateInstalledModel(excluding selectedModel: ParakeetModelChoice) -> ParakeetModelChoice? {
        ParakeetModelChoice.allCases.first {
            $0 != selectedModel && appState.parakeetEngine.checkModelOnDisk(for: $0)
        }
    }
}
