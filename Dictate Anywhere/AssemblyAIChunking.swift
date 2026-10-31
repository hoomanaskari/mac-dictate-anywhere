import Foundation
import CryptoKit
import NaturalLanguage

nonisolated struct AssemblyAIChunk: Sendable {
    let start: Int
    let samples: [Float]
    let silentOverlap: Bool
    var end: Int { start + samples.count }
}

/// Deterministic across audio callback/file-read sizes. Keep three seconds on
/// both sides of each seam; prefer a quiet half-second in the last five seconds.
nonisolated struct AssemblyAIChunker {
    static let rate = 16_000
    static let target = 100 * rate
    static let overlap = 3 * rate
    private var buffer: [Float] = []
    private var start = 0
    private var previousEnd = 0
    private var silentOverlap = true

    mutating func append(_ samples: [Float], final: Bool = false) -> [AssemblyAIChunk] {
        buffer.append(contentsOf: samples)
        var result: [AssemblyAIChunk] = []
        while buffer.count >= Self.target {
            var cut = Self.target
            let window = Self.rate / 2
            for end in stride(from: Self.target, through: Self.target - 5 * Self.rate, by: -window) {
                if Self.isQuiet(buffer[(end - window)..<end]) { cut = end; break }
            }
            result.append(AssemblyAIChunk(start: start, samples: Array(buffer.prefix(cut)), silentOverlap: silentOverlap))
            previousEnd = start + cut
            silentOverlap = Self.isQuiet(buffer[(cut - Self.overlap)..<cut])
            buffer.removeFirst(cut - Self.overlap)
            start += cut - Self.overlap
        }
        if final {
            // No overlap-only tail, and no minimum duration that drops a final word.
            if start + buffer.count > previousEnd {
                result.append(AssemblyAIChunk(start: start, samples: buffer, silentOverlap: silentOverlap))
            }
            buffer.removeAll()
        }
        return result
    }

    private static func isQuiet(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        return samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count) < 0.000001
    }
}

nonisolated enum AssemblyAIChunkError: Error, LocalizedError {
    case uncertainBoundary
    case damagedAudio
    var errorDescription: String? {
        switch self {
        case .uncertainBoundary:
            return "A transcription boundary could not be joined reliably. Your audio is saved; recover it with another speech model or export it."
        case .damagedAudio:
            return "A saved audio chunk could not be read. The original recording is still available."
        }
    }
}

