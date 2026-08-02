import XCTest
import AVFoundation
import FluidAudio
@testable import Dictate_Anywhere_Dev

final class NemotronMultilingualSmokeTests: XCTestCase {
    func testStreamsMandarinFixtureToChineseTranscript() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_NEMOTRON_ASR_TESTS"] == "1",
            "Set RUN_NEMOTRON_ASR_TESTS=1 to run (downloads ~1 GB on first run)")

        let manager = StreamingNemotronMultilingualAsrManager(configuration: nil)
        let variantDir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: 1120, to: nil, progressHandler: nil)
        try await manager.loadModels(from: variantDir)
        await manager.setLanguage("zh-CN")

        // Reuse the WAV-loading approach from MandarinFixtureTests (duplicate the
        // helper locally — test classes don't share helpers across files unless
        // extracted; copying ~20 lines is acceptable here).
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "zh-short", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length) + 1024)!
        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true; s.pointee = .haveData; return inBuf
        }
        if let convError { throw convError }
        let samples = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))

        // Feed in 80 ms chunks like streamingTranscriptionLoop does.
        let chunk = 16_000 * 80 / 1000
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            _ = try await manager.process(samples: Array(samples[offset..<end]))
            offset = end
        }
        let text = try await manager.finish()
        await manager.cleanup()

        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.unicodeScalars.contains(where: { CJKText.isCJK($0) }), "expected Han output: \(text)")
        XCTAssertTrue(text.contains("\u{5929}\u{6C14}"), "expected 天气 in: \(text)")  // 天气
    }
}
