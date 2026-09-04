import XCTest
import AVFoundation
import FluidAudio
@testable import Dictate_Anywhere

/// Character error rate over punctuation-and-whitespace-stripped text.
func characterErrorRate(reference: String, hypothesis: String) -> Double {
    func strip(_ s: String) -> [Character] {
        s.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }.map { $0 }
    }
    let ref = strip(reference), hyp = strip(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    var dist = Array(0...hyp.count)
    for i in 1...ref.count {
        var prev = dist[0]; dist[0] = i
        for j in 1...max(hyp.count, 1) where !hyp.isEmpty {
            let cost = ref[i-1] == hyp[j-1] ? 0 : 1
            let next = min(dist[j] + 1, dist[j-1] + 1, prev + cost)
            prev = dist[j]; dist[j] = next
        }
    }
    return Double(dist[hyp.count]) / Double(ref.count)
}

final class MandarinFixtureTests: XCTestCase {
    static let references: [String: String] = [
        "zh-short": "今天天气很好。",
        "zh-question": "你明天有时间吗？",
        "zh-numbers": "我们三点半开会，会议大概持续两个小时。",
        "zh-mixed": "我明天要去 Apple Park 开会。",
    ]

    private static var manager: SenseVoiceManager?

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_MANDARIN_ASR_TESTS"] == "1",
            "Set RUN_MANDARIN_ASR_TESTS=1 to run Mandarin ASR fixture tests (downloads ~225 MB on first run)")
        if Self.manager == nil {
            // Match shipping: fp32 encoder on non-ANE hardware, int8 otherwise.
            let models = try await SenseVoiceModels.downloadAndLoad(
                precision: ParakeetEngine.senseVoiceEncoderPrecision)
            Self.manager = SenseVoiceManager(models: models, textNorm: 14)
        }
    }

    private func samples(for fixture: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: fixture, withExtension: "wav"),
            "\(fixture).wav missing from test bundle")
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let ratio = 16_000.0 / file.processingFormat.sampleRate
        let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * ratio) + 1024)!
        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return inBuf
        }
        if let convError { throw convError }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    private func transcribe(_ fixture: String) async throws -> String {
        try await XCTUnwrap(Self.manager).transcribe(audio: samples(for: fixture))
    }

    func testShortSentenceAccuracyAndPunctuation() async throws {
        let text = try await transcribe("zh-short")
        XCTAssertLessThanOrEqual(characterErrorRate(reference: Self.references["zh-short"]!, hypothesis: text), 0.2, "transcript: \(text)")
        XCTAssertTrue(text.hasSuffix("\u{3002}"), "expected trailing 。 in: \(text)")
    }

    func testQuestionGetsQuestionMark() async throws {
        let text = try await transcribe("zh-question")
        XCTAssertLessThanOrEqual(characterErrorRate(reference: Self.references["zh-question"]!, hypothesis: text), 0.2, "transcript: \(text)")
        XCTAssertTrue(text.hasSuffix("\u{FF1F}"), "expected trailing ？ in: \(text)")
    }

    func testNumbersSentence() async throws {
        let text = try await transcribe("zh-numbers")
        XCTAssertLessThanOrEqual(characterErrorRate(reference: Self.references["zh-numbers"]!, hypothesis: text), 0.25, "transcript: \(text)")
    }

    func testCodeSwitchKeepsEnglishTerm() async throws {
        let text = try await transcribe("zh-mixed")
        // TTS renders English words with a Chinese voice, so the surrounding
        // Han transcription is shakier than the pure-zh fixtures — keep the CER
        // bound lenient and rely on the printed transcript for human review.
        XCTAssertLessThanOrEqual(characterErrorRate(reference: Self.references["zh-mixed"]!, hypothesis: text), 0.5, "transcript: \(text)")
        // ...but that bound alone would pass with the English term dropped
        // entirely, which is the whole point of this fixture. Assert it
        // survives, tolerating the two things the model legitimately varies:
        // casing (it currently emits lowercase "apple park") and the internal
        // gap (`\s*` covers "Apple Park", "applepark", and any run of spaces).
        // No \b anchors: Han characters are word characters to ICU, so there is
        // no boundary between 去 and "apple" and the pattern would never match.
        XCTAssertNotNil(
            text.range(of: #"apple\s*park"#, options: [.regularExpression, .caseInsensitive]),
            "English term \"Apple Park\" did not survive transcription: \(text)")
        print("code-switch transcript: \(text)")
    }

    /// Reproduces the shipping chunker rather than an idealized one.
    ///
    /// `ParakeetEngine.commitBufferedChunksIfNeeded` commits fixed-size chunks
    /// and then drops exactly that many samples, retaining **no** overlap, and
    /// the finalize path transcribes whatever tail is left over. Consecutive
    /// chunk transcripts therefore meet at a hard seam with no repeated audio —
    /// which is why `joinChunkTranscripts` concatenates rather than
    /// deduplicating. This splits the fixture on the same boundary, using the
    /// production constant so the two cannot drift.
    func testLongAudioSplitMergeMatchesFullTranscription() async throws {
        let all = try samples(for: "zh-long")
        let chunk = ParakeetEngine.chunkTranscriptionSampleCount
        let minimumTailSamples = 8_000  // finalize skips a shorter tail
        try XCTSkipUnless(
            all.count > chunk + minimumTailSamples,
            "zh-long fixture must exceed one \(ParakeetEngine.chunkTranscriptionSeconds) s chunk plus a tail — regenerate")
        let manager = try XCTUnwrap(Self.manager)
        let full = try await manager.transcribe(audio: all)

        var merged = ""
        var seamOffsets: [Int] = []
        for start in stride(from: 0, to: all.count, by: chunk) {
            let slice = Array(all[start..<min(start + chunk, all.count)])
            // Production drops a sub-8000-sample tail instead of transcribing it.
            if slice.count <= minimumTailSamples { break }
            let text = try await manager.transcribe(audio: slice)
            if !merged.isEmpty { seamOffsets.append(merged.count) }
            merged = ParakeetEngine.joinChunkTranscripts(base: merged, addition: text)
        }

        XCTAssertFalse(seamOffsets.isEmpty, "fixture produced no chunk seam to exercise")
        XCTAssertLessThanOrEqual(characterErrorRate(reference: full, hypothesis: merged), 0.15,
            "merged: \(merged)\nfull: \(full)")
        // CER strips whitespace, so check space injection separately: pure-zh
        // audio must not gain spaces between Han characters at the merge seam.
        XCTAssertNil(merged.range(of: #"\p{Han}\s+\p{Han}"#, options: .regularExpression),
            "space injected between Han characters: \(merged)")
        print("chunked transcript (seams at \(seamOffsets)): \(merged)")
        print("full transcript: \(full)")
    }

    /// Optional real-voice fixture (TTS audio is artificially easy for ASR).
    /// Record `zh-real.wav` (16 kHz mono) with a matching `zh-real.txt`
    /// reference transcript and drop both in Fixtures/ — the test activates
    /// automatically; it skips when the files are absent.
    func testRealVoiceFixtureIfPresent() async throws {
        guard let wav = Bundle(for: Self.self).url(forResource: "zh-real", withExtension: "wav"),
              let txt = Bundle(for: Self.self).url(forResource: "zh-real", withExtension: "txt") else {
            throw XCTSkip("zh-real.wav/.txt not present — record a real-voice fixture to enable")
        }
        _ = wav
        let reference = try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = try await transcribe("zh-real")
        XCTAssertLessThanOrEqual(characterErrorRate(reference: reference, hypothesis: text), 0.3, "transcript: \(text)")
    }
}
