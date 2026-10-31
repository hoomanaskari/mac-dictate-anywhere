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

    var format: AVAudioFormat { file.processingFormat }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1 else { throw TranscriptionError.audioFormatError }
    }

    func nextSamples(maxSamples: Int = 160_000) throws -> [Float]? {
        guard let buffer = try nextBuffer(maxSamples: maxSamples),
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// PCM consumers can avoid copying file audio through an intermediate array.
    /// As with nextSamples, the caller serializes reads.
    func nextBuffer(maxSamples: Int = 160_000) throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        guard maxSamples > 0 else { throw TranscriptionError.audioFormatError }
        let count = AVAudioFrameCount(min(Int64(maxSamples), file.length - file.framePosition))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw TranscriptionError.audioFormatError
        }
        try file.read(into: buffer, frameCount: count)
        return buffer.frameLength > 0 ? buffer : nil
    }
}

/// Serialized, bounded file pulls with one conversion stream, including its tail.
/// Each returned buffer owns its samples; asynchronous consumers may retain it.
nonisolated final class ConvertedRecoveryAudioReader: @unchecked Sendable {
    private let lock = NSLock()
    private let reader: RecoveryAudioReader
    private let converter: PCMStreamConverter
    private var pending: [AVAudioPCMBuffer] = []
    private var nextIndex = 0
    private var ended = false

    init(url: URL, outputFormat: AVAudioFormat) throws {
        reader = try RecoveryAudioReader(url: url)
        converter = try PCMStreamConverter(from: reader.format, to: outputFormat)
    }

    func nextBuffer() throws -> AVAudioPCMBuffer? {
        try lock.withLock {
            while nextIndex == pending.count {
                pending.removeAll(keepingCapacity: true)
                nextIndex = 0
                guard !ended else { return nil }
                if let source = try reader.nextBuffer() {
                    pending = try converter.convert(source)
                } else {
                    ended = true
                    pending = try converter.finish()
                }
            }
            defer { nextIndex += 1 }
            return pending[nextIndex]
        }
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
        let trace = PerfTrace.begin("recovery.reload")
        defer { trace.end() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { entries = []; return }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        entries = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(CancelledDictation.self, from: data),
                  url.deletingPathExtension().lastPathComponent == entry.id.uuidString else { return nil }
            return entry
        }.sorted { $0.createdAt > $1.createdAt }
        // A crash may leave readable audio without cancellation metadata.
        // Surface it instead of silently deleting it at the next expiry sweep.
        let knownIDs = Set(entries.map(\.id)).union(activeCaptureIDs)
        for url in files where url.pathExtension == "caf" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !knownIDs.contains(id),
                  let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) < Self.retention,
                  let file = try? AVAudioFile(forReading: url), file.length > 0 else { continue }
            let previewURL = AssemblyAIChunkStore.directory(for: url).appendingPathComponent("preview.txt")
            let preview = (try? String(contentsOf: previewURL, encoding: .utf8)) ?? ""
            let entry = CancelledDictation(id: id, createdAt: modified,
                expiresAt: modified.addingTimeInterval(Self.retention),
                duration: Double(file.length) / file.processingFormat.sampleRate,
                preview: preview, completedTranscript: nil, hasAudio: true,
                captureError: "Recording interrupted; saved audio may be incomplete.")
            try JSONEncoder().encode(entry).write(to: metadataURL(id: id), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL(id: id).path)
            entries.append(entry)
        }
        entries.sort { $0.createdAt > $1.createdAt }
        for entry in entries where entry.expiresAt <= now && !retainedEntryIDs.contains(entry.id) {
            try remove(id: entry.id)
        }
        // Clean up interrupted captures and unreadable metadata after the same retention period.
        let retainedIDs = Set(entries.map(\.id)).union(activeCaptureIDs)
        for file in files where ["caf", "json", "chunks"].contains(file.pathExtension) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !retainedIDs.contains(id), fm.fileExists(atPath: file.path),
                  let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) >= Self.retention else { continue }
            try fm.removeItem(at: file)
        }
        scheduleExpiry()
    }

    func beginCapture() throws -> RecoveryAudioCapture {
        let trace = PerfTrace.begin("recovery.captureStart")
        defer { trace.end() }
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
        let trace = PerfTrace.begin("recovery.preserve")
        defer { trace.end() }
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
        let trace = PerfTrace.begin("recovery.discard")
        defer { trace.end() }
        _ = await capture.finish()
        activeCaptureIDs.remove(capture.id)
        try remove(id: capture.id)
    }

    func remove(id: UUID) throws {
        guard !retainedEntryIDs.contains(id) else {
            throw NSError(domain: "DictationRecovery", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This session is currently in use."])
        }
        for url in [audioURL(id: id), metadataURL(id: id), AssemblyAIChunkStore.directory(for: audioURL(id: id))] where FileManager.default.fileExists(atPath: url.path) {
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

    /// A preview is explicitly copyable even when recognition cannot finish.
    /// Never pretend it is the completed transcript or delete the source audio.
    func copyableText(for entry: CancelledDictation) -> String {
        if let completed = entry.completedTranscript, !completed.isEmpty { return completed }
        let cached = (try? String(contentsOf: AssemblyAIChunkStore.directory(for: audioURL(id: entry.id))
            .appendingPathComponent("preview.txt"), encoding: .utf8)) ?? ""
        let chunkText = CancelledDictation.joining(entry.transcriptPrefix ?? "", cached)
        return entry.preview.count >= chunkText.count ? entry.preview : chunkText
    }

    /// The caller retains the entry while the save panel and export are active.
    func exportAudio(id: UUID, to destination: URL) async throws {
        let source = audioURL(id: id)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try await Task.detached(priority: .userInitiated) {
            let input = try AVAudioFile(forReading: source)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".dictation-export-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let output = try AVAudioFile(forWriting: temporary, settings: input.processingFormat.settings)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000) else {
                    throw TranscriptionError.audioFormatError
                }
                while input.framePosition < input.length {
                    try Task.checkCancellation()
                    try input.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    try output.write(from: buffer)
                }
            } // Close the WAV before making it visible at its final path.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }.value
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
