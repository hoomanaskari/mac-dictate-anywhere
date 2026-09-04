import XCTest
@testable import Dictate_Anywhere

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

    /// A chunk truncated straight after an opener is still CJK content: the
    /// scan looks past 「 to 说 so the next chunk joins without a space.
    func testEndsWithCJKSkipsOpeningBrackets() {
        XCTAssertTrue(CJKText.endsWithCJK("他说「"))
        XCTAssertTrue(CJKText.endsWithCJK("参见【"))
        XCTAssertTrue(CJKText.endsWithCJK("书名《"))
        XCTAssertFalse(CJKText.endsWithCJK("he said「"))  // Latin content, opener or not
        XCTAssertFalse(CJKText.endsWithCJK("「"))          // nothing but the opener
    }

    func testPunctuationSets() {
        XCTAssertTrue(CJKText.cjkTerminalPunctuation.contains(0x3002))  // 。
        XCTAssertTrue(CJKText.cjkTerminalPunctuation.contains(0xFF01))  // ！
        XCTAssertTrue(CJKText.cjkTerminalPunctuation.contains(0xFF1F))  // ？
        XCTAssertTrue(CJKText.cjkClosingPunctuation.contains(0x300D))   // 」
        XCTAssertTrue(CJKText.cjkAttachedLeadingPunctuation.contains(0xFF0C)) // ，
    }

    /// Openers pair with the closers already covered, and stay out of the
    /// unconditional "never a space before this" set — the space in front of an
    /// opener depends on the left-hand side, so callers must ask separately.
    func testOpeningPunctuationSetPairsWithClosers() {
        let openers: [(UInt32, UInt32)] = [
            (0x300C, 0x300D),  // 「 」
            (0x300E, 0x300F),  // 『 』
            (0xFF08, 0xFF09),  // （ ）
            (0x3010, 0x3011),  // 【 】
            (0x3008, 0x3009),  // 〈 〉
            (0x300A, 0x300B),  // 《 》
        ]
        for (opener, closer) in openers {
            XCTAssertTrue(CJKText.cjkOpeningPunctuation.contains(opener), "missing opener \(String(opener, radix: 16))")
            XCTAssertTrue(CJKText.cjkClosingPunctuation.contains(closer), "missing closer \(String(closer, radix: 16))")
            XCTAssertFalse(
                CJKText.cjkAttachedLeadingPunctuation.contains(opener),
                "opener \(String(opener, radix: 16)) must not be unconditionally space-suppressing")
            XCTAssertTrue(
                CJKText.endsWithCJKSkippedTrailingScalars.contains(opener),
                "opener \(String(opener, radix: 16)) must be skipped when judging trailing CJK")
        }
    }
}
