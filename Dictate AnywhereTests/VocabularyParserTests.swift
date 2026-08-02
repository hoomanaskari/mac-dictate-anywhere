import XCTest
@testable import Dictate_Anywhere_Dev

final class VocabularyParserTests: XCTestCase {

    func testParsesSingleTerm() {
        XCTAssertEqual(VocabularyInputParser.terms(from: "Parakeet", existingTerms: []), ["Parakeet"])
    }

    func testParsesCommaSeparatedTerms() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "Parakeet, Ollama, FluidAudio", existingTerms: []),
            ["Parakeet", "Ollama", "FluidAudio"]
        )
    }

    func testParsesNewlineSeparatedTerms() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "one\ntwo\nthree", existingTerms: []),
            ["one", "two", "three"]
        )
    }

    func testSkipsExistingTerms() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "old, new", existingTerms: ["old"]),
            ["new"]
        )
    }

    func testDeduplicatesWithinInput() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "dup, dup, other", existingTerms: []),
            ["dup", "other"]
        )
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "  padded  ,  second  ", existingTerms: []),
            ["padded", "second"]
        )
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertEqual(VocabularyInputParser.terms(from: "", existingTerms: []), [])
        XCTAssertEqual(VocabularyInputParser.terms(from: " , ,\n", existingTerms: []), [])
    }

    func testSplitsOnFullwidthComma() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "你好\u{FF0C}世界", existingTerms: []),
            ["你好", "世界"])
    }

    func testSplitsOnEnumerationComma() {
        XCTAssertEqual(
            VocabularyInputParser.terms(from: "苹果\u{3001}微软\u{3001}谷歌", existingTerms: []),
            ["苹果", "微软", "谷歌"])
    }
}
