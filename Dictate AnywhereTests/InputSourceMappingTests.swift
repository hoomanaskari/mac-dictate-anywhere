import XCTest
@testable import Dictate_Anywhere_Dev

final class InputSourceMappingTests: XCTestCase {
    private var savedMappings: [InputSourceMapping] = []
    private var savedEnabled = false
    private var savedEngineChoice: TranscriptionEngineChoice = .parakeet
    private var savedModel: ParakeetModelChoice = .multilingual
    private var savedLanguage: SupportedLanguage = .english
    private var savedMode: TranscriptPostProcessingMode = .none

    override func setUp() {
        super.setUp()
        let settings = Settings.shared
        savedMappings = settings.inputSourceMappings
        savedEnabled = settings.inputSourceAutoSwitchEnabled
        savedEngineChoice = settings.engineChoice
        savedModel = settings.parakeetModelChoice
        savedLanguage = settings.selectedLanguage
        savedMode = settings.transcriptPostProcessingMode
    }

    override func tearDown() {
        let settings = Settings.shared
        settings.inputSourceMappings = savedMappings
        settings.inputSourceAutoSwitchEnabled = savedEnabled
        // Model before language, post-processing mode last (didSet coercions).
        settings.engineChoice = savedEngineChoice
        settings.parakeetModelChoice = savedModel
        settings.selectedLanguage = savedLanguage
        settings.transcriptPostProcessingMode = savedMode
        super.tearDown()
    }

    private func makeMapping(
        source: String = "com.apple.keylayout.ABC",
        engine: TranscriptionEngineChoice = .parakeet,
        model: ParakeetModelChoice? = .englishOnly,
        language: SupportedLanguage = .english
    ) -> InputSourceMapping {
        InputSourceMapping(
            id: UUID(), inputSourceID: source, inputSourceDisplayName: "ABC",
            engine: engine, parakeetModel: model, language: language
        )
    }

    func testMappingsRoundTripThroughJSON() throws {
        let mappings = [
            makeMapping(),
            makeMapping(source: "com.apple.inputmethod.SCIM.ITABC", model: .senseVoice, language: .chinese),
        ]
        let data = try JSONEncoder().encode(mappings)
        XCTAssertEqual(Settings.sanitizedMappings(from: data), mappings)
    }

    func testSanitizedMappingsDropsUnknownEnumRawValues() throws {
        let json = """
        [
          {"id":"\(UUID().uuidString)","inputSourceID":"a","inputSourceDisplayName":"A",
           "engine":"parakeet","parakeetModel":"englishOnly","language":"en"},
          {"id":"\(UUID().uuidString)","inputSourceID":"b","inputSourceDisplayName":"B",
           "engine":"banana","parakeetModel":"englishOnly","language":"en"},
          {"id":"\(UUID().uuidString)","inputSourceID":"c","inputSourceDisplayName":"C",
           "engine":"parakeet","parakeetModel":"deletedModel","language":"en"},
          {"id":"\(UUID().uuidString)","inputSourceID":"d","inputSourceDisplayName":"D",
           "engine":"parakeet","parakeetModel":"englishOnly","language":"xx"}
        ]
        """
        let survivors = Settings.sanitizedMappings(from: Data(json.utf8))
        XCTAssertEqual(survivors.map(\.inputSourceID), ["a"])
    }

    func testSanitizedMappingsDropsParakeetEntryWithoutModel() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","inputSourceID":"a","inputSourceDisplayName":"A",
          "engine":"parakeet","language":"en"}]
        """
        XCTAssertTrue(Settings.sanitizedMappings(from: Data(json.utf8)).isEmpty)
    }

    func testSanitizedMappingsReturnsEmptyOnGarbageData() {
        XCTAssertTrue(Settings.sanitizedMappings(from: Data("not json".utf8)).isEmpty)
    }

    func testMappingsPersistToUserDefaults() throws {
        let settings = Settings.shared
        let mapping = makeMapping()
        settings.inputSourceMappings = [mapping]
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "inputSourceMappings"))
        XCTAssertEqual(Settings.sanitizedMappings(from: data), [mapping])
    }
}
