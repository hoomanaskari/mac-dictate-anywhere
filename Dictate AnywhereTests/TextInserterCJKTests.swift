import XCTest
@testable import Dictate_Anywhere

final class TextInserterCJKTests: XCTestCase {
    func testNormalizedForInsertionNeverInventsPunctuation() {
        XCTAssertEqual(TextInserter.normalizedForInsertion("你好"), "你好")
        XCTAssertEqual(TextInserter.normalizedForInsertion("你好。"), "你好。")
        XCTAssertEqual(TextInserter.normalizedForInsertion("hello"), "hello")
        XCTAssertEqual(TextInserter.normalizedForInsertion("hello?"), "hello?")
        XCTAssertEqual(TextInserter.normalizedForInsertion("  你好  "), "你好")
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
