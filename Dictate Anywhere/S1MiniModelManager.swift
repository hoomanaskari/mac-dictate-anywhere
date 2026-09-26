//
//  S1MiniModelManager.swift
//  Dictate Anywhere
//
//  Verified download and lifecycle management for S1-mini by Superwhisper.
//

import CryptoKit
import Foundation

enum S1MiniModelManagerError: LocalizedError {
    case downloadInProgress
    case invalidResponse
    case unexpectedFileSize(actual: Int64, expected: Int64)
    case checksumMismatch
    case missingLicense

    var errorDescription: String? {
        switch self {
        case .downloadInProgress:
            return "An S1-mini model operation is already in progress."
        case .invalidResponse:
            return "The S1-mini download server returned an invalid response."
        case .unexpectedFileSize(let actual, let expected):
            return "The S1-mini download had an unexpected size (\(actual) of \(expected) bytes)."
        case .checksumMismatch:
            return "The S1-mini download failed its integrity check."
        case .missingLicense:
            return "The S1-mini license could not be downloaded."
        }
    }
}

enum S1MiniModelIntegrity {
    nonisolated static func validate(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == S1MiniModelSpec.byteCount else {
            throw S1MiniModelManagerError.unexpectedFileSize(
                actual: byteCount,
                expected: S1MiniModelSpec.byteCount
            )
        }
        guard try sha256(of: url) == S1MiniModelSpec.sha256 else {
            throw S1MiniModelManagerError.checksumMismatch
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum S1MiniDownloadProgress {
    nonisolated static let installationFraction = 0.98

    nonisolated static func transferFraction(
        totalBytesWritten: Int64,
        serverExpectedByteCount: Int64,
        pinnedByteCount: Int64 = S1MiniModelSpec.byteCount
    ) -> Double {
        guard pinnedByteCount > 0 else { return 0 }

        // Hugging Face's redirected download may report NSURLSessionTransferSizeUnknown.
        // The pinned artifact size is authoritative and is verified again after download.
        let expectedByteCount = serverExpectedByteCount == pinnedByteCount
            ? serverExpectedByteCount
            : pinnedByteCount
        return min(1, max(0, Double(totalBytesWritten) / Double(expectedByteCount)))
    }

    nonisolated static func installationProgress(
        current: Double,
        transferFraction: Double
    ) -> Double {
        let candidate = min(installationFraction, max(0, transferFraction) * installationFraction)
        return max(current, candidate)
    }
}

private final class S1MiniModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var activeTask: URLSessionDownloadTask?
    private var cancellationRequested = false
    private var fileMoveError: Error?
    private var lastReportedFraction = -1.0

    init(destinationURL: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: .default,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.downloadTask(with: url)

                stateLock.lock()
                self.continuation = continuation
                activeTask = task
                let shouldCancel = cancellationRequested
                stateLock.unlock()

                if shouldCancel {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.stateLock.lock()
            self.cancellationRequested = true
            let task = self.activeTask
            self.stateLock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = S1MiniDownloadProgress.transferFraction(
            totalBytesWritten: totalBytesWritten,
            serverExpectedByteCount: totalBytesExpectedToWrite
        )

        stateLock.lock()
        let shouldReport = fraction >= 1 || fraction - lastReportedFraction >= 0.002
        if shouldReport {
            lastReportedFraction = fraction
        }
        stateLock.unlock()

        if shouldReport {
            onProgress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            stateLock.lock()
            fileMoveError = error
            stateLock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let pendingContinuation = continuation
        self.continuation = nil
        activeTask = nil
        let pendingFileMoveError = fileMoveError
        self.fileMoveError = nil
        stateLock.unlock()

        session.finishTasksAndInvalidate()
        guard let pendingContinuation else { return }

        if let error {
            pendingContinuation.resume(throwing: error)
        } else if let pendingFileMoveError {
            pendingContinuation.resume(throwing: pendingFileMoveError)
        } else if let response = task.response {
            pendingContinuation.resume(returning: response)
        } else {
            pendingContinuation.resume(throwing: S1MiniModelManagerError.invalidResponse)
        }
    }
}

@Observable
@MainActor
final class S1MiniModelManager {
    private struct Fingerprint: Equatable {
        let byteCount: Int64
        let modificationDate: Date
    }

    private(set) var isModelDownloaded: Bool
    private(set) var isDownloading = false
    private(set) var isDeleting = false
    private(set) var isVerifying = false
    private(set) var downloadProgress = 0.0
    private(set) var lastError: String?

    let modelDirectory: URL
    let modelURL: URL
    let licenseURL: URL

    private var verifiedFingerprint: Fingerprint?

    init(modelDirectory: URL = S1MiniModelManager.defaultModelDirectory) {
        self.modelDirectory = modelDirectory
        modelURL = modelDirectory.appendingPathComponent(S1MiniModelSpec.filename)
        licenseURL = modelDirectory.appendingPathComponent("LICENSE")
        isModelDownloaded = Self.hasCompleteInstallation(
            modelURL: modelURL,
            licenseURL: licenseURL
        )
    }

    nonisolated static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Anywhere", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("S1-mini", isDirectory: true)
    }

    var isBusy: Bool {
        isDownloading || isDeleting || isVerifying
    }

    func refreshInstallationState() async {
        guard !isDownloading, !isDeleting else { return }
        guard Self.hasCompleteInstallation(modelURL: modelURL, licenseURL: licenseURL) else {
            isModelDownloaded = false
            verifiedFingerprint = nil
            return
        }

        isVerifying = true
        defer { isVerifying = false }
        do {
            try await validateModel(at: modelURL)
            isModelDownloaded = true
            lastError = nil
        } catch {
            isModelDownloaded = false
            verifiedFingerprint = nil
            lastError = error.localizedDescription
        }
    }

    func validatedModelURL() async throws -> URL {
        let trace = PerfTrace.begin("cleanup.validate")
        defer { trace.end() }
        guard Self.hasNonEmptyFile(at: licenseURL) else {
            isModelDownloaded = false
            throw S1MiniModelManagerError.missingLicense
        }
        let fingerprint = try Self.fingerprint(at: modelURL)
        if fingerprint != verifiedFingerprint {
            isVerifying = true
            defer { isVerifying = false }
            try await validateModel(at: modelURL)
        }
        isModelDownloaded = true
        return modelURL
    }

    func downloadModel() async throws {
        let trace = PerfTrace.begin("cleanup.modelDownload")
        defer { trace.end() }
        guard !isBusy else { throw S1MiniModelManagerError.downloadInProgress }

        if let existingURL = try? await validatedModelURL() {
            isModelDownloaded = true
            lastError = nil
            _ = existingURL
            return
        }

        isDownloading = true
        isModelDownloaded = false
        downloadProgress = 0
        lastError = nil

        let fileManager = FileManager.default
        let stagingID = UUID().uuidString
        let stagedModelURL = modelDirectory.appendingPathComponent(".\(stagingID).gguf.part")
        let stagedLicenseURL = modelDirectory.appendingPathComponent(".\(stagingID).license.part")

        defer {
            isDownloading = false
            try? fileManager.removeItem(at: stagedModelURL)
            try? fileManager.removeItem(at: stagedLicenseURL)
            if let contents = try? fileManager.contentsOfDirectory(atPath: modelDirectory.path),
               contents.isEmpty {
                try? fileManager.removeItem(at: modelDirectory)
            }
        }

        do {
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            let downloader = S1MiniModelDownloader(destinationURL: stagedModelURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloadProgress = S1MiniDownloadProgress.installationProgress(
                        current: self.downloadProgress,
                        transferFraction: fraction
                    )
                }
            }
            let response = try await downloader.download(from: S1MiniModelSpec.downloadURL)
            try Self.requireSuccessfulHTTPResponse(response)
            try await validateModel(at: stagedModelURL, cacheFingerprint: false)

            let (licenseData, licenseResponse) = try await URLSession.shared.data(
                from: S1MiniModelSpec.licenseURL
            )
            try Self.requireSuccessfulHTTPResponse(licenseResponse)
            guard !licenseData.isEmpty else {
                throw S1MiniModelManagerError.missingLicense
            }

            try licenseData.write(to: stagedLicenseURL, options: .atomic)
            downloadProgress = 0.99

            await S1MiniPostProcessingService.unload()
            if fileManager.fileExists(atPath: modelURL.path) {
                try fileManager.removeItem(at: modelURL)
            }
            if fileManager.fileExists(atPath: licenseURL.path) {
                try fileManager.removeItem(at: licenseURL)
            }
            try fileManager.moveItem(at: stagedModelURL, to: modelURL)
            try fileManager.moveItem(at: stagedLicenseURL, to: licenseURL)

            verifiedFingerprint = try Self.fingerprint(at: modelURL)
            isModelDownloaded = true
            downloadProgress = 1
        } catch {
            isModelDownloaded = Self.hasCompleteInstallation(
                modelURL: modelURL,
                licenseURL: licenseURL
            )
            lastError = error.localizedDescription
            throw error
        }
    }

    func deleteModel() async throws {
        guard !isBusy else { throw S1MiniModelManagerError.downloadInProgress }
        isDeleting = true
        lastError = nil
        defer { isDeleting = false }

        await S1MiniPostProcessingService.unload()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        if fileManager.fileExists(atPath: licenseURL.path) {
            try fileManager.removeItem(at: licenseURL)
        }
        if let contents = try? fileManager.contentsOfDirectory(atPath: modelDirectory.path), contents.isEmpty {
            try? fileManager.removeItem(at: modelDirectory)
        }
        verifiedFingerprint = nil
        isModelDownloaded = false
        downloadProgress = 0
    }

    private func validateModel(at url: URL, cacheFingerprint: Bool = true) async throws {
        try await Task.detached(priority: .utility) {
            try S1MiniModelIntegrity.validate(url)
        }.value
        if cacheFingerprint {
            verifiedFingerprint = try Self.fingerprint(at: url)
        }
    }

    nonisolated private static func hasExpectedSize(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == S1MiniModelSpec.byteCount
    }

    nonisolated private static func hasCompleteInstallation(
        modelURL: URL,
        licenseURL: URL
    ) -> Bool {
        hasExpectedSize(at: modelURL) && hasNonEmptyFile(at: licenseURL)
    }

    nonisolated private static func hasNonEmptyFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    nonisolated private static func fingerprint(at url: URL) throws -> Fingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Fingerprint(
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            modificationDate: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }

    nonisolated private static func requireSuccessfulHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw S1MiniModelManagerError.invalidResponse
        }
    }
}
