//
//  AssemblyAIStreaming.swift
//  Dictate Anywhere
//
//  AssemblyAI STT-3.7 streaming over the v3 WebSocket. A session lasts up
//  to three hours, so one push-to-talk dictation is never split into
//  overlapping HTTP chunks (see `Settings.assemblyAIStreamingEnabled`).
//

import Foundation
import os

nonisolated enum AssemblyAIStreamingModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case realtimeAgent = "assemblyai-stt-3-7-realtime-agent"
    case realtime = "assemblyai-stt-3-7-realtime"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtimeAgent: return "Realtime Agent (\(hourlyPrice)/hr)"
        case .realtime: return "Realtime (\(hourlyPrice)/hr)"
        }
    }

    var hourlyPrice: String {
        switch self {
        case .realtimeAgent: return "$0.45"
        case .realtime: return "$0.30"
        }
    }
}

nonisolated struct AssemblyAIStreamingConfiguration: Equatable, Sendable {
    static let maximumPromptCharacters = 1_750
    static let maximumKeyterms = 100
    static let maximumKeytermCharacters = 50

    var model: AssemblyAIStreamingModel
    var languageCode: String
    var prompt: String?
    var keyterms: [String]
    /// `max_accuracy` waits longest before closing a turn. Push-to-talk only
    /// needs finished turns at Stop, which `ForceEndpoint` provides anyway.
    var mode = "max_accuracy"

    /// Streaming accepts 100 keyterms of at most 50 characters each. Longer
    /// terms are ignored by the server, so leave them out here.
    static func fittedKeyterms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maximumKeytermCharacters,
                  seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == maximumKeyterms { break }
        }
        return result
    }

    func url(region: AssemblyAIRegion) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = switch region {
        case .global: "streaming.assemblyai.com"
        case .unitedStates: "streaming.us.assemblyai.com"
        case .europeanUnion: "streaming.eu.assemblyai.com"
        }
        components.path = "/v3/ws"
        var items = [
            URLQueryItem(name: "speech_model", value: model.rawValue),
            URLQueryItem(name: "sample_rate", value: String(AssemblyAIChunker.rate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "language_codes", value: Self.jsonArray([languageCode])),
        ]
        if let prompt, !prompt.isEmpty {
            items.append(URLQueryItem(name: "prompt", value: String(prompt.prefix(Self.maximumPromptCharacters))))
        }
        if !keyterms.isEmpty {
            items.append(URLQueryItem(name: "keyterms_prompt", value: Self.jsonArray(keyterms)))
        }
        components.queryItems = items
        // URLComponents leaves "+" unescaped, which servers decode as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private static func jsonArray(_ values: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Assembles `Turn` messages. Each message replaces the previous one for the
/// same `turn_order`; a formatted final is never downgraded by a late partial.
nonisolated struct AssemblyAIStreamingTranscript: Equatable, Sendable {
    private struct Turn: Equatable, Sendable {
        var text: String
        var isFinal: Bool
        var isFormatted: Bool
    }

    private var turns: [Int: Turn] = [:]
    let joinsWithoutSpaces: Bool

    init(languageCode: String) {
        joinsWithoutSpaces = ["zh", "ja", "yue"].contains(languageCode)
    }

    mutating func apply(order: Int, transcript: String, endOfTurn: Bool, isFormatted: Bool) {
        if let existing = turns[order], existing.isFinal, existing.isFormatted,
           !(endOfTurn && isFormatted) {
            return
        }
        turns[order] = Turn(text: transcript, isFinal: endOfTurn, isFormatted: isFormatted)
    }

    var turnCount: Int { turns.count }
    var hasOpenTurn: Bool { turns.values.contains { !$0.isFinal } }

    var text: String {
        turns.keys.sorted().compactMap { order -> String? in
            let text = turns[order]!.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        .joined(separator: joinsWithoutSpaces ? "" : " ")
    }
}

nonisolated enum AssemblyAIStreamingError: Error, LocalizedError, Equatable {
    case server(code: Int, message: String)
    case closedBeforeTermination
    case beginTimedOut
    case finalizationTimedOut
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .server(let code, let message): return "AssemblyAI streaming error \(code): \(message)"
        case .closedBeforeTermination: return "The AssemblyAI stream closed before the final transcript arrived."
        case .beginTimedOut: return "AssemblyAI streaming did not start in time."
        case .finalizationTimedOut: return "AssemblyAI streaming did not finish the final transcript in time."
        case .invalidMessage: return "AssemblyAI streaming sent an unexpected message."
        }
    }
}

