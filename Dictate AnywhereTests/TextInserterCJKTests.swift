import XCTest
@testable import Dictate_Anywhere_Dev

final class TextInserterCJKTests: XCTestCase {
    // Terminal punctuation detection
    func testCJKTerminalPunctuationRecognized() {
        XCTAssertTrue(TextInserter.hasTerminalPunctuation("你好。"))
        XCTAssertTrue(TextInserter.hasTerminalPunctuation("真的吗？"))
        XCTAssertTrue(TextInserter.hasTerminalPunctuation("太好了！"))
        XCTAssertTrue(TextInserter.hasTerminalPunctuation("他说「你好。」")) // CJK closer after terminal
        XCTAssertFalse(TextInserter.hasTerminalPunctuation("你好"))
    }

    // Auto-appended period picks the right script
    func testNormalizedForInsertionAppendsCJKPeriod() {
        XCTAssertEqual(TextInserter.normalizedForInsertion("你好"), "你好。")
        XCTAssertEqual(TextInserter.normalizedForInsertion("你好。"), "你好。")   // no double period
        XCTAssertEqual(TextInserter.normalizedForInsertion("hello"), "hello.")
        XCTAssertEqual(TextInserter.normalizedForInsertion("我要去 Apple Park"), "我要去 Apple Park.") // ends Latin → ASCII period
        XCTAssertEqual(TextInserter.normalizedForInsertion("他说「你好」"), "他说「你好」。") // closer-skipping
        XCTAssertEqual(TextInserter.normalizedForInsertion("  你好  "), "你好。")
        XCTAssertEqual(TextInserter.normalizedForInsertion(""), "")
    }

    // Separator suppression
    func testAttachedPunctuationIncludesCJK() {
        XCTAssertTrue(TextInserter.startsWithAttachedPunctuation("，继续"))
        XCTAssertTrue(TextInserter.startsWithAttachedPunctuation("。"))
        XCTAssertFalse(TextInserter.startsWithAttachedPunctuation("你好"))
    }

    func testNoSeparatorBeforeCJKText() {
        XCTAssertFalse(TextInserter.needsSeparator(before: "你好"))
        XCTAssertTrue(TextInserter.needsSeparator(before: "hello"))
        XCTAssertFalse(TextInserter.needsSeparator(before: "，好的"))
    }
}
