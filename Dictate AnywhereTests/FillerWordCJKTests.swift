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
        XCTAssertFalse(Settings.defaultFillerWords.contains("那个")) // real word — never a default filler
    }

    /// 唔 is a hesitation sound in Mandarin but the Cantonese negator, so
    /// shipping it as a default would let filler removal invert meaning.
    func testDefaultsExcludeCantoneseNegator() {
        XCTAssertFalse(Settings.defaultFillerWords.contains("唔"))
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "我唔知道"), "我唔知道")
    }

    /// Even when a user opts 唔 in, it must not be cut out of running text —
    /// "我唔知道" (I don't know) must never become "我知道" (I know).
    func testUserAddedAmbiguousHanFillerIsNotRemovedMidText() {
        Settings.shared.fillerWordsToRemove = Settings.defaultFillerWords + ["唔"]
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "我唔知道"), "我唔知道")
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "佢唔系我嘅朋友"), "佢唔系我嘅朋友")
    }

    /// Boundary-anchored still means a standalone hesitation gets cleaned up.
    func testUserAddedAmbiguousHanFillerIsRemovedWhenStandingAlone() {
        Settings.shared.fillerWordsToRemove = Settings.defaultFillerWords + ["唔"]
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "我知道，唔，佢唔系"), "我知道，佢唔系")
        XCTAssertEqual(Settings.shared.removeFillerWords(from: "唔 I think so"), "I think so")
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
