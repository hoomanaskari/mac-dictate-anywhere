//
//  ModelsView.swift
//  Dictate Anywhere
//
//  "Speech Model" page: download, delete, engine selector.
//

import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var appState

    @State private var showDeleteConfirm = false
    @State private var downloadError: String?

    var body: some View {
        @Bindable var settings = appState.settings
        let selectedModel = settings.parakeetModelChoice

        DSPage {
            DSSectionHeader(
                title: "Speech Model",
                subtitle: "Everything runs on your Mac — your voice never leaves this device."
            )

            DSSection(overline: "Active Engine") {
                DSInfoRow(label: "Engine") {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.textSecondary)
                        Text(TranscriptionEngineChoice.parakeet.displayName)
                            .font(DS.Fonts.ui(13.5))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }

            DSSection(overline: "FluidAudio") {
                DSDetailRow(label: "Variant", caption: selectedModel.detail) {
                    DSDropdown(
                        selection: Binding(
                            get: { settings.parakeetModelChoice },
                            set: { newValue in
                                downloadError = nil
                                settings.parakeetModelChoice = newValue
                                Task {
                                    await appState.parakeetEngine.recheckModelOnDisk(for: newValue)
                                    await appState.handleParakeetModelSelectionChange(userInitiated: true)
                                }
                            }
                        ),
                        options: Array(ParakeetModelChoice.allCases),
                        title: \.displayName,
                        isEnabled: appState.status == .idle && !appState.parakeetEngine.isDownloading
                    )
                }
                DSDivider()
                DSInfoRow(
                    label: "Type",
                    value: selectedModel.usesTrueStreaming
                        ? "On-device true streaming speech-to-text"
                        : "On-device speech-to-text"
                )
                DSDivider()
                DSInfoRow(label: "Languages", value: selectedModel.languageSummary)
                DSDivider()
                DSInfoRow(label: "Size", value: selectedModel.sizeSummary)
                if let alternateModel = alternateInstalledModel(excluding: selectedModel) {
                    DSDivider()
                    DSInfoRow(label: "Also installed", value: alternateModel.displayName)
                }
                if selectedModel.supportsEndOfUtterance {
                    DSDivider()
                    DSInfoRow(label: "Stop hands-free dictation after speech ends") {
                        Toggle("", isOn: $settings.autoStopAfterSpeechEndsEnabled)
                            .labelsHidden()
                            .toggleStyle(.dsSwitch)
                    }
                }
                DSDivider()
                statusRow
                if appState.parakeetEngine.isModelDownloaded {
                    DSDivider()
                    DSInfoRow(
                        label: "Remove the downloaded model files from this Mac.",
                        labelColor: DS.Colors.textSecondary,
                        labelWeight: .regular
                    ) {
                        Button("Delete Model…") {
                            showDeleteConfirm = true
                        }
                        .buttonStyle(.dsDestructive)
                        .disabled(appState.status != .idle)
                    }
                }
                if let error = downloadError {
                    DSDivider()
                    DSInfoRow(
                        label: error,
                        labelColor: DS.Colors.destructive,
                        labelWeight: .regular
                    ) {
                        EmptyView()
                    }
                }
            }

            DSHint(text: selectedModel.speechModelFooter)
        }
        .alert("Delete \(selectedModel.displayName)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.parakeetEngine.deleteModel()
                    await MainActor.run { applyParakeetSelection(userInitiated: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the \(selectedModel.displayName.lowercased()) speech model (\(selectedModel.sizeSummary)). You can download it again later.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if appState.parakeetEngine.isModelDownloaded {
            DSInfoRow(label: "Status") {
                DSStatusPill(text: "Ready")
            }
        } else if appState.parakeetEngine.isDownloading {
            let progress = appState.parakeetEngine.downloadProgress
            DSInfoRow(label: "Downloading… \(Int(progress * 100))%") {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Colors.accent)
                    .frame(width: 180)
            }
        } else {
            DSInfoRow(label: "Status") {
                HStack(spacing: 10) {
                    DSStatusPill(
                        text: "Not downloaded",
                        dotColor: DS.Colors.textSecondary,
                        textColor: DS.Colors.textSecondary,
                        fill: DS.Colors.bgInset
                    )
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
                    .buttonStyle(.dsPrimary)
                    .disabled(appState.status != .idle)
                }
            }
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
