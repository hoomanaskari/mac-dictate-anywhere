import SwiftUI

/// Main view for managing WhisperKit models
struct ModelsView: View {
    @Bindable var viewModel: DictationViewModel
    @State private var showDeleteConfirmation = false

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
            ScrollView {
                VStack(spacing: 24) {
                    // Current Model Section
                    if let currentModel = viewModel.modelManager.currentModel {
                        currentModelSection(currentModel)
                    } else {
                        noModelSection
                    }

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 8)

                    // Available Models Section
                    availableModelsSection
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteCurrentModel()
            }
        } message: {
            Text("This will remove the downloaded model. You'll need to download a model again to use transcription.")
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

            Spacer()

            Text("Models")
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

    // MARK: - Current Model Section

    private func currentModelSection(_ model: WhisperModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            CurrentModelCard(model: model) {
                showDeleteConfirmation = true
            }
        }
    }

    // MARK: - No Model Section

    private var noModelSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No Model Downloaded")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)

            Text("Select a model below to get started")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Available Models Section

    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            // Group models by category
            VStack(spacing: 10) {
                ForEach(WhisperModel.allModels.filter { $0.id != viewModel.modelManager.currentModel?.id }) { model in
                    ModelCardView(
                        model: model,
                        isCurrent: false,
                        isDownloading: viewModel.modelManager.downloadingModelId == model.id,
                        downloadProgress: viewModel.modelManager.downloadingModelId == model.id
                            ? viewModel.modelManager.downloadProgress : 0,
                        onSelect: {
                            selectModel(model)
                        },
                        onDelete: nil
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func selectModel(_ model: WhisperModel) {
        Task {
            do {
                try await viewModel.modelManager.selectModel(model)
                // Re-initialize transcription service with new model
                await viewModel.reinitializeWithNewModel(model)
            } catch {
                // Error is handled by ModelManager
            }
        }
    }

    private func deleteCurrentModel() {
        do {
            try viewModel.modelManager.deleteCurrentModel()
            // Go back to download state since no model is available
            viewModel.state = .downloadingModel
        } catch {
            // Error handled by ModelManager
        }
    }
}

// MARK: - Preview

#Preview {
    ModelsView(viewModel: DictationViewModel())
}
