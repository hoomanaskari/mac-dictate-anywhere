import Foundation
import WhisperKit

/// Manages WhisperKit model download and deletion
@Observable
final class ModelManager {
    // MARK: - Observable State

    /// Whether the model is downloaded and ready
    var isModelDownloaded: Bool = false

    /// Download progress (0.0 to 1.0)
    var downloadProgress: Double = 0.0

    /// Whether a download is in progress
    private(set) var isDownloading: Bool = false

    /// Error message if something went wrong
    var errorMessage: String?

    // MARK: - Private

    private var downloadTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        checkModelStatus()
    }

    // MARK: - Public Methods

    /// Checks if the model is currently downloaded
    func checkModelStatus() {
        isModelDownloaded = checkModelExistsOnDisk()
    }

    /// Downloads the speech recognition model
    func downloadModel() async throws {
        guard !isDownloading else {
            throw ModelManagerError.downloadInProgress
        }

        guard !isModelDownloaded else {
            return // Already downloaded
        }

        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
            errorMessage = nil
        }

        do {
            // Download the model
            // Scale progress to 0.95 max during download, leaving room for verification phase
            let folder = try await WhisperKit.download(
                variant: WhisperModel.defaultModel.whisperKitVariant,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = min(progress.fractionCompleted * 0.95, 0.95)
                    }
                }
            )

            // Verify the model was actually downloaded
            await MainActor.run {
                self.downloadProgress = 0.97
            }

            guard folder != nil, checkModelExistsOnDisk() else {
                throw ModelManagerError.verificationFailed
            }

            await MainActor.run {
                self.isModelDownloaded = true
                self.isDownloading = false
                self.downloadProgress = 1.0
            }

        } catch {
            await MainActor.run {
                self.isDownloading = false
                self.downloadProgress = 0.0
                self.errorMessage = "Download failed: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Deletes the downloaded model
    func deleteModel() throws {
        guard isModelDownloaded else {
            throw ModelManagerError.noModelToDelete
        }

        guard !isDownloading else {
            throw ModelManagerError.downloadInProgress
        }

        try deleteModelFiles()
        isModelDownloaded = false
    }

    /// Cancels any in-progress download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
    }

    // MARK: - Private Methods

    /// Checks if the model files exist on disk
    private func checkModelExistsOnDisk() -> Bool {
        let fileManager = FileManager.default
        let possiblePaths = getModelPaths()

        for path in possiblePaths {
            let audioEncoderPath = path.appendingPathComponent("AudioEncoder.mlmodelc")
            if fileManager.fileExists(atPath: audioEncoderPath.path) {
                return true
            }
        }

        return false
    }

    /// Gets possible storage paths for the model
    private func getModelPaths() -> [URL] {
        let fileManager = FileManager.default
        var paths: [URL] = []
        let modelName = WhisperModel.defaultModel.id

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
    private func deleteModelFiles() throws {
        let fileManager = FileManager.default
        let paths = getModelPaths()

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
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "A download is already in progress."
        case .noModelToDelete:
            return "No model is currently downloaded."
        case .modelNotFound:
            return "Could not find the model files to delete."
        case .verificationFailed:
            return "Model download could not be verified. Please try again."
        }
    }
}
