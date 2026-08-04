import XCTest
@testable import Dictate_Anywhere_Dev

final class MergeTranscriptsTests: XCTestCase {
    // Existing Latin behavior must not regress
    func testLatinMergeInsertsSpace() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "hello world", addition: "how are you"),
                       "hello world how are you")
    }

    func testLatinOverlapMerge() {
        XCTAssertEqual(
            ParakeetEngine.mergeTranscripts(base: "the quick brown fox jumps", addition: "fox jumps over the dog"),
            "the quick brown fox jumps over the dog")
    }

    // CJK: no space injected at chunk boundaries
    func testCJKMergeNoSpace() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "今天天气很好", addition: "我们去公园吧"),
                       "今天天气很好我们去公园吧")
    }

    func testCJKMergeNoSpaceBeforeFullwidthPunctuation() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "今天天气很好", addition: "，我们去公园吧"),
                       "今天天气很好，我们去公园吧")
    }

    // CJK: no space injected after fullwidth terminal punctuation with no overlap match
    // (regression test for the endsWithCJK terminal-punctuation fix — see CJKText.swift)
    func testCJKMergeNoSpaceAfterTerminalPunctuation() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "今天天气很好。", addition: "我们去公园吧"),
                       "今天天气很好。我们去公园吧")
    }

    // CJK: short overlaps (< 8 chars) are detected
    func testCJKShortOverlapDetected() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "我们明天去公园", addition: "去公园散步"),
                       "我们明天去公园散步")
    }

    // Mixed boundary: CJK left side, Latin right side keeps the space
    func testMixedBoundaryKeepsSpaceBeforeLatin() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "我要去", addition: "Apple Park"),
                       "我要去 Apple Park")
    }

    // MARK: - Disjoint chunk seams (the shipping chunker's actual output)

    // commitBufferedChunksIfNeeded drops exactly one chunk per commit and keeps
    // no overlap, so consecutive chunk transcripts share no repeated audio. The
    // seam must join with nothing added and nothing dropped.
    func testDisjointCJKChunkSeamJoinsWithoutSpaceOrLoss() {
        let first = "今天天气很好我们打算"
        let second = "去公园散步然后回家"
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: first, addition: second), first + second)
    }

    // ASR's ITN commonly closes a truncated chunk with a fullwidth period even
    // mid-utterance; the next chunk must not gain a space after it.
    func testDisjointCJKChunkSeamAfterTruncationPunctuation() {
        let merged = ParakeetEngine.mergeTranscripts(base: "我们打算去公园。", addition: "散步然后回家")
        XCTAssertEqual(merged, "我们打算去公园。散步然后回家")
        XCTAssertNil(merged.range(of: #"\p{Han}\s+\p{Han}"#, options: .regularExpression))
    }

    // Latin chunks meeting at a disjoint seam still get exactly one space.
    func testDisjointLatinChunkSeamGetsSingleSpace() {
        XCTAssertEqual(
            ParakeetEngine.mergeTranscripts(base: "we are going to the", addition: "park this afternoon"),
            "we are going to the park this afternoon")
    }

    // The chunk length the seam tests split on must stay tied to production.
    func testChunkConstantsMatchProductionChunker() {
        XCTAssertEqual(ParakeetEngine.transcriptionSampleRate, 16_000)
        XCTAssertEqual(
            ParakeetEngine.chunkTranscriptionSampleCount,
            ParakeetEngine.transcriptionSampleRate * ParakeetEngine.chunkTranscriptionSeconds)
    }

    // Base/addition passthroughs
    func testEmptySides() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "", addition: "你好"), "你好")
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "你好", addition: ""), "你好")
    }
}
