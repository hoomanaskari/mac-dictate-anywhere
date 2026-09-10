import Foundation
@preconcurrency import AVFoundation

nonisolated struct RecoveryCaptureResult: Sendable {
    let sampleCount: Int
    let error: String?
}

/// Audio callbacks only enqueue chunks. All file access is serialized off the
/// capture and main threads; closing drains pending writes before saving history.
nonisolated final class RecoveryAudioCapture: @unchecked Sendable {
    let id: UUID
    let url: URL
    private let queue = DispatchQueue(label: "com.dictate-anywhere.recovery-audio", qos: .utility)
    private var file: AVAudioFile?
    private var sampleCount = 0
    private var writeError: String?

    init(id: UUID, url: URL) throws {
        self.id = id
        self.url = url
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard let file, writeError == nil else { return }
            do {
                let buffer = try makePCMBuffer(from: samples)
                try file.write(from: buffer)
                sampleCount += samples.count
            } catch {
                writeError = error.localizedDescription
            }
        }
    }

    func finish() async -> RecoveryCaptureResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                file = nil
                continuation.resume(returning: RecoveryCaptureResult(sampleCount: sampleCount, error: writeError))
            }
        }
    }
}

/// Reads bounded chunks (ten seconds by default), including for long recordings.
nonisolated final class RecoveryAudioReader: @unchecked Sendable {
    private let file: AVAudioFile

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1 else { throw TranscriptionError.audioFormatError }
    }

    func nextSamples(maxSamples: Int = 160_000) throws -> [Float]? {
        guard file.framePosition < file.length else { return nil }
        guard maxSamples > 0 else { throw TranscriptionError.audioFormatError }
        let count = AVAudioFrameCount(min(Int64(maxSamples), file.length - file.framePosition))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw TranscriptionError.audioFormatError
        }
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

nonisolated struct CancelledDictation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let duration: TimeInterval
    let preview: String
    /// A completed recognition result captured before cancellation during cleanup.
    /// The live preview is never treated as a complete replacement for audio.
    let completedTranscript: String?
    let hasAudio: Bool
    let captureError: String?
    /// Words from earlier parts of a continued session. This file contains
    /// only the newest audio; a completedTranscript already includes the prefix.
    var transcriptPrefix: String? = nil
    var targetBundleIdentifier: String? = nil

    nonisolated static func joining(_ prefix: String, _ text: String) -> String {
        [prefix, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@Observable
@MainActor
final class DictationRecoveryStore {
    static let retention: TimeInterval = 24 * 60 * 60
    private(set) var entries: [CancelledDictation] = []
    var errorMessage: String?
    let directory: URL
    private var expiryTask: Task<Void, Never>?
    private var activeCaptureIDs: Set<UUID> = []
    private var retainedEntryIDs: Set<UUID> = []

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate Anywhere/Cancelled Dictations", isDirectory: true)
    }

    isolated deinit { expiryTask?.cancel() }

    func reload(now: Date = Date()) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { entries = []; return }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        entries = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(CancelledDictation.self, from: data),
                  url.deletingPathExtension().lastPathComponent == entry.id.uuidString else { return nil }
            return entry
        }.sorted { $0.createdAt > $1.createdAt }
        for entry in entries where entry.expiresAt <= now && !retainedEntryIDs.contains(entry.id) {
            try remove(id: entry.id)
        }
        // Clean up interrupted captures and unreadable metadata after the same retention period.
        let retainedIDs = Set(entries.map(\.id)).union(activeCaptureIDs)
        for file in files where ["caf", "json"].contains(file.pathExtension) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !retainedIDs.contains(id), fm.fileExists(atPath: file.path),
                  let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) >= Self.retention else { continue }
            try fm.removeItem(at: file)
        }
        scheduleExpiry()
    }

    func beginCapture() throws -> RecoveryAudioCapture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        let id = UUID()
        let capture = try RecoveryAudioCapture(id: id, url: audioURL(id: id))
        activeCaptureIDs.insert(id)
        return capture
    }

    @discardableResult
    func preserve(
        _ capture: RecoveryAudioCapture, preview: String, completedTranscript: String?,
        transcriptPrefix: String? = nil, previousDuration: TimeInterval = 0,
        targetBundleIdentifier: String? = nil, now: Date = Date()
    ) async throws -> CancelledDictation? {
        let result = await capture.finish()
        activeCaptureIDs.remove(capture.id)
        guard result.sampleCount > 0 || !preview.isEmpty || completedTranscript?.isEmpty == false
                || transcriptPrefix?.isEmpty == false else {
            try remove(id: capture.id)
            if let error = result.error { errorMessage = "Audio recovery could not be saved: \(error)" }
            return nil
        }
        let entry = CancelledDictation(
            id: capture.id, createdAt: now, expiresAt: now.addingTimeInterval(Self.retention),
            duration: previousDuration + Double(result.sampleCount) / 16_000, preview: preview,
            completedTranscript: completedTranscript, hasAudio: result.sampleCount > 0,
            captureError: result.error, transcriptPrefix: transcriptPrefix,
            targetBundleIdentifier: targetBundleIdentifier
        )
        try JSONEncoder().encode(entry).write(to: metadataURL(id: entry.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL(id: entry.id).path)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if let error = result.error { errorMessage = "Only part of the cancelled audio was saved: \(error)" }
        scheduleExpiry()
        return entry
    }

    func discard(_ capture: RecoveryAudioCapture) async throws {
        _ = await capture.finish()
        activeCaptureIDs.remove(capture.id)
        try remove(id: capture.id)
    }

    func remove(id: UUID) throws {
        guard !retainedEntryIDs.contains(id) else {
            throw NSError(domain: "DictationRecovery", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This session is currently in use."])
        }
        for url in [audioURL(id: id), metadataURL(id: id)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        entries.removeAll { $0.id == id }
    }

    func removeAll() throws {
        for entry in entries where !retainedEntryIDs.contains(entry.id) { try remove(id: entry.id) }
        scheduleExpiry()
    }

    /// A source must survive expiry and History actions while it is being used.
    func retain(id: UUID) {
        retainedEntryIDs.insert(id)
        scheduleExpiry()
    }

    func release(id: UUID) {
        retainedEntryIDs.remove(id)
        scheduleExpiry()
    }

    func audioURL(id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".caf") }
    private func metadataURL(id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = entries.filter({ !retainedEntryIDs.contains($0.id) }).map(\.expiresAt).min()
        else { expiryTask = nil; return }
        let delay = max(1, next.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            do { try self.reload() } catch { self.errorMessage = error.localizedDescription }
        }
    }
}
