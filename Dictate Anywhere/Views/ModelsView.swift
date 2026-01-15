import SwiftUI

/// View for managing the speech recognition model
struct ModelsView: View {
    @Bindable var viewModel: DictationViewModel
    @State private var showDeleteConfirmation = false
    @State private var showErrorAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if viewModel.modelManager.isDownloading {
                    downloadingSection
                } else if viewModel.modelManager.isModelDownloaded {
                    modelDownloadedSection
                } else {
                    noModelSection
                }

                Spacer()

                // FluidAudio Attribution
                fluidAudioAttribution
            }
            .padding(24)
            .navigationTitle("Speech Model")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: { viewModel.state = .ready }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .opacity(viewModel.modelManager.isModelDownloaded ? 1 : 0)
                    .disabled(!viewModel.modelManager.isModelDownloaded)
                }
            }
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteModel()
            }
        } message: {
            Text("This will remove the downloaded model (~500 MB). You can download it again anytime.")
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                viewModel.modelManager.errorMessage = nil
            }
        } message: {
            Text(viewModel.modelManager.errorMessage ?? "An error occurred.")
        }
        .onChange(of: viewModel.modelManager.errorMessage) { _, newValue in
            showErrorAlert = newValue != nil
        }
    }

    // MARK: - Model Downloaded Section

    private var modelDownloadedSection: some View {
        VStack(spacing: 20) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            // Model info
            VStack(spacing: 8) {
                Text("Model Downloaded")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text("~500 MB")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            // Delete button
            Button(action: { showDeleteConfirmation = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete Model")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background {
                    Capsule()
                        .stroke(.red.opacity(0.5), lineWidth: 1)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    // MARK: - No Model Section

    private var noModelSection: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            // Info
            VStack(spacing: 8) {
                Text("Speech Model Required")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Download the speech recognition model to start using dictation.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("~500 MB")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // Download button
            Button(action: { downloadModel() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download Model")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background {
                    Capsule()
                        .fill(Color.accentColor)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    // MARK: - Downloading Section

    private var downloadingSection: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            // Title
            VStack(spacing: 8) {
                Text("Downloading Model")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text("~500 MB")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)

                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * viewModel.modelManager.downloadProgress, height: 6)
                    }
                }
                .frame(height: 6)

                Text("\(Int(viewModel.modelManager.downloadProgress * 100))%")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 60)
        }
    }

    // MARK: - FluidAudio Attribution

    private var fluidAudioAttribution: some View {
        VStack(spacing: 12) {
            Divider()
                .background(Color.white.opacity(0.1))

            VStack(spacing: 8) {
                Text("Powered by FluidAudio")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Parakeet ASR · On-device processing")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))

                Button(action: {
                    if let url = URL(string: "https://github.com/FluidInference/FluidAudio") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text("View on GitHub")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.blue.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func downloadModel() {
        Task {
            do {
                let models = try await viewModel.modelManager.downloadAndLoadModels()
                // Reinitialize transcription service after download
                try await viewModel.transcriptionService.initialize(with: models)
                viewModel.transcriptionService.setLanguage(SettingsManager.shared.selectedLanguage)
                viewModel.keyboardMonitor.startMonitoring()
                viewModel.state = .ready
            } catch {
                // Error is handled by ModelManager and shown via alert
            }
        }
    }

    private func deleteModel() {
        // Clean up transcription service first
        viewModel.transcriptionService.cleanup()

        // Actually delete model files from disk
        do {
            try viewModel.modelManager.deleteModelFiles()
        } catch {
            viewModel.modelManager.errorMessage = "Failed to delete model: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    ModelsView(viewModel: DictationViewModel())
}
