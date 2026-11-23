import Foundation

/// Accepts capture callbacks while a single multipart request is in flight.
nonisolated final class AssemblyAILiveAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0
    private let pipe = AsyncThrowingStream<[Float], Error>.makeStream()

    var chunks: AsyncThrowingStream<[Float], Error> { pipe.stream }

    func append(_ samples: [Float]) {
        lock.withLock {
            sampleCount += samples.count
            if sampleCount >= AssemblyAIChunker.target {
                pipe.continuation.finish(throwing: AssemblyAIEngineError.recordingTooLong)
            } else {
                pipe.continuation.yield(samples)
            }
        }
    }

    func finish() { pipe.continuation.finish() }
}

private nonisolated final class AssemblyAILiveResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var input: InputStream?
    private var body = Data()
    private var didTraceUpload = false
    let result = AsyncThrowingStream<(Data, URLResponse), Error>.makeStream()

    init(input: InputStream) { self.input = input }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        // The audio stream is consumed once. Recovery owns any replay.
        let stream = input
        input = nil
        completionHandler(stream)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !didTraceUpload, totalBytesSent >= 32_000 else { return }
        didTraceUpload = true
        PerfTrace.event("stt.assemblyAILiveBodySent", counts: ["sent_bytes": Int(totalBytesSent)])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            result.continuation.finish(throwing: error)
        } else if let response = task.response {
            result.continuation.yield((body, response))
            result.continuation.finish()
        } else {
            result.continuation.finish(throwing: AssemblyAIEngineError.invalidResponse)
        }
    }
}

nonisolated enum AssemblyAILiveUpload {
    static func send(_ request: URLRequest, prefix: Data, suffix: Data,
                     audio: AssemblyAILiveAudio) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 32_768, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw URLError(.cannotOpenFile) }

        let delegate = AssemblyAILiveResponse(input: input)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let upload = session.uploadTask(withStreamedRequest: request)
        upload.resume()
        // Only the writer accesses the output stream. The bound input is
        // consumed independently by URLSession.
        let writer = Task.detached { [output] in
            output.open()
            defer { output.close() }
            do {
                try await write(prefix, to: output)
                for try await samples in audio.chunks {
                    try await write(AssemblyAIEngine.pcmBytes(samples), to: output)
                }
                try Task.checkCancellation()
                try await write(suffix, to: output)
            } catch {
                if (error as? AssemblyAIEngineError) == .recordingTooLong {
                    PerfTrace.event("stt.assemblyAILiveHandoff")
                }
                delegate.result.continuation.finish(throwing: error)
                upload.cancel()
            }
        }
        defer {
            writer.cancel()
            session.invalidateAndCancel()
        }
        var responses = delegate.result.stream.makeAsyncIterator()
        guard let response = try await responses.next() else { throw CancellationError() }
        return response
    }

    private static func write(_ data: Data, to stream: OutputStream) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            if let error = stream.streamError { throw error }
            guard stream.hasSpaceAvailable else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            let written = data.withUnsafeBytes { bytes in
                stream.write(bytes.bindMemory(to: UInt8.self).baseAddress! + offset,
                             maxLength: data.count - offset)
            }
            guard written > 0 else { throw stream.streamError ?? URLError(.networkConnectionLost) }
            offset += written
        }
    }
}
