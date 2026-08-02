import XCTest
@testable import Dictate_Anywhere_Dev

final class CJKTextTests: XCTestCase {
    func testIsCJKForHanCharacters() {
        XCTAssertTrue(CJKText.isCJK("你".unicodeScalars.first!))
        XCTAssertTrue(CJKText.isCJK("好".unicodeScalars.first!))
        XCTAssertFalse(CJKText.isCJK("a".unicodeScalars.first!))
        XCTAssertFalse(CJKText.isCJK("。".unicodeScalars.first!)) // punctuation is not Han
    }

    func testStartsWithCJK() {
        XCTAssertTrue(CJKText.startsWithCJK("你好 world"))
        XCTAssertFalse(CJKText.startsWithCJK("hello 你好"))
        XCTAssertFalse(CJKText.startsWithCJK(""))
    }

    func testEndsWithCJKSkipsClosers() {
        XCTAssertTrue(CJKText.endsWithCJK("hello 你好"))
        XCTAssertTrue(CJKText.endsWithCJK("他说「你好」"))   // skips 」
        XCTAssertTrue(CJKText.endsWithCJK("（你好）"))       // skips ）
        XCTAssertFalse(CJKText.endsWithCJK("你好 world"))
        XCTAssertFalse(CJKText.endsWithCJK(""))
    }

    func testEndsWithCJKSkipsTerminalPunctuation() {
        XCTAssertTrue(CJKText.endsWithCJK("你好。"))       // skips 。 (fullwidth period)
        XCTAssertTrue(CJKText.endsWithCJK("你好。」"))     // skips closer, then terminal punctuation
        XCTAssertFalse(CJKText.endsWithCJK("hello."))      // ASCII period is not CJK content
    }

    func testPunctuationSets() {
        XCTAssertTrue(CJKText.cjkTerminalPunctuation.contains(0x3002))  // 。
        XCTAssertTrue(CJKText.cjkTerminalPunctuation.contains(0xFF01))  // ！
        XCTAssertTrue(CJKText.cjkTerminalPunctuation.contains(0xFF1F))  // ？
        XCTAssertTrue(CJKText.cjkClosingPunctuation.contains(0x300D))   // 」
        XCTAssertTrue(CJKText.cjkAttachedLeadingPunctuation.contains(0xFF0C)) // ，
    }
}
