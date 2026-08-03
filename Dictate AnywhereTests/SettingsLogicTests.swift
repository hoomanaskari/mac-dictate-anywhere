import XCTest
@testable import Dictate_Anywhere_Dev

/// Tests that exercise `Settings.shared` mutating APIs.
/// Every touched property is snapshotted in `setUp` and restored in `tearDown`
/// so the host app's persisted settings are left untouched.
final class SettingsLogicTests: XCTestCase {
    private var savedFillerEnabled = false
    private var savedFillerWords: [String] = []
    private var savedHistory: [TranscriptHistoryEntry] = []
    private var savedBindings: [HotkeyBinding] = []
    private var savedMode: TranscriptPostProcessingMode = .none
    private var savedEngineChoice: TranscriptionEngineChoice = .parakeet
    private var savedParakeetModelChoice: ParakeetModelChoice = .multilingual
    private var savedSelectedLanguage: SupportedLanguage = .english
    private var savedPendingVocabularyModeRestore = false

    override func setUp() {
        super.setUp()
        let settings = Settings.shared
        savedFillerEnabled = settings.isFillerWordRemovalEnabled
        savedFillerWords = settings.fillerWordsToRemove
        savedHistory = settings.transcriptHistory
        savedBindings = settings.hotkeyBindings
        savedMode = settings.transcriptPostProcessingMode
        savedEngineChoice = settings.engineChoice
        savedParakeetModelChoice = settings.parakeetModelChoice
        savedSelectedLanguage = settings.selectedLanguage
        savedPendingVocabularyModeRestore = settings.pendingVocabularyModeRestore
    }

