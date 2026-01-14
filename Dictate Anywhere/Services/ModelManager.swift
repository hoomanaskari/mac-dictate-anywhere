import Foundation
import WhisperKit

/// Manages WhisperKit model downloads, deletion, and selection
@Observable
final class ModelManager {
    // MARK: - Observable State

    /// All available models with their download status
    var availableModels: [WhisperModel] = WhisperModel.allModels

    /// Currently downloaded and active model (nil if none)
    var currentModel: WhisperModel?

    /// ID of model currently being downloaded (nil if not downloading)
    var downloadingModelId: String?

    /// Download progress (0.0 to 1.0)
    var downloadProgress: Double = 0.0

    /// Whether a download is in progress
    var isDownloading: Bool { downloadingModelId != nil }

    /// Error message if something went wrong
    var errorMessage: String?

    // MARK: - Private

    private var downloadTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        checkCurrentModel()
    }

    // MARK: - Public Methods

    /// Checks which model is currently downloaded
    func checkCurrentModel() {
        let fileManager = FileManager.default

        for model in availableModels {
            if isModelDownloaded(model) {
                currentModel = model
                return
            }
        }

        currentModel = nil
    }

    /// Selects a new model - downloads it and deletes the old one
    /// - Parameter model: The model to download and activate
    func selectModel(_ model: WhisperModel) async throws {
        guard !isDownloading else {
            throw ModelManagerError.downloadInProgress
        }

        guard model.id != currentModel?.id else {
            return // Already the current model
        }

        await MainActor.run {
            downloadingModelId = model.id
            downloadProgress = 0.0
            errorMessage = nil
        }

        do {
            // Download the new model
            _ = try await WhisperKit.download(
                variant: model.whisperKitVariant,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
            )

            // Delete old model if exists
            if let oldModel = currentModel {
                try? deleteModelFiles(oldModel)
            }

            await MainActor.run {
                self.currentModel = model
                self.downloadingModelId = nil
                self.downloadProgress = 1.0
            }

        } catch {
            await MainActor.run {
                self.downloadingModelId = nil
                self.downloadProgress = 0.0
                self.errorMessage = "Download failed: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Deletes the currently downloaded model
    func deleteCurrentModel() throws {
        guard let model = currentModel else {
            throw ModelManagerError.noModelToDelete
        }

        guard !isDownloading else {
            throw ModelManagerError.downloadInProgress
        }

        try deleteModelFiles(model)
        currentModel = nil
    }

    /// Cancels any in-progress download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelId = nil
        downloadProgress = 0.0
    }

    // MARK: - Private Methods

    /// Checks if a specific model is downloaded
    private func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let fileManager = FileManager.default
        let possiblePaths = getModelPaths(for: model)

        for path in possiblePaths {
            let audioEncoderPath = path.appendingPathComponent("AudioEncoder.mlmodelc")
            if fileManager.fileExists(atPath: audioEncoderPath.path) {
                return true
            }
        }

        return false
    }

    /// Gets possible storage paths for a model
    private func getModelPaths(for model: WhisperModel) -> [URL] {
        let fileManager = FileManager.default
        var paths: [URL] = []

        let modelName: String
        if model.id.hasPrefix("openai_whisper-") {
            modelName = "openai_whisper-\(model.whisperKitVariant)"
        } else {
            modelName = model.id
        }

        // Documents/huggingface (non-sandboxed)
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)"))
        }

        // Home .cache
        let homeCache = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots")
        paths.append(homeCache)

        // Sandboxed container (legacy)
        let containerPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.pixelforty.Dictate-Anywhere/Data/Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)")
        paths.append(containerPath)

        return paths
    }

    /// Deletes model files from disk
    private func deleteModelFiles(_ model: WhisperModel) throws {
        let fileManager = FileManager.default
        let paths = getModelPaths(for: model)

        var deleted = false

        for path in paths {
            if fileManager.fileExists(atPath: path.path) {
                try fileManager.removeItem(at: path)
                deleted = true
            }
        }

        if !deleted {
            throw ModelManagerError.modelNotFound
        }
    }
}

// MARK: - Errors

enum ModelManagerError: LocalizedError {
    case downloadInProgress
    case noModelToDelete
    case modelNotFound
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "A download is already in progress."
        case .noModelToDelete:
            return "No model is currently downloaded."
        case .modelNotFound:
            return "Could not find the model files to delete."
        case .deletionFailed:
            return "Failed to delete the model files."
        }
    }
}
