import XCTest
import CoreAudio
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

    func testAddMappingWhileAssemblyAIIsSelectedCreatesALocalProfile() {
        let settings = Settings.shared
        settings.inputSourceMappings = []
        settings.engineChoice = .assemblyAI
        settings.parakeetModelChoice = .nemotronMultilingual

        let mapping = settings.addInputSourceMapping(
            inputSourceID: "com.apple.keylayout.German",
            displayName: "German",
            derivedLanguage: .german,
            isModelDownloaded: { _ in true }
        )

        XCTAssertEqual(mapping?.engine, .parakeet)
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

    #if DEBUG
    @MainActor
    func testRecordingTraceUsesResolvedInputSourceProfileWithoutChangingSession() async throws {
        try XCTSkipUnless(PerfTrace.isEnabled, "Requires enabled trace emission")
        let settings = Settings.shared
        let sound = settings.soundEffectsEnabled
        let boost = settings.boostMicrophoneVolumeEnabled
        let mute = settings.muteSystemAudioDuringRecordingEnabled
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-trace-\(UUID())")
        defer {
            PerfTrace.onIntervalCompleted = nil
            settings.soundEffectsEnabled = sound
            settings.boostMicrophoneVolumeEnabled = boost
            settings.muteSystemAudioDuringRecordingEnabled = mute
            try? FileManager.default.removeItem(at: directory)
        }
        settings.soundEffectsEnabled = false
        settings.boostMicrophoneVolumeEnabled = false
        settings.muteSystemAudioDuringRecordingEnabled = false
        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.selectedLanguage = .english
        settings.transcriptPostProcessingMode = .none
        settings.inputSourceAutoSwitchEnabled = true
        settings.inputSourceMappings = [makeMapping(source: "profile-test", model: .multilingual, language: .german)]

        let records = ProfileTraceRecords()
        PerfTrace.onIntervalCompleted = { name, _, metadata in
            records.append(name: name, metadata: metadata)
        }
        let engine = ProfileTraceEngine()
        let app = AppState(
            permissions: Permissions(statusProvider: { (true, false) }),
            recoveryStore: DictationRecoveryStore(directory: directory),
            engine: engine,
            contextCapture: { _ in nil },
            inputSourceID: { "profile-test" },
            profileModelAvailable: { _ in true }
        )
        app.permissions.micGranted = true
        await app.startDictation()
        XCTAssertEqual(app.status, .recording)
        let source = try XCTUnwrap(records.metadata(for: "dictation.inputSourceApply"))
        let request = try XCTUnwrap(records.metadata(for: "dictation.requestToRecording"))
        let start = try XCTUnwrap(records.metadata(for: "dictation.start"))
        XCTAssertTrue(source.contains("language=en"), source)
        XCTAssertTrue(request.contains("language=de"), request)
        XCTAssertTrue(start.contains("language=de"), start)
        XCTAssertTrue(request.contains("model=multilingual"), request)
        let id = try XCTUnwrap(request.split(separator: " ").first { $0.hasPrefix("session_id=") })
        XCTAssertTrue(source.contains(id), source)
        XCTAssertTrue(start.contains(id), start)
        await app.cancelDictation()
        PerfTrace.begin("test.profileAfterSuccess").end()
        XCTAssertEqual(records.metadata(for: "test.profileAfterSuccess"), "session_id=none")
        engine.isReady = false
        await app.startDictation()
        PerfTrace.begin("test.profileAfterAbort").end()
        XCTAssertEqual(records.metadata(for: "test.profileAfterAbort"), "session_id=none")
        await app.shutdown()
    }
    #endif
}

#if DEBUG
private final class ProfileTraceRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String)] = []

    func append(name: String, metadata: String) {
        lock.withLock { entries.append((name, metadata)) }
    }

    func metadata(for name: String) -> String? {
        lock.withLock { entries.first { $0.0 == name }?.1 }
    }
}

@MainActor
private final class ProfileTraceEngine: TranscriptionEngine {
    var recoveryCapture: RecoveryAudioCapture?
    var isReady = true
    var currentTranscript = ""
    var audioSamples: [Float] = []
    func levelSamples(count: Int) -> [Float] { [] }
    func prepare() async throws {}
    func startRecording(deviceID: AudioDeviceID?) async throws {}
    func stopAudioCapture() async {}
    func stopRecording() async -> String { "" }
    func cancel() async {}
    func transcribeRecording(at url: URL) async throws -> String { "" }
}
#endif
