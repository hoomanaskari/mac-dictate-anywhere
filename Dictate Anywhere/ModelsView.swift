//
//  ModelsView.swift
//  Dictate Anywhere
//
//  Model management: download, delete, engine selector.
//

import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var appState

    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var downloadError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                enginePicker
                parakeetSection
                appleSpeechSection
            }
            .padding(24)
        }
        .navigationTitle("Speech Model")
    }

    // MARK: - Engine Picker

    private var enginePicker: some View {
        GroupBox("Active Engine") {
            @Bindable var settings = appState.settings
            Picker("Engine", selection: $settings.engineChoice) {
                ForEach(TranscriptionEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
        }
    }

    // MARK: - Parakeet Section

    private var parakeetSection: some View {
        GroupBox("Parakeet (FluidAudio)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.blue)
                    Text("On-device speech-to-text")
                        .font(.subheadline)
                    Spacer()
                    Text("~500 MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.parakeetEngine.isModelDownloaded {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Model downloaded and ready")
                            .font(.subheadline)

                        Spacer()

                        Button("Delete Model") {
                            showDeleteConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                } else if appState.parakeetEngine.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: appState.parakeetEngine.downloadProgress)
                        Text("Downloading... \(Int(appState.parakeetEngine.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Model not downloaded")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

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
                }

                if let error = downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
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

    // MARK: - Apple Speech Section

    private var appleSpeechSection: some View {
        GroupBox("Apple Speech") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "apple.logo")
                        .foregroundStyle(.primary)
                    Text("Built-in on-device recognition")
                        .font(.subheadline)
                    Spacer()
                    Text("No download")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Available on macOS 15+")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Uses Apple's built-in speech recognition. No additional download needed. Language support depends on your system settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
    }
}
