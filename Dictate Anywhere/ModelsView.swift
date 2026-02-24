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
        Form {
            Section("Active Engine") {
                LabeledContent("Engine") {
                    Text(TranscriptionEngineChoice.parakeet.displayName)
                }
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
                                    applyParakeetSelection(userInitiated: false)
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

        }
        .formStyle(.grouped)
        .navigationTitle("Speech Model")
        .alert("Delete Model?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.parakeetEngine.deleteModel()
                    await MainActor.run { applyParakeetSelection(userInitiated: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the Parakeet model (~500 MB). You can download it again later.")
        }
    }

    private func applyParakeetSelection(userInitiated: Bool) {
        guard appState.status == .idle else { return }
        appState.settings.engineChoice = .parakeet
        appState.settings.userHasChosenEngine = userInitiated
        appState.isPreparingEngine = true
        Task { await appState.prepareActiveEngine() }
    }
}