nonisolated enum AssemblyAIOverlap {
    /// Returns the stable prefix from the older result. The newer result owns
    /// the overlap. Never discard an unmatched suffix or guess on a short phrase.
    static func stablePrefix(_ older: String, before newer: String) -> String? {
        func tokens(_ text: String) -> [(Range<String.Index>, String)] {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            var result: [(Range<String.Index>, String)] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = String(text[range]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                result.append((range, word))
                return true
            }
            return result
        }
        let lhs = Array(tokens(older).suffix(32)), rhs = Array(tokens(newer).prefix(32))
        guard min(lhs.count, rhs.count) >= 3 else { return nil }
        // Exact lexical matches ignore punctuation/case. Prefer the largest
        // overlap; one/two-word matches could erase intentional repetition.
        var matchingStarts: [String.Index] = []
        for count in stride(from: min(lhs.count, rhs.count), through: 3, by: -1) {
            let tail = Array(lhs.suffix(count))
            if zip(tail, rhs.prefix(count)).allSatisfy({ $0.1 == $1.1 }) {
                matchingStarts.append(tail[0].0.lowerBound)
            }
        }
        if matchingStarts.count > 1 { return nil }
        if let start = matchingStarts.first {
            return String(older[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // One differing word inside an otherwise strong anchor is allowed.
        // Insertions/deletions or ambiguity use a larger audio decode instead.
        for count in stride(from: min(lhs.count, rhs.count), through: 6, by: -1) {
            let tail = Array(lhs.suffix(count))
            let matches = zip(tail, rhs.prefix(count)).map { $0.1 == $1.1 }
            if matches.first == true, matches.last == true, matches.filter({ !$0 }).count == 1 {
                return String(older[..<tail[0].0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

nonisolated struct AssemblyAIStoredChunk: Codable, Sendable {
    let start: Int
    let end: Int
    let silentOverlap: Bool
    let key: String
}

/// Audio callbacks only enqueue local work. Network backpressure leaves audio
/// on disk, not in an ever-growing array or an unbounded set of HTTP requests.
nonisolated final class AssemblyAIChunkStore: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.dictate-anywhere.assemblyai-chunks", qos: .utility)
    private var chunker = AssemblyAIChunker()
    private var chunks: [AssemblyAIStoredChunk] = []
    private var failure: Error?
    private var finished = false

    init(audioURL: URL) throws {
        directory = Self.directory(for: audioURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func directory(for audioURL: URL) -> URL { audioURL.deletingPathExtension().appendingPathExtension("chunks") }

    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard !finished, failure == nil else { return }
            do { try save(chunker.append(samples)) } catch { failure = error }
        }
    }

    func finish() async throws {
        try await access {
            guard !self.finished else { return }
            self.finished = true
            try self.save(self.chunker.append([], final: true))
        }
    }

    func snapshot() async throws -> [AssemblyAIStoredChunk] { try await access { self.chunks } }

    func samples(for chunk: AssemblyAIStoredChunk) async throws -> [Float] {
        try await access {
            let data = try Data(contentsOf: self.directory.appendingPathComponent(chunk.key + ".pcm"))
            guard data.count == (chunk.end - chunk.start) * MemoryLayout<Float>.size else { throw AssemblyAIChunkError.damagedAudio }
            return data.withUnsafeBytes { bytes in
                (0..<(data.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
        }
    }

    func cachedText(for chunk: AssemblyAIStoredChunk, signature: String) async throws -> String? {
        try await access {
            try? String(contentsOf: self.textURL(chunk, signature: signature), encoding: .utf8)
        }
    }

    func saveText(_ text: String, for chunk: AssemblyAIStoredChunk, signature: String) async throws {
        try await access { try self.write(Data(text.utf8), to: self.textURL(chunk, signature: signature)) }
    }

    func savePreview(_ text: String) async throws {
        try await access { try self.write(Data(text.utf8), to: self.directory.appendingPathComponent("preview.txt")) }
    }

    private func textURL(_ chunk: AssemblyAIStoredChunk, signature: String) -> URL {
        let hash = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(chunk.key + "-" + hash + ".txt")
    }

    private func save(_ incoming: [AssemblyAIChunk]) throws {
        for chunk in incoming {
            let data = chunk.samples.withUnsafeBytes { Data($0) }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let key = "\(chunk.start)-\(chunk.end)-\(hash)"
            let stored = AssemblyAIStoredChunk(start: chunk.start, end: chunk.end, silentOverlap: chunk.silentOverlap, key: key)
            let url = directory.appendingPathComponent(key + ".pcm")
            if !FileManager.default.fileExists(atPath: url.path) { try write(data, to: url) }
            chunks.append(stored)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func access<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if let failure { throw failure }
                    continuation.resume(returning: try body())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// One owner processes requests in audio order. Successful requests are durable
/// before advancing; cancellation cannot label a partial session as complete.
@MainActor
final class AssemblyAIChunkProcessor {
    let store: AssemblyAIChunkStore
    private let signature: String
    private let request: ([Float]) async throws -> String
    private var nextIndex = 0
    private var committed = ""
    private var pending = ""
    private var pendingStart = 0
    private var pendingChunks: [AssemblyAIStoredChunk] = []
    var text: String { CancelledDictation.joining(committed, pending) }

    init(store: AssemblyAIChunkStore, signature: String, request: @escaping ([Float]) async throws -> String) {
        self.store = store
        self.signature = signature
        self.request = request
    }

    func processAvailable() async throws {
        let chunks = try await store.snapshot()
        while nextIndex < chunks.count {
            try Task.checkCancellation()
            let chunk = chunks[nextIndex]
            let decoded: String
            if let cached = try await store.cachedText(for: chunk, signature: signature) { decoded = cached }
            else {
                decoded = try await requestWithRetry(try await store.samples(for: chunk))
                try Task.checkCancellation()
                try await store.saveText(decoded, for: chunk, signature: signature)
            }
            if nextIndex == 0 {
                pending = decoded
                pendingStart = chunk.start
                pendingChunks = [chunk]
            } else if chunk.silentOverlap {
                committed = CancelledDictation.joining(committed, pending)
                pending = decoded
                pendingStart = chunk.start
                pendingChunks = [chunk]
            } else if let prefix = AssemblyAIOverlap.stablePrefix(pending, before: decoded) {
                committed = CancelledDictation.joining(committed, prefix)
                pending = decoded
                pendingStart = chunk.start
                pendingChunks = [chunk]
            } else {
                // Decode the ambiguous span together, eliminating this seam.
                // Usually two chunks (~197 sec), never beyond the HTTP limit.
                guard chunk.end - pendingStart <= 20 * 60 * AssemblyAIChunker.rate else {
                    throw AssemblyAIChunkError.uncertainBoundary
                }
                var combined: [Float] = []
                var end = pendingStart
                for part in pendingChunks + [chunk] {
                    let samples = try await store.samples(for: part)
                    combined.append(contentsOf: samples.dropFirst(max(0, end - part.start)))
                    end = part.end
                }
                // A stable content signature avoids re-paying for repairs on recovery.
                let repairKey = combined.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
                let cache = AssemblyAIStoredChunk(start: pendingStart, end: chunk.end, silentOverlap: false, key: "repair-" + repairKey)
                if let cached = try await store.cachedText(for: cache, signature: signature) { pending = cached }
                else {
                    let repaired = try await requestWithRetry(combined)
                    try Task.checkCancellation()
                    try await store.saveText(repaired, for: cache, signature: signature)
                    pending = repaired
                }
                pendingChunks.append(chunk)
            }
            nextIndex += 1
            try await store.savePreview(text)
        }
    }

    private func requestWithRetry(_ samples: [Float]) async throws -> String {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await request(samples) }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
            }
        }
        throw AssemblyAIEngineError.invalidResponse
    }

    static func isRetryable(_ error: Error) -> Bool {
        if case AssemblyAIEngineError.requestFailed(let status, _) = error { return status == 429 || status >= 500 }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        return false
    }
}