nonisolated struct AssemblyAIStreamingResult: Equatable, Sendable {
    let text: String
    let turnCount: Int
    let audioDurationSeconds: Double?
    let sessionDurationSeconds: Double?
}

/// Audio buffered from the capture thread until the socket is ready. Frames
/// are 100 ms of 16-bit PCM, inside the documented 20–1000 ms window.
nonisolated final class AssemblyAIStreamingAudio: @unchecked Sendable {
    static let frameBytes = AssemblyAIChunker.rate / 10 * 2
    static let minimumFrameBytes = AssemblyAIChunker.rate / 50 * 2

    private let lock = NSLock()
    private var pending = Data()
    private var finished = false
    private let pipe = AsyncStream<Data>.makeStream()

    var frames: AsyncStream<Data> { pipe.stream }

    func append(_ samples: [Float]) {
        let bytes = AssemblyAIEngine.pcmBytes(samples)
        lock.withLock {
            guard !finished else { return }
            pending.append(bytes)
            while pending.count >= Self.frameBytes {
                pipe.continuation.yield(pending.prefix(Self.frameBytes))
                pending.removeFirst(Self.frameBytes)
            }
        }
    }

    /// Sends the tail, padded with silence to the 20 ms minimum frame.
    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            if !pending.isEmpty {
                if pending.count < Self.minimumFrameBytes {
                    pending.append(Data(count: Self.minimumFrameBytes - pending.count))
                }
                pipe.continuation.yield(pending)
                pending = Data()
            }
            pipe.continuation.finish()
        }
    }

    /// Drops buffered audio. Used when the stream failed and will not resume.
    func abandon() {
        lock.withLock {
            finished = true
            pending = Data()
            pipe.continuation.finish()
        }
    }
}

