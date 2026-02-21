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
            if let warning = modelWarning {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title)
                                .font(.headline)
                            Text(warning.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Engine Picker
            Section("Active Engine") {
                Picker("Engine", selection: $settings.engineChoice) {
                    ForEach(TranscriptionEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
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
                            } catch {
                                downloadError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
        .onChange(of: appState.settings.engineChoice) { _, _ in
            Task { await appState.prepareActiveEngine() }
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.parakeetEngine.deleteModel()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the Parakeet model (~500 MB). You can download it again later.")
        }
    }

    private var modelWarning: (title: String, subtitle: String)? {
        if case .error(let message) = appState.status {
            return (message, "Try again or check settings")
        }

        if !appState.activeEngine.isReady {
            return ("Not Ready", "Download or configure the speech model")
        }

        return nil
    }
}
