import XCTest
@testable import Dictate_Anywhere_Dev

final class PostProcessingNormalizationTests: XCTestCase {
    func testEmDashBetweenHanBecomesFullwidthComma() {
        XCTAssertEqual(normalizePostProcessedTranscript("我\u{2014}觉得可以"), "我\u{FF0C}觉得可以")
        XCTAssertEqual(normalizePostProcessedTranscript("我\u{2014}\u{2014}觉得可以"), "我\u{FF0C}觉得可以")
    }

    func testEmDashInLatinStillBecomesCommaSpace() {
        XCTAssertEqual(normalizePostProcessedTranscript("well\u{2014}maybe"), "well, maybe")
    }

    func testFullwidthSpacingCleanup() {
        XCTAssertEqual(normalizePostProcessedTranscript("你好 \u{FF0C}世界"), "你好\u{FF0C}世界")
        XCTAssertEqual(normalizePostProcessedTranscript("好的 \u{3002}"), "好的\u{3002}")
    }

    func testExistingLatinCleanupUnchanged() {
        XCTAssertEqual(normalizePostProcessedTranscript("done ."), "done .") // " ." is NOT rewritten today — do not add new ASCII rules
        XCTAssertEqual(normalizePostProcessedTranscript("a , b"), "a, b")
    }
}