nonisolated enum AssemblyAIStreamingSession {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AssemblyAIStreaming"
    )

    /// Streams `audio` until it finishes, then ends the open turn and waits
    /// for `Termination`. `onUpdate` receives the assembled preview text.
    static func run(
        configuration: AssemblyAIStreamingConfiguration,
        region: AssemblyAIRegion,
        apiKey: String,
        audio: AssemblyAIStreamingAudio,
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> AssemblyAIStreamingResult {
        var request = URLRequest(url: configuration.url(region: region))
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let socket = URLSession.shared.webSocketTask(with: request)
        let state = StreamState(languageCode: configuration.languageCode)
        socket.resume()
        defer {
            // Streaming is billed while the socket is open.
            socket.cancel(with: .normalClosure, reason: nil)
            audio.abandon()
        }
        let trace = PerfTrace.begin("stt.assemblyAIStream")
        defer { trace.end() }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: AssemblyAIStreamingResult?.self) { group in
                group.addTask {
                    try await receive(socket: socket, state: state,
                                      expectedModel: configuration.model.rawValue, onUpdate: onUpdate)
                }
                group.addTask {
                    try await state.waitForBegin(timeout: .seconds(10))
                    for await frame in audio.frames {
                        try Task.checkCancellation()
                        try await socket.send(.data(frame))
                    }
                    try Task.checkCancellation()
                    PerfTrace.event("stt.assemblyAIStreamAudioSent")
                    try await socket.send(.string(#"{"type":"ForceEndpoint"}"#))
                    try await socket.send(.string(#"{"type":"Terminate"}"#))
                    try await Task.sleep(for: .seconds(20))
                    throw AssemblyAIStreamingError.finalizationTimedOut
                }
                defer {
                    group.cancelAll()
                    // WebSocket send/receive ignore task cancellation; closing
                    // the socket makes every child return promptly.
                    socket.cancel(with: .normalClosure, reason: nil)
                    audio.abandon()
                }
                while let result = try await group.next() {
                    if let result { return result }
                }
                throw AssemblyAIStreamingError.closedBeforeTermination
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func receive(
        socket: URLSessionWebSocketTask,
        state: StreamState,
        expectedModel: String,
        onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> AssemblyAIStreamingResult {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                try Task.checkCancellation()
                if let code = closeCode(socket) { throw code }
                throw error
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                throw AssemblyAIStreamingError.invalidMessage
            }
            switch type {
            case "Begin":
                let configuration = object["configuration"] as? [String: Any]
                let model = configuration?["model"] as? String
                logger.info("Streaming session \(object["id"] as? String ?? "?", privacy: .public) began: model=\(model ?? "?", privacy: .public) mode=\(configuration?["mode"] as? String ?? "?", privacy: .public)")
                if let model, model != expectedModel {
                    logger.warning("Streaming model mismatch: requested \(expectedModel, privacy: .public), got \(model, privacy: .public)")
                }
                PerfTrace.event("stt.assemblyAIStreamBegin")
                state.didBegin()
            case "Turn":
                guard let order = object["turn_order"] as? Int else { throw AssemblyAIStreamingError.invalidMessage }
                let text = state.apply(
                    order: order,
                    transcript: object["transcript"] as? String ?? "",
                    endOfTurn: object["end_of_turn"] as? Bool ?? false,
                    isFormatted: object["turn_is_formatted"] as? Bool ?? false
                )
                onUpdate(text)
            case "Termination":
                let snapshot = state.snapshot
                logger.info("Streaming session ended: turns=\(snapshot.turnCount) open=\(snapshot.hasOpenTurn)")
                return AssemblyAIStreamingResult(
                    text: snapshot.text,
                    turnCount: snapshot.turnCount,
                    audioDurationSeconds: (object["audio_duration_seconds"] as? NSNumber)?.doubleValue,
                    sessionDurationSeconds: (object["session_duration_seconds"] as? NSNumber)?.doubleValue
                )
            case "Error":
                let code = (object["error_code"] as? NSNumber)?.intValue ?? 0
                let text = object["error"] as? String ?? "Unknown error"
                state.fail(AssemblyAIStreamingError.server(code: code, message: text))
                throw AssemblyAIStreamingError.server(code: code, message: text)
            default:
                continue
            }
        }
    }

    /// The server reports configuration errors as a close code and reason.
    private static func closeCode(_ socket: URLSessionWebSocketTask) -> AssemblyAIStreamingError? {
        guard socket.closeCode != .invalid else { return nil }
        let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return .server(code: socket.closeCode.rawValue, message: reason.isEmpty ? "Connection closed" : reason)
    }
}

private nonisolated final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var transcript: AssemblyAIStreamingTranscript
    private var began = false
    private var failure: Error?

    init(languageCode: String) {
        transcript = AssemblyAIStreamingTranscript(languageCode: languageCode)
    }

    var snapshot: AssemblyAIStreamingTranscript { lock.withLock { transcript } }

    func apply(order: Int, transcript text: String, endOfTurn: Bool, isFormatted: Bool) -> String {
        lock.withLock {
            transcript.apply(order: order, transcript: text, endOfTurn: endOfTurn, isFormatted: isFormatted)
            return transcript.text
        }
    }

    func didBegin() { lock.withLock { began = true } }
    func fail(_ error: Error) { lock.withLock { failure = error } }

    /// Polls so a timeout or cancellation never strands a continuation.
    func waitForBegin(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let status = lock.withLock { (began, failure) }
            if let failure = status.1 { throw failure }
            if status.0 { return }
            guard ContinuousClock.now < deadline else { throw AssemblyAIStreamingError.beginTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
