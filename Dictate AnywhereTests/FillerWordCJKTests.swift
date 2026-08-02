import XCTest
@testable import Dictate_Anywhere_Dev

@MainActor
final class FillerWordCJKTests: XCTestCase {
    private var savedEnabled = false
    private var savedWords: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        savedEnabled = Settings.shared.isFillerWordRemovalEnabled
        savedWords = Settings.shared.fillerWordsToRemove
        Settings.shared.isFillerWordRemovalEnabled = true
        Settings.shared.fillerWordsToRemove = Settings.defaultFillerWords
    }

    override func tearDown() async throws {
        Settings.shared.isFillerWordRemovalEnabled = savedEnabled
        Settings.shared.fillerWordsToRemove = savedWords
        try await super.tearDown()
    }

    func testDefaultsIncludeMandarinFillers() {
        XCTAssertTrue(Settings.defaultFillerWords.contains("嗯"))
        XCTAssertTrue(Settings.defaultFillerWords.contains("呃"))
        XCTAssertTrue(Settings.defaultFillerWords.contains("唔"))
        XCTAssertFalse(Settings.defaultFillerWords.contains("那个")) // real word — never a default filler
    }

    func testRemovesHanFillerInsideUnsegmentedText() {
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "我嗯觉得可以"), "我觉得可以")
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "嗯嗯我觉得可以"), "我觉得可以") // repeated filler
    }

    func testCleansFullwidthPunctuationAfterRemoval() {
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "我，嗯，觉得可以"), "我，觉得可以")
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "好的 ，走吧"), "好的，走吧")
    }

    func testEnglishBehaviorUnchanged() {
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "I um think uh this works"), "I think this works")
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "The umbrella is here"), "The umbrella is here") // \b intact
    }

    func testHanFillerDoesNotEatSubstringOfRealWord() {
        // 嗯 does not appear inside common words, but verify removal is exact-character, not fuzzy.
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "你好嗯"), "你好")
    }
}
