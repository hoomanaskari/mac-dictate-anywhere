import SwiftUI

/// View for managing the speech recognition model
struct ModelsView: View {
    @Bindable var viewModel: DictationViewModel
    @State private var showDeleteConfirmation = false
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()
                .background(Color.white.opacity(0.1))

            // Content
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
            }
            .padding(24)
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteModel()
            }
        } message: {
            Text("This will remove the downloaded model (\(WhisperModel.defaultModel.size)). You can download it again anytime.")
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

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { viewModel.state = .ready }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .opacity(viewModel.modelManager.isModelDownloaded ? 1 : 0)
            .disabled(!viewModel.modelManager.isModelDownloaded)

            Spacer()

            Text("Speech Model")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            // Spacer to balance the back button
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .opacity(0)
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
                Text(WhisperModel.defaultModel.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text(WhisperModel.defaultModel.size)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                Text(WhisperModel.defaultModel.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
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
                .foregroundStyle(.blue)

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

                Text(WhisperModel.defaultModel.size)
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
                        .fill(.blue)
                }
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
                .foregroundStyle(.blue)

            // Title
            VStack(spacing: 8) {
                Text("Downloading Model")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text(WhisperModel.defaultModel.displayName)
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
                            .fill(.blue)
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

    // MARK: - Actions

    private func downloadModel() {
        Task {
            do {
                try await viewModel.modelManager.downloadModel()
                // Reinitialize transcription service after download
                await viewModel.initializeAfterDownload()
            } catch {
                // Error is handled by ModelManager and shown via alert
            }
        }
    }

    private func deleteModel() {
        do {
            // Clean up transcription service first
            viewModel.transcriptionService.cleanup()
            try viewModel.modelManager.deleteModel()
        } catch {
            // Error handled by ModelManager
        }
    }
}

// MARK: - Preview

#Preview {
    ModelsView(viewModel: DictationViewModel())
}
