import XCTest
@testable import Dictate_Anywhere

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

    func testSanitizedMappingsCoercesLanguageUnsupportedByStoredModel() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","inputSourceID":"a","inputSourceDisplayName":"A",
          "engine":"parakeet","parakeetModel":"englishOnly","language":"zh"}]
        """
        let survivors = Settings.sanitizedMappings(from: Data(json.utf8))
        XCTAssertEqual(survivors.map(\.inputSourceID), ["a"])
        XCTAssertEqual(survivors.first?.language, .english)
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

    // MARK: - Mutation helpers

    func testAddMappingDerivesDefaultsFromCurrentSettings() {
        let settings = Settings.shared
        settings.inputSourceMappings = []
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .englishOnly

        let mapping = settings.addInputSourceMapping(
            inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
            displayName: "Pinyin – Simplified",
            derivedLanguage: .chinese,
            isModelDownloaded: { $0 == .senseVoice }
        )

        // englishOnly can't do Chinese; senseVoice is the downloaded model that can.
        XCTAssertEqual(mapping?.engine, .parakeet)
        XCTAssertEqual(mapping?.parakeetModel, .senseVoice)
        XCTAssertEqual(mapping?.language, .chinese)
        XCTAssertEqual(settings.inputSourceMappings.count, 1)
    }

    func testAddMappingKeepsCurrentModelWhenItSupportsDerivedLanguage() {
        let settings = Settings.shared
        settings.inputSourceMappings = []
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .nemotronMultilingual

        let mapping = settings.addInputSourceMapping(
            inputSourceID: "com.apple.keylayout.German",
            displayName: "German",
            derivedLanguage: .german,
            isModelDownloaded: { _ in false }
        )

        XCTAssertEqual(mapping?.parakeetModel, .nemotronMultilingual)
        XCTAssertEqual(mapping?.language, .german)
    }

    func testAddMappingFallsBackToCurrentModelAndCoercesLanguage() {
        let settings = Settings.shared
        settings.inputSourceMappings = []
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .englishOnly

        // Nothing downloaded that supports Chinese -> keep current model, coerce language.
        let mapping = settings.addInputSourceMapping(
            inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
            displayName: "Pinyin – Simplified",
            derivedLanguage: .chinese,
            isModelDownloaded: { _ in false }
        )

        XCTAssertEqual(mapping?.parakeetModel, .englishOnly)
        XCTAssertEqual(mapping?.language, .english)
    }

    func testAddMappingRejectsDuplicateInputSource() {
        let settings = Settings.shared
        settings.inputSourceMappings = [makeMapping(source: "dup")]

        let second = settings.addInputSourceMapping(
            inputSourceID: "dup", displayName: "Dup",
            derivedLanguage: nil, isModelDownloaded: { _ in true }
        )

        XCTAssertNil(second)
        XCTAssertEqual(settings.inputSourceMappings.count, 1)
    }

    func testUpdateCoercesLanguageUnsupportedByModel() {
        let settings = Settings.shared
        let mapping = makeMapping(model: .nemotronMultilingual, language: .chinese)
        settings.inputSourceMappings = [mapping]

        var edited = mapping
        edited.parakeetModel = .englishOnly  // englishOnly can't do Chinese
        settings.updateInputSourceMapping(edited)

        XCTAssertEqual(settings.inputSourceMappings[0].parakeetModel, .englishOnly)
        XCTAssertEqual(settings.inputSourceMappings[0].language, .english)
    }

    func testUpdateNormalizesModelForEngine() {
        let settings = Settings.shared
        settings.parakeetModelChoice = .multilingual
        let mapping = makeMapping()
        settings.inputSourceMappings = [mapping]

        // Switching to Apple Speech clears the model…
        var edited = mapping
        edited.engine = .appleSpeech
        settings.updateInputSourceMapping(edited)
        XCTAssertNil(settings.inputSourceMappings[0].parakeetModel)

        // …and switching back fills it from the current global choice.
        edited = settings.inputSourceMappings[0]
        edited.engine = .parakeet
        settings.updateInputSourceMapping(edited)
        XCTAssertEqual(settings.inputSourceMappings[0].parakeetModel, .multilingual)
    }

    func testRemoveAndLookup() {
        let settings = Settings.shared
        let mapping = makeMapping(source: "findme")
        settings.inputSourceMappings = [mapping]

        XCTAssertEqual(settings.mapping(forInputSourceID: "findme"), mapping)
        XCTAssertNil(settings.mapping(forInputSourceID: "absent"))

        settings.removeInputSourceMapping(id: mapping.id)
        XCTAssertTrue(settings.inputSourceMappings.isEmpty)
    }
}
