import XCTest
@testable import Dictate_Anywhere

/// `ParakeetEngine.joinChunkTranscripts` joins transcripts of **disjoint**
/// audio: `commitBufferedChunksIfNeeded` drops exactly one chunk per commit and
/// retains no overlap, so consecutive chunk transcripts never share speech.
/// The join must therefore add a separator and nothing else — never delete.
final class MergeTranscriptsTests: XCTestCase {
    // Existing Latin behavior must not regress
    func testLatinMergeInsertsSpace() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "hello world", addition: "how are you"),
                       "hello world how are you")
    }

    // CJK: no space injected at chunk boundaries
    func testCJKMergeNoSpace() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "今天天气很好", addition: "我们去公园吧"),
                       "今天天气很好我们去公园吧")
    }

    func testCJKMergeNoSpaceBeforeFullwidthPunctuation() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "今天天气很好", addition: "，我们去公园吧"),
                       "今天天气很好，我们去公园吧")
    }

    // CJK: no space injected after fullwidth terminal punctuation
    // (regression test for the endsWithCJK terminal-punctuation fix — see CJKText.swift)
    func testCJKMergeNoSpaceAfterTerminalPunctuation() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "今天天气很好。", addition: "我们去公园吧"),
                       "今天天气很好。我们去公园吧")
    }

    // Mixed boundary: CJK left side, Latin right side keeps the space
    func testMixedBoundaryKeepsSpaceBeforeLatin() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "我要去", addition: "Apple Park"),
                       "我要去 Apple Park")
    }

    // MARK: - Repeated speech across a disjoint seam must survive

    // The reviewer's failure case. Overlap deduplication used to collapse this
    // to "我真的不知道该怎么办", deleting a 不知道 the speaker actually said —
    // and the CJK overlap floor of 3 characters made 不知道 an exact match.
    func testRepeatedCJKPhraseAcrossSeamIsNotDeduplicated() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "我真的不知道", addition: "不知道该怎么办"),
                       "我真的不知道不知道该怎么办")
    }

    // Same hazard in Latin: a stutter or a genuine repeat at the seam is speech.
    func testRepeatedLatinPhraseAcrossSeamIsNotDeduplicated() {
        XCTAssertEqual(
            ParakeetEngine.joinChunkTranscripts(base: "the quick brown fox jumps", addition: "fox jumps over the dog"),
            "the quick brown fox jumps fox jumps over the dog")
    }

    // A short CJK addition that happens to repeat the tail of the base is not
    // containment — the audio underneath it is disjoint, so it must survive.
    func testAdditionContainedInBaseSurvives() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "我真的不知道", addition: "不知道"),
                       "我真的不知道不知道")
    }

    func testBaseContainedInAdditionSurvives() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "不知道", addition: "不知道该怎么办"),
                       "不知道不知道该怎么办")
    }

    // MARK: - Disjoint chunk seams (the shipping chunker's actual output)

    // commitBufferedChunksIfNeeded drops exactly one chunk per commit and keeps
    // no overlap, so consecutive chunk transcripts share no repeated audio. The
    // seam must join with nothing added and nothing dropped.
    func testDisjointCJKChunkSeamJoinsWithoutSpaceOrLoss() {
        let first = "今天天气很好我们打算"
        let second = "去公园散步然后回家"
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: first, addition: second), first + second)
    }

    // ASR's ITN commonly closes a truncated chunk with a fullwidth period even
    // mid-utterance; the next chunk must not gain a space after it.
    func testDisjointCJKChunkSeamAfterTruncationPunctuation() {
        let merged = ParakeetEngine.joinChunkTranscripts(base: "我们打算去公园。", addition: "散步然后回家")
        XCTAssertEqual(merged, "我们打算去公园。散步然后回家")
        XCTAssertNil(merged.range(of: #"\p{Han}\s+\p{Han}"#, options: .regularExpression))
    }

    // Latin chunks meeting at a disjoint seam still get exactly one space.
    func testDisjointLatinChunkSeamGetsSingleSpace() {
        XCTAssertEqual(
            ParakeetEngine.joinChunkTranscripts(base: "we are going to the", addition: "park this afternoon"),
            "we are going to the park this afternoon")
    }

    // The chunk length the seam tests split on must stay tied to production.
    func testChunkConstantsMatchProductionChunker() {
        XCTAssertEqual(ParakeetEngine.transcriptionSampleRate, 16_000)
        XCTAssertEqual(
            ParakeetEngine.chunkTranscriptionSampleCount,
            ParakeetEngine.transcriptionSampleRate * ParakeetEngine.chunkTranscriptionSeconds)
    }

    // MARK: - Opening CJK punctuation at a seam

    // 「『（【《〈 belong to the text that follows them, so inside CJK they take
    // no space before them either.
    func testNoSpaceBeforeOpeningCJKBracketAfterCJK() {
        for opener in ["「", "『", "（", "【", "《", "〈"] {
            XCTAssertEqual(
                ParakeetEngine.joinChunkTranscripts(base: "他说", addition: "\(opener)你好"),
                "他说\(opener)你好",
                "opener \(opener) should attach to CJK on its left")
        }
    }

    // After Latin the same opener keeps its ordinary word space.
    func testSpaceKeptBeforeOpeningCJKBracketAfterLatin() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "he said", addition: "「你好」"),
                       "he said 「你好」")
    }

    // A chunk truncated straight after an opener is still CJK on its left.
    func testNoSpaceAfterTrailingOpeningBracket() {
        let merged = ParakeetEngine.joinChunkTranscripts(base: "他说「", addition: "你好」")
        XCTAssertEqual(merged, "他说「你好」")
    }

    // Closing brackets keep attaching to the left regardless of what precedes.
    func testNoSpaceBeforeClosingCJKBracket() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "他说「你好", addition: "」然后走了"),
                       "他说「你好」然后走了")
    }

    // Base/addition passthroughs
    func testEmptySides() {
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "", addition: "你好"), "你好")
        XCTAssertEqual(ParakeetEngine.joinChunkTranscripts(base: "你好", addition: ""), "你好")
    }
}
