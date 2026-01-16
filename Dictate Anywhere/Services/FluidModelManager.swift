//
//  FluidModelManager.swift
//  Dictate Anywhere
//
//  Manages FluidAudio Parakeet model download and lifecycle.
//

import Foundation
import FluidAudio

/// Manages FluidAudio model download and initialization
@Observable
final class FluidModelManager {
    // MARK: - Constants

    private let isModelDownloadedKey = "isFluidModelDownloaded"
    private let hasCleanedUpWhisperKitKey = "hasCleanedUpWhisperKitModels"

    /// Background queue for file system operations to avoid blocking MainActor
    private let fileQueue = DispatchQueue(label: "com.dictate-anywhere.model-files", qos: .userInitiated)

    // MARK: - Observable State

    /// Whether the model is downloaded and ready
    var isModelDownloaded: Bool = false

    // MARK: - Initialization

    init() {
        // Use cached value initially for fast startup (avoid blocking MainActor)
        isModelDownloaded = UserDefaults.standard.bool(forKey: isModelDownloadedKey)

        // Verify actual disk state in background, then cleanup old models
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            let exists = self.checkModelExistsOnDiskSync()
            let needsCleanup = !UserDefaults.standard.bool(forKey: self.hasCleanedUpWhisperKitKey)

            DispatchQueue.main.async {
                self.isModelDownloaded = exists
                if !exists {
                    UserDefaults.standard.set(false, forKey: self.isModelDownloadedKey)
                }
            }

            // One-time cleanup of old WhisperKit models (in background)
            if needsCleanup {
                self.cleanupOldWhisperKitModelsSync()
            }
        }
    }

    /// Download progress (0.0 to 1.0)
    var downloadProgress: Double = 0.0

    /// Whether a download is in progress
    private(set) var isDownloading: Bool = false

    /// Error message if something went wrong
    var errorMessage: String?

    // MARK: - Private

    private var downloadTask: Task<AsrModels, Error>?
    private var loadedModels: AsrModels?

    // MARK: - Model Disk Management

    /// Returns the FluidAudio model storage directory path
    private func getFluidAudioCachePath() -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent("Library/Application Support/FluidAudio/Models")
    }

    /// Checks if model files exist on disk (async version - runs off MainActor)
    func checkModelExistsOnDisk() async -> Bool {
        return await withCheckedContinuation { continuation in
            fileQueue.async {
                let exists = self.checkModelExistsOnDiskSync()
                continuation.resume(returning: exists)
            }
        }
    }

    /// Checks if model files exist on disk (synchronous - for background queue use only)
    private func checkModelExistsOnDiskSync() -> Bool {
        let fileManager = FileManager.default
        let cachePath = getFluidAudioCachePath()

        guard fileManager.fileExists(atPath: cachePath.path) else { return false }

        // Check for parakeet model directories
        if let contents = try? fileManager.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) {
            return contents.contains { $0.lastPathComponent.hasPrefix("parakeet") }
        }
        return false
    }

    /// Deletes the FluidAudio model files from disk (async - runs off MainActor)
    func deleteModelFiles() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileQueue.async {
                do {
                    try self.deleteModelFilesSync()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Update UI state on MainActor
        await MainActor.run {
            self.loadedModels = nil
            self.isModelDownloaded = false
            UserDefaults.standard.set(false, forKey: self.isModelDownloadedKey)
        }
    }

    /// Deletes the FluidAudio model files from disk (synchronous - for background queue use only)
    private func deleteModelFilesSync() throws {
        let fileManager = FileManager.default
        let cachePath = getFluidAudioCachePath()

        // Delete all model subdirectories (parakeet-*, etc.)
        if fileManager.fileExists(atPath: cachePath.path) {
            let contents = try fileManager.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil)
            for item in contents {
                // Only delete parakeet ASR model directories
                if item.lastPathComponent.hasPrefix("parakeet") {
                    try fileManager.removeItem(at: item)
                }
            }
        }
    }

    /// Cleans up old WhisperKit model files (synchronous - for background queue use only)
    private func cleanupOldWhisperKitModelsSync() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        // Old WhisperKit paths to clean up
        let oldPaths = [
            homeDir.appendingPathComponent("Documents/huggingface/models/argmaxinc"),
            homeDir.appendingPathComponent(".cache/huggingface/hub/models--argmaxinc--whisperkit-coreml"),
        ]

        for path in oldPaths {
            if fileManager.fileExists(atPath: path.path) {
                try? fileManager.removeItem(at: path)
            }
        }

        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: self.hasCleanedUpWhisperKitKey)
        }
    }

    // MARK: - Public Methods

    /// Downloads and loads the FluidAudio ASR models.
    /// FluidAudio handles model caching internally, so subsequent calls are fast.
    /// - Returns: The loaded ASrModels for use with AsrManager
    @discardableResult
    func downloadAndLoadModels() async throws -> AsrModels {
        // If already loaded, return cached models
        if let models = loadedModels {
            return models
        }

        guard !isDownloading else {
            throw FluidModelError.downloadInProgress
        }

        // Check if models exist on disk (runs off MainActor)
        let modelsExist = await checkModelExistsOnDisk()

        await MainActor.run {
            isDownloading = true
            downloadProgress = modelsExist ? 0.5 : 0.0  // Start at 50% if cached
            errorMessage = nil
        }

        // Start a progress simulation task for downloads
        // FluidAudio doesn't expose progress, so we simulate it
        let progressTask = Task { @MainActor in
            // Only simulate progress for actual downloads (not cached loads)
            guard !modelsExist else { return }

            // Simulate progress over ~60 seconds (typical download time)
            for i in 1...90 {
                guard self.isDownloading else { break }
                // Progress from 0 to 90% over time
                self.downloadProgress = min(0.9, Double(i) / 100.0)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        do {
            // Download and load models (uses v3 for multilingual support)
            let models = try await AsrModels.downloadAndLoad(version: .v3)

            // Cancel progress simulation
            progressTask.cancel()

            // Store reference to loaded models
            self.loadedModels = models

            await MainActor.run {
                self.isModelDownloaded = true
                self.isDownloading = false
                self.downloadProgress = 1.0
                UserDefaults.standard.set(true, forKey: self.isModelDownloadedKey)
            }

            return models

        } catch {
            progressTask.cancel()
            await MainActor.run {
                self.isDownloading = false
                self.downloadProgress = 0.0
                self.errorMessage = "Download failed: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Returns the loaded models if available
    func getLoadedModels() -> AsrModels? {
        return loadedModels
    }

    /// Cancels any in-progress download
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
    }

    /// Clears the loaded models from memory (models remain on disk)
    func unloadModels() {
        loadedModels = nil
        isModelDownloaded = false
    }
}

// MARK: - Errors

enum FluidModelError: LocalizedError {
    case downloadInProgress
    case modelsNotLoaded

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "A download is already in progress."
        case .modelsNotLoaded:
            return "Models have not been loaded yet."
        }
    }
}