    override func tearDown() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = savedFillerEnabled
        settings.fillerWordsToRemove = savedFillerWords
        settings.transcriptHistory = savedHistory
        settings.hotkeyBindings = savedBindings
        settings.pendingVocabularyModeRestore = savedPendingVocabularyModeRestore
        // Restore engine/model choice before post-processing mode: both
        // carry didSet coercions that can rewrite `transcriptPostProcessingMode`
        // (and `selectedLanguage`), so mode must be restored last to avoid
        // being clobbered by a coercion firing during this teardown.
        settings.engineChoice = savedEngineChoice
        settings.parakeetModelChoice = savedParakeetModelChoice
        settings.selectedLanguage = savedSelectedLanguage
        settings.transcriptPostProcessingMode = savedMode
        super.tearDown()
    }

    // MARK: - Filler word removal

    func testRemoveFillerWordsRemovesConfiguredWords() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = ["um", "uh"]

        let cleaned = settings.removeFillerWords(from: "So um I think uh this works")
        XCTAssertEqual(cleaned, "So I think this works")
    }

    func testRemoveFillerWordsIsCaseInsensitive() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = ["um"]

        XCTAssertEqual(settings.removeFillerWords(from: "Um hello UM world"), "hello world")
    }

    func testRemoveFillerWordsRespectsWordBoundaries() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = ["um"]

        // "umbrella" must survive.
        XCTAssertEqual(settings.removeFillerWords(from: "my umbrella um leaks"), "my umbrella leaks")
    }

    func testRemoveFillerWordsCleansPunctuationSpacing() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = ["um"]

        XCTAssertEqual(settings.removeFillerWords(from: "Well um, fine um."), "Well, fine.")
    }

    func testRemoveFillerWordsNoOpWhenDisabled() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = false
        settings.fillerWordsToRemove = ["um"]

        XCTAssertEqual(settings.removeFillerWords(from: "um hi"), "um hi")
    }

    func testRemoveFillerWordsNoOpWithEmptyList() {
        let settings = Settings.shared
        settings.isFillerWordRemovalEnabled = true
        settings.fillerWordsToRemove = []

        XCTAssertEqual(settings.removeFillerWords(from: "um hi"), "um hi")
    }

    func testDefaultFillerWords() {
        XCTAssertEqual(Settings.defaultFillerWords, ["um", "uh", "erm", "er", "hmm", "嗯", "呃"])
    }

    // MARK: - Transcript history

    func testAddRemoveClearTranscriptHistory() {
        let settings = Settings.shared
        settings.transcriptHistory = []

        settings.addTranscriptHistoryEntry("first")
        settings.addTranscriptHistoryEntry("second")
        XCTAssertEqual(settings.transcriptHistory.map(\.text), ["first", "second"])

        let id = settings.transcriptHistory[0].id
        settings.removeTranscriptHistoryEntry(id: id)
        XCTAssertEqual(settings.transcriptHistory.map(\.text), ["second"])

        settings.clearTranscriptHistory()
        XCTAssertTrue(settings.transcriptHistory.isEmpty)
    }

    // MARK: - Hotkey bindings

    func testAddUpdateClearRemoveBinding() {
        let settings = Settings.shared
        settings.hotkeyBindings = [HotkeyBinding.defaultBinding]

        let added = settings.addBinding()
        XCTAssertEqual(settings.hotkeyBindings.count, 2)
        XCTAssertFalse(added.hasBinding)

        settings.updateBindingHotkey(
            id: added.id,
            keyCode: nil,
            modifiers: [.command, .shift],
            displayName: "\u{21E7}\u{2318}"
        )
        let updated = settings.hotkeyBindings.first { $0.id == added.id }
        XCTAssertEqual(updated?.displayName, "\u{21E7}\u{2318}")
        XCTAssertTrue(updated?.hasBinding ?? false)

        var modeChanged = updated!
        modeChanged.mode = .handsFreeToggle
        settings.updateBinding(modeChanged)
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == added.id }?.mode, .handsFreeToggle)

        settings.clearBindingHotkey(id: added.id)
        let cleared = settings.hotkeyBindings.first { $0.id == added.id }
        XCTAssertEqual(cleared?.hasBinding, false)

        settings.removeBinding(id: added.id)
        XCTAssertEqual(settings.hotkeyBindings.count, 1)
    }

    func testHasHotkeyReflectsBindings() {
        let settings = Settings.shared
        settings.hotkeyBindings = [HotkeyBinding.defaultBinding]
        XCTAssertTrue(settings.hasHotkey)

        settings.hotkeyBindings = [
            HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: 0, displayName: "", mode: .holdToRecord)
        ]
        XCTAssertFalse(settings.hasHotkey)
    }

    // MARK: - Post-processing mode flags

    func testPostProcessingModeComputedFlags() {
        let settings = Settings.shared

        settings.transcriptPostProcessingMode = .none
        XCTAssertFalse(settings.ollamaPostProcessingEnabled)
        XCTAssertFalse(settings.appleIntelligencePostProcessingEnabled)
        XCTAssertFalse(settings.openRouterPostProcessingEnabled)
        XCTAssertFalse(settings.openAICompatiblePostProcessingEnabled)
        XCTAssertFalse(settings.fluidAudioVocabularyEnabled)

        settings.transcriptPostProcessingMode = .ollama
        XCTAssertTrue(settings.ollamaPostProcessingEnabled)

        settings.transcriptPostProcessingMode = .appleIntelligence
        XCTAssertTrue(settings.appleIntelligencePostProcessingEnabled)

        settings.transcriptPostProcessingMode = .openRouter
        XCTAssertTrue(settings.openRouterPostProcessingEnabled)

        settings.transcriptPostProcessingMode = .openAICompatible
        XCTAssertTrue(settings.openAICompatiblePostProcessingEnabled)

        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        XCTAssertTrue(settings.fluidAudioVocabularyEnabled)
    }

    /// Switching engines away from Parakeet while a vocabulary-incapable
    /// Parakeet model is persisted must not leave a stale
    /// `.fluidAudioVocabulary` post-processing mode selected once the user
    /// switches back to Parakeet.
    func testEngineChoiceCoercesStaleVocabularyMode() {
        let settings = Settings.shared

        // Start on a Parakeet model that supports FluidAudio vocabulary.
        settings.parakeetModelChoice = .multilingual
        XCTAssertTrue(settings.parakeetModelChoice.supportsFluidAudioVocabulary)

        // Vocabulary mode is legitimate on Apple Speech, independent of the
        // persisted Parakeet model choice.
        settings.engineChoice = .appleSpeech
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary

        // Changing the persisted Parakeet model choice while the active
        // engine is Apple Speech must not coerce the mode away.
        settings.parakeetModelChoice = .senseVoice
        XCTAssertFalse(settings.parakeetModelChoice.supportsFluidAudioVocabulary)
        XCTAssertEqual(settings.transcriptPostProcessingMode, .fluidAudioVocabulary)

        // Switching the engine to Parakeet with a stale, vocab-incapable
        // model selected must coerce the mode back to `.none`.
        settings.engineChoice = .parakeet
        XCTAssertEqual(settings.transcriptPostProcessingMode, .none)
    }

    // MARK: - Pending vocabulary mode restore (auto-switch)

    func testNoteAutoSwitchModelChangeSetsFlagOnlyWhenModeWasStripped() {
        let settings = Settings.shared

        // Simulate the coercion having fired: mode was `.fluidAudioVocabulary`
        // before the auto-switch write, and is no longer that after.
        settings.pendingVocabularyModeRestore = false
        settings.transcriptPostProcessingMode = .none
        settings.noteAutoSwitchModelChange(hadVocabularyMode: true)
        XCTAssertTrue(settings.pendingVocabularyModeRestore)
    }

    func testNoteAutoSwitchModelChangeNoOpsWhenHadVocabularyModeIsFalse() {
        let settings = Settings.shared

        settings.pendingVocabularyModeRestore = false
        settings.transcriptPostProcessingMode = .none
        settings.noteAutoSwitchModelChange(hadVocabularyMode: false)
        XCTAssertFalse(settings.pendingVocabularyModeRestore)
    }

    func testNoteAutoSwitchModelChangeNoOpsWhenModeStillFluidAudioVocabulary() {
        let settings = Settings.shared

        // Coercion didn't fire (e.g. destination was still vocab-capable).
        settings.pendingVocabularyModeRestore = false
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.noteAutoSwitchModelChange(hadVocabularyMode: true)
        XCTAssertFalse(settings.pendingVocabularyModeRestore)
    }

    func testRestoreVocabularyModeRestoresAndClearsWhenModelCapable() {
        let settings = Settings.shared

        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        XCTAssertTrue(settings.parakeetModelChoice.supportsFluidAudioVocabulary)
        settings.transcriptPostProcessingMode = .none
        settings.pendingVocabularyModeRestore = true

        settings.restoreVocabularyModeAfterAutoSwitchIfPending()

        XCTAssertEqual(settings.transcriptPostProcessingMode, .fluidAudioVocabulary)
        XCTAssertFalse(settings.pendingVocabularyModeRestore)
    }

    func testRestoreVocabularyModeKeepsFlagPendingWhenModelNotCapable() {
        let settings = Settings.shared

        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .senseVoice
        XCTAssertFalse(settings.parakeetModelChoice.supportsFluidAudioVocabulary)
        // Coerced to .none as a side effect of the assignment above; confirm
        // the starting point explicitly.
        settings.transcriptPostProcessingMode = .none
        settings.pendingVocabularyModeRestore = true

        settings.restoreVocabularyModeAfterAutoSwitchIfPending()

        XCTAssertEqual(settings.transcriptPostProcessingMode, .none)
        XCTAssertTrue(settings.pendingVocabularyModeRestore)
    }

    func testRestoreVocabularyModeClearsWithoutChangingModeWhenUserPickedAnotherMode() {
        let settings = Settings.shared

        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.transcriptPostProcessingMode = .ollama
        settings.pendingVocabularyModeRestore = true

        settings.restoreVocabularyModeAfterAutoSwitchIfPending()

        XCTAssertEqual(settings.transcriptPostProcessingMode, .ollama)
        XCTAssertFalse(settings.pendingVocabularyModeRestore)
    }

    func testRestoreVocabularyModeClearsWhenModeAlreadyFluidAudioVocabulary() {
        let settings = Settings.shared

        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.transcriptPostProcessingMode = .fluidAudioVocabulary
        settings.pendingVocabularyModeRestore = true

        settings.restoreVocabularyModeAfterAutoSwitchIfPending()

        XCTAssertEqual(settings.transcriptPostProcessingMode, .fluidAudioVocabulary)
        XCTAssertFalse(settings.pendingVocabularyModeRestore)
    }

    func testRestoreVocabularyModeNoOpWhenFlagNotPending() {
        let settings = Settings.shared

        settings.engineChoice = .parakeet
        settings.parakeetModelChoice = .multilingual
        settings.transcriptPostProcessingMode = .none
        settings.pendingVocabularyModeRestore = false

        settings.restoreVocabularyModeAfterAutoSwitchIfPending()

        XCTAssertEqual(settings.transcriptPostProcessingMode, .none)
        XCTAssertFalse(settings.pendingVocabularyModeRestore)
    }
}
