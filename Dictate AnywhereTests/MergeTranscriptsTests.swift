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

    // Base/addition passthroughs
    func testEmptySides() {
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "", addition: "你好"), "你好")
        XCTAssertEqual(ParakeetEngine.mergeTranscripts(base: "你好", addition: ""), "你好")
    }
}
