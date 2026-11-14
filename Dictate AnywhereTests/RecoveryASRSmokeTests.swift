import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Speech
import FluidAudio
@testable import Dictate_Anywhere

/// Exercises the actual file-recovery paths with a known speech fixture and
/// already-installed models. No microphone capture or model downloads.
@MainActor
final class RecoveryASRSmokeTests: XCTestCase {
    override func setUp() async throws {
        let recoveryEnabled = ProcessInfo.processInfo.environment["RUN_RECOVERY_ASR_TESTS"] == "1"
        #if PIPELINE_BENCHMARK
        let benchmarkEnabled = true
        #else
        let benchmarkEnabled = false
        #endif
        try XCTSkipUnless(recoveryEnabled || benchmarkEnabled,
                          "Set RUN_RECOVERY_ASR_TESTS=1 to test recovery with installed speech models")
    }

    func testBufferedModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .englishOnly)
    }

    func testStreamingModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .parakeetEou320)
    }

    func testMultilingualModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .multilingual)
    }

    func testNemotronModelRecoversSavedAudio() async throws {
        try await checkFluidAudioRecovery(model: .nemotron1120)
    }

    /// Exercise the same sliding-window/vocabulary configuration used for final
    /// dictation, without microphone access or the app's fallback hiding errors.
    func testVocabularyWindowsPreserveBeginningAndEnding() async throws {
        try XCTSkipUnless(ParakeetEngine().checkModelOnDisk(for: .englishOnly), "English Parakeet is not installed")
        let ctcDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ctcDirectory.path), "CTC model is not installed")
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
        let ctcModels = try await CtcModels.load(from: ctcDirectory)
        let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)
        let vocabulary = CustomVocabularyContext(terms: [
            CustomVocabularyTerm(text: "cancellation", ctcTokenIds: tokenizer.encode("cancellation"))
        ])
        let manager = SlidingWindowAsrManager(config: SlidingWindowAsrConfig(
            chunkSeconds: 11.0, hypothesisChunkSeconds: 1.0,
            leftContextSeconds: 2.0, rightContextSeconds: 2.0,
            minContextForConfirmation: 0.0, confirmationThreshold: 0.0))
        do {
            try await manager.configureVocabularyBoosting(
                vocabulary: vocabulary, ctcModels: ctcModels,
                config: ParakeetEngine.vocabularyRescorerConfig)
            try await manager.loadModels(models)
            try await manager.startStreaming(source: .microphone)
            let fixture = try fixtureSamples()
            let samples = fixture + [Float](repeating: 0, count: 8_000) + fixture
            XCTAssertGreaterThan(samples.count, 11 * 16_000, "Fixture must exercise multiple windows")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            for offset in stride(from: 0, to: samples.count, by: 16_000) {
                let chunk = Array(samples[offset..<min(offset + 16_000, samples.count)])
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.count)
                }
                await manager.streamAudio(buffer)
            }
            let text = try await manager.finish()
            await manager.cleanup()
            print("VOCABULARY_ASR: \(text)")
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            XCTAssertEqual(words.filter { $0 == "weather" }.count, 2, "A beginning was lost: \(text)")
            XCTAssertEqual(words.filter { $0 == "recording" }.count, 2, "Ordinary words were replaced: \(text)")
            XCTAssertEqual(words.filter { $0 == "cancellation" }.count, 2, "Vocabulary was inserted or an ending lost: \(text)")
        } catch {
            await manager.cleanup()
            throw error
        }
    }

    /// A false preflight must preserve the caller's exact transcript, while a
    /// real proper-name correction must still reach both acoustic backends.
    func testVocabularyPreflightPreservesCorrections() async throws {
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let files = FileManager.default
        try XCTSkipUnless(["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "CtcHead.mlmodelc", "tokenizer.json"].allSatisfy {
            files.fileExists(atPath: directory.appendingPathComponent($0).path)
        }, "Install vocabulary assets first; this check never downloads models")
        let ctcModels = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
        let samples = try fixtureSamples(named: "vocabulary-names")
        let name = "Solanki"
        var checked = 0
        for (choice, version) in [(ParakeetModelChoice.multilingual, AsrModelVersion.v3), (.compactEnglish, .tdtCtc110m)] {
            guard ParakeetEngine().checkModelOnDisk(for: choice) else { continue }
            let models = try AsrModels.loadLocal(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            let manager = AsrManager(config: BatchTranscriptionPolicy.asrConfig, models: models)
            var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
            let original = try await manager.transcribe(samples, decoderState: &state)
            let head = try await MLModel.load(contentsOf: directory.appendingPathComponent("CtcHead.mlmodelc"),
                                              configuration: models.configuration)
            let irrelevant = try await PreparedTDTVocabulary.prepare(models: models,
                terms: ["Czechoslovakia", "photosynthesis"], cachedCTCModels: ctcModels, cachedHead: head)
            let unchanged = try await irrelevant.rescore(original, samples: samples)
            XCTAssertEqual(unchanged, original.text, "Unrelated vocabulary changed the transcript for \(choice.rawValue)")
            XCTAssertFalse(original.text.localizedCaseInsensitiveContains(name),
                           "Refresh the fixture if the base model learns this name; the check must exercise a correction")
            let eligible = try await PreparedTDTVocabulary.prepare(models: models, terms: [name],
                cachedCTCModels: ctcModels, cachedHead: head)
            let corrected = try await eligible.rescore(original, samples: samples)
            XCTAssertTrue(corrected.localizedCaseInsensitiveContains(name),
                          "Preflight lost the eligible correction for \(choice.rawValue): \(corrected)")
            XCTAssertTrue(corrected.localizedCaseInsensitiveContains("said the accused appeared in court with covered faces"),
                          "Vocabulary correction dropped the words following the name for \(choice.rawValue): \(corrected)")
            await manager.cleanup()
            checked += 1
        }
        try XCTSkipUnless(checked > 0, "Install Parakeet v3 or 110M first")
    }

    private func checkFluidAudioRecovery(model: ParakeetModelChoice) async throws {
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: model), "\(model.displayName) is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        let oldMode = settings.transcriptPostProcessingMode
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            settings.transcriptPostProcessingMode = oldMode
        }
        settings.parakeetModelChoice = model
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .none
        try await engine.prepare()
        try await checkRecovery(using: engine)
    }

    func testAppleSpeechRecoversSavedAudio() async throws {
        try XCTSkipUnless(AppleSpeechEngine.isSupported, "Apple Speech is unavailable")
        let installed = await AppleSpeechEngine.installedLanguages()
        try XCTSkipUnless(installed.contains(.english), "English Apple Speech assets are not installed")
        let oldLanguage = Settings.shared.appleSpeechLanguage
        defer { Settings.shared.appleSpeechLanguage = oldLanguage }
        Settings.shared.appleSpeechLanguage = .english
        try await checkRecovery(using: AppleSpeechEngine())
    }

    /// Replays one saved speech fixture through the real offline transcription
    /// paths. Gated because it requires installed models and is intentionally
    /// slower than the normal test suite.
    func testRepeatableOfflineASRBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable the offline ASR benchmark")
        #else
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let capture = try store.beginCapture()
        capture.append(try fixtureSamples())
        let preserved = try await store.preserve(capture, preview: "", completedTranscript: nil)
        let entry = try XCTUnwrap(preserved)
        let audioURL = store.audioURL(id: entry.id)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        let oldAppleSpeechLanguage = settings.appleSpeechLanguage
        let oldMode = settings.transcriptPostProcessingMode
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            settings.appleSpeechLanguage = oldAppleSpeechLanguage
            settings.transcriptPostProcessingMode = oldMode
            PerfTrace.clearSessionMetadata()
        }

        let choice = ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_MODEL"] ?? "parakeetEou320"
        let models: [ParakeetModelChoice]
        if choice == "all" {
            models = ParakeetModelChoice.allCases.filter { $0.isAvailableOnThisMac }
        } else {
            models = [try XCTUnwrap(ParakeetModelChoice(rawValue: choice), "Unknown benchmark model: \(choice)")]
        }
        var didRun = false
        for model in models {
            PerfTrace.clearSessionMetadata()
            let engine = ParakeetEngine()
            guard engine.checkModelOnDisk(for: model) else {
                print("REPRO_ASR_BENCHMARK model=\(model.rawValue) skipped=not_installed")
                continue
            }
            settings.parakeetModelChoice = model
            settings.selectedLanguage = .english
            settings.transcriptPostProcessingMode = .none
            let loadStart = ContinuousClock.now
            try await engine.prepare()
            print("REPRO_ASR_BENCHMARK model=\(model.rawValue) model_load_ms=\(BenchmarkStatistics.elapsedMilliseconds(from: loadStart))")
            try await benchmark(
                engine: engine,
                name: "parakeet",
                model: model.rawValue,
                audioURL: audioURL,
                audioSeconds: audioSeconds,
                iterations: iterations
            )
            didRun = true
        }

        if AppleSpeechEngine.isSupported {
            PerfTrace.clearSessionMetadata()
            let engine = AppleSpeechEngine()
            settings.appleSpeechLanguage = .english
            let installed = await AppleSpeechEngine.installedLanguages()
            if installed.contains(.english) { try await engine.prepare() }
            if engine.isReady {
                try await benchmark(
                    engine: engine,
                    name: "appleSpeech",
                    model: "english",
                    audioURL: audioURL,
                    audioSeconds: audioSeconds,
                    iterations: iterations
                )
                didRun = true
            }
        }

        try XCTSkipUnless(didRun, "No selected offline ASR model or installed Apple Speech asset is available")

        #endif
    }

    /// Uses four existing TTS fixtures with known references. Only runs when
    /// SenseVoice is already installed; the benchmark never downloads models.
    func testInstalledMandarinASRBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable Mandarin ASR benchmark")
        #else
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: .senseVoice), "SenseVoice is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            PerfTrace.clearSessionMetadata()
        }
        settings.parakeetModelChoice = .senseVoice
        settings.selectedLanguage = .chinese
        try await engine.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mandarin-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)

        for (fixture, reference) in MandarinFixtureTests.references.sorted(by: { $0.key < $1.key }) {
            let capture = try store.beginCapture()
            capture.append(try fixtureSamples(named: fixture))
            let saved = try await store.preserve(capture, preview: "", completedTranscript: nil)
            let entry = try XCTUnwrap(saved)
            let url = store.audioURL(id: entry.id)
            var latencies: [Double] = []
            var worstCER = 0.0
            for iteration in 1...max(1, Int(ProcessInfo.processInfo.environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3) {
                PerfTrace.setSessionMetadata([
                    "session_id": "benchmark-\(fixture)-\(iteration)", "engine": "parakeet",
                    "model": "senseVoice", "language": "chinese", "benchmark": "offline_asr"
                ])
                let start = ContinuousClock.now
                let text = try await engine.transcribeRecording(at: url)
                latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
                worstCER = max(worstCER, characterErrorRate(reference: reference, hypothesis: text))
            }
            BenchmarkStatistics(latencies).report(
                component: "mandarin_asr", details: "fixture=\(fixture) worst_cer=\(String(format: "%.3f", worstCER))"
            )
            XCTAssertLessThanOrEqual(worstCER, fixture == "zh-mixed" ? 0.5 : 0.3)
            try store.remove(id: entry.id)
        }
        #endif
    }

    /// An opt-in human-speech fixture can be passed without bundling or
    /// uploading its contents. Both audio and its exact reference are required.
    func testUserSuppliedSpeechFixtureBenchmark() async throws {
        #if !PIPELINE_BENCHMARK
        throw XCTSkip("Run scripts/dev.sh benchmark to enable speech fixture benchmark")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["PIPELINE_BENCHMARK_AUDIO_PATH"],
              let referencePath = environment["PIPELINE_BENCHMARK_REFERENCE_PATH"] else {
            throw XCTSkip("Set PIPELINE_BENCHMARK_AUDIO_PATH and PIPELINE_BENCHMARK_REFERENCE_PATH")
        }
        let url = URL(fileURLWithPath: audioPath)
        let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
        let reader = try RecoveryAudioReader(url: url)
        try XCTSkipUnless(reader.nextSamples() != nil && !reference.isEmpty, "Empty fixture or reference")
        let modelName = environment["PIPELINE_BENCHMARK_MODEL"] ?? "parakeetEou320"
        let model = try XCTUnwrap(ParakeetModelChoice(rawValue: modelName), "Select one model for a supplied fixture")
        let engine = ParakeetEngine()
        try XCTSkipUnless(engine.checkModelOnDisk(for: model), "Selected speech model is not installed")
        let settings = Settings.shared
        let oldModel = settings.parakeetModelChoice
        let oldLanguage = settings.selectedLanguage
        defer {
            settings.parakeetModelChoice = oldModel
            settings.selectedLanguage = oldLanguage
            PerfTrace.clearSessionMetadata()
        }
        settings.parakeetModelChoice = model
        settings.selectedLanguage = .english
        try await engine.prepare()
        let count = max(1, Int(environment["PIPELINE_BENCHMARK_ITERATIONS"] ?? "3") ?? 3)
        var latencies: [Double] = []
        var worstWER = 0.0
        for iteration in 1...count {
            PerfTrace.setSessionMetadata([
                "session_id": "benchmark-user-\(iteration)", "engine": "parakeet",
                "model": model.rawValue, "language": "english", "benchmark": "offline_asr"
            ])
            let start = ContinuousClock.now
            let text = try await engine.transcribeRecording(at: url)
            latencies.append(BenchmarkStatistics.elapsedMilliseconds(from: start))
            worstWER = max(worstWER, benchmarkWordErrorRate(reference: reference, hypothesis: text))
        }
        BenchmarkStatistics(latencies).report(
            component: "user_speech_asr", details: "model=\(model.rawValue) worst_wer=\(String(format: "%.3f", worstWER))"
        )
        if let threshold = environment["PIPELINE_BENCHMARK_MAX_WER"].flatMap(Double.init) {
            XCTAssertLessThanOrEqual(worstWER, threshold)
        }
        #endif
    }



    private func benchmark(
        engine: TranscriptionEngine,
        name: String,
        model: String,
        audioURL: URL,
        audioSeconds: Double,
        iterations: Int
    ) async throws {
        var latencies: [Double] = []
        for iteration in 1...iterations {
            PerfTrace.setSessionMetadata([
                "session_id": "benchmark-\(name)-\(iteration)",
                "benchmark": "offline_asr",
                "iteration": String(iteration),
                "engine": name,
                "model": model,
                "language": "english",
                "cleanup_mode": "none",
                "s1_mini_enabled": "false",
                "filler_removal_enabled": "false",
                "context_awareness_enabled": "false"
            ])
            let startedAt = ContinuousClock.now
            let text = try await engine.transcribeRecording(at: audioURL)
            let elapsed = BenchmarkStatistics.elapsedMilliseconds(from: startedAt)
            latencies.append(elapsed)
            XCTAssertFalse(text.isEmpty, "\(name) benchmark produced no transcript")
            XCTAssertTrue(text.localizedCaseInsensitiveContains("weather"), "\(name) lost the fixture beginning")
            XCTAssertTrue(text.localizedCaseInsensitiveContains("cancellation"), "\(name) lost the fixture ending")
            print("REPRO_ASR_BENCHMARK engine=\(name) model=\(model) iteration=\(iteration) elapsed_ms=\(elapsed)")
        }
        BenchmarkStatistics(latencies).report(
            component: "offline_asr",
            details: "engine=\(name) model=\(model) audio_seconds=\(String(format: "%.3f", audioSeconds)) "
                + "median_rtf=\(String(format: "%.3f", BenchmarkStatistics(latencies).p50 / 1_000 / audioSeconds))"
        )
    }

    private func checkRecovery(using engine: TranscriptionEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-asr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let capture = try store.beginCapture()
        capture.append(try fixtureSamples())
        _ = try await store.preserve(capture, preview: "", completedTranscript: nil)
        let relaunched = DictationRecoveryStore(directory: directory)
        try relaunched.reload()
        let entry = try XCTUnwrap(relaunched.entries.first)
        let text = try await engine.transcribeRecording(at: relaunched.audioURL(id: entry.id))
        print("RECOVERY_ASR \(type(of: engine)): \(text)")
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("weather"), "Beginning of recording missing: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("cancellation"), "End of recording missing: \(text)")
    }

    private func fixtureSamples(named name: String = "en-recovery") throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1_024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard !fed else { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
