import AVFoundation
import FoundationModels
import XCTest
@testable import Dictate_Anywhere

/// Opt-in production-code workloads that need no microphone, Accessibility,
/// installed speech model, network connection, or target application.
@MainActor
final class PipelineWorkloadBenchmarkTests: XCTestCase {
    private var iterations: Int {
        min(10, max(2, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3))
    }

    private func requireBenchmark() throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable workload benchmarks")
        #endif
    }

    private var measureOptions: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }

    /// A 4096-frame tap buffer converted into the 16 kHz mono buffer sent to
    /// ASR. This times the app's allocation/copy, not a hardware callback.
    func testPCMBufferConstruction() throws {
        try requireBenchmark()
        let samples = (0..<4_096).map { sin(Float($0) * 0.07) * 0.1 }
        var last: AVAudioPCMBuffer?
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: measureOptions) {
            for _ in 0..<200 { last = try? makePCMBuffer(from: samples) }
        }
        XCTAssertEqual(last?.frameLength, 4_096)
        XCTAssertEqual(try XCTUnwrap(last?.floatChannelData?[0][1]), samples[1], accuracy: 0.0001)
        print("PIPELINE_BENCHMARK component=pcm_buffer buffers_per_measurement=200 input_samples=4096")
    }

    /// Both the sample map and multipart Data growth are on the cloud-engine
    /// stop path. A 60 s synthetic recording exercises real request sizing.
    func testAssemblyAIRequestEncoding() throws {
        try requireBenchmark()
        let samples = [Float](repeating: 0.125, count: 60 * AssemblyAIEngine.sampleRate)
        let config = AssemblyAIRequestConfiguration(
            sampleRate: AssemblyAIEngine.sampleRate,
            channels: 1,
            languageCodes: ["en"],
            sttPrompt: nil,
            keytermsPrompt: ["microphone"],
            llmInstruction: nil
        )
        var lastBody = Data()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: measureOptions) {
            let audio = AssemblyAIEngine.pcm16Data(from: samples)
            lastBody = (try? AssemblyAIEngine.multipartBody(
                config: config, pcmAudio: audio, boundary: "benchmark-boundary"
            )) ?? Data()
        }
        XCTAssertGreaterThan(lastBody.count, samples.count * MemoryLayout<Int16>.size)
        print("PIPELINE_BENCHMARK component=assembly_ai_request input_samples=\(samples.count) body_bytes=\(lastBody.count)")
    }

    /// Fixed disjoint chunks reveal long-dictation string-growth costs while
    /// preserving the exact production seam and cleanup functions.
    func testLongTranscriptAssemblyAndNormalization() throws {
        try requireBenchmark()
        let segments = (0..<300).map { "Meeting item \($0) recorded for the team." }
        var output = ""
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: measureOptions) {
            var joined = ""
            for segment in segments {
                joined = ParakeetEngine.joinChunkTranscripts(base: joined, addition: segment)
            }
            output = normalizePostProcessedTranscript(joined)
        }
        XCTAssertTrue(output.contains("Meeting item 0"))
        XCTAssertTrue(output.contains("Meeting item 299"))
        print("PIPELINE_BENCHMARK component=long_transcript segments=300 output_chars=\(output.count)")
    }

    /// Exercises the actual callback-queue writer, close/preserve, reload and
    /// bounded reader separately. Setup and temporary cleanup are unmeasured.
    func testRecoveryWriteAndRead() async throws {
        try requireBenchmark()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = [Float](repeating: 0.125, count: 16_000)
        var saveTimes: [Double] = []
        var readTimes: [Double] = []

        for _ in 0..<iterations {
            let store = DictationRecoveryStore(directory: directory)
            let capture = try store.beginCapture()
            let saveStart = ContinuousClock.now
            for _ in 0..<30 { capture.append(chunk) }
            let saved = try await store.preserve(capture, preview: "", completedTranscript: nil)
            let entry = try XCTUnwrap(saved)
            saveTimes.append(BenchmarkStatistics.elapsedMilliseconds(from: saveStart))
            let readStart = ContinuousClock.now
            let relaunched = DictationRecoveryStore(directory: directory)
            try relaunched.reload()
            let reader = try RecoveryAudioReader(url: relaunched.audioURL(id: entry.id))
            var sampleCount = 0
            var firstSample: Float?
            while let samples = try reader.nextSamples() {
                if firstSample == nil { firstSample = samples.first }
                sampleCount += samples.count
            }
            readTimes.append(BenchmarkStatistics.elapsedMilliseconds(from: readStart))
            XCTAssertEqual(sampleCount, 30 * chunk.count)
            XCTAssertEqual(try XCTUnwrap(firstSample), 0.125, accuracy: 0.0001)
            try relaunched.remove(id: entry.id)
        }
        BenchmarkStatistics(saveTimes).report(component: "recovery_save", details: "audio_seconds=30")
        BenchmarkStatistics(readTimes).report(component: "recovery_reload_read", details: "audio_seconds=30")
    }

    /// Uses the app's validated installed model (or an explicit model path);
    /// never downloads. Cold request and warm requests are reported separately.
    func testS1MiniCleanupWithInstalledModel() async throws {
        try requireBenchmark()
        let url: URL
        if let path = ProcessInfo.processInfo.environment["S1_MINI_MODEL_PATH"], !path.isEmpty {
            url = URL(fileURLWithPath: path)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "S1-mini model path does not exist")
        } else {
            let manager = S1MiniModelManager()
            try XCTSkipUnless(manager.isModelDownloaded, "S1-mini is not installed")
            url = try await manager.validatedModelURL()
        }
        defer { PerfTrace.clearSessionMetadata() }
        await S1MiniPostProcessingService.unload()

        do {
            for (name, text) in [
                ("short", "Um, I think we should send the report tomorrow."),
                ("long", Array(repeating: "We reviewed the project and agreed on the next steps.", count: 12)
                    .joined(separator: " "))
            ] {
                var latencies: [Double] = []
                for iteration in 1...iterations {
                    PerfTrace.setSessionMetadata([
                        "session_id": "benchmark-s1-\(name)-\(iteration)", "engine": "s1Mini",
                        "model": "s1Mini", "language": "english", "benchmark": "cleanup"
                    ])
                    let start = ContinuousClock.now
                    let output = try await S1MiniPostProcessingService.process(
                        text: text, modelURL: url, styling: .semiFormal,
                        structure: .prose, contextSetting: .general, context: nil
                    )
                    latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
                    XCTAssertFalse(output.isEmpty)
                }
                print("PIPELINE_BENCHMARK component=s1_mini_cleanup fixture=\(name) first_request_ms=\(latencies[0]) cold_model=\(name == "short")")
                if latencies.count > 1 {
                    BenchmarkStatistics(Array(latencies.dropFirst())).report(
                        component: "s1_mini_cleanup_warm", details: "fixture=\(name) input_chars=\(text.count)"
                    )
                }
            }
        } catch {
            await S1MiniPostProcessingService.unload()
            throw error
        }
        await S1MiniPostProcessingService.unload()
    }

    func testAppleIntelligenceCleanupWhenAvailable() async throws {
        try requireBenchmark()
        guard #available(macOS 26, *) else { throw XCTSkip("Foundation Models requires macOS 26") }
        guard case .available = AIPostProcessingService.availability else {
            throw XCTSkip("Apple Intelligence is not available on this Mac")
        }
        let text = "Um, please send the report tomorrow morning."
        defer { PerfTrace.clearSessionMetadata() }
        var latencies: [Double] = []
        for iteration in 1...iterations {
            PerfTrace.setSessionMetadata([
                "session_id": "benchmark-foundation-\(iteration)", "engine": "appleIntelligence",
                "model": "system", "language": "english", "benchmark": "cleanup"
            ])
            let start = ContinuousClock.now
            let output = try await AIPostProcessingService.process(
                text: text, prompt: "Remove filler words and preserve the user's intent."
            )
            latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
            XCTAssertFalse(output.isEmpty)
        }
        BenchmarkStatistics(latencies).report(component: "apple_intelligence_cleanup", details: "input_chars=\(text.count)")
    }
}
