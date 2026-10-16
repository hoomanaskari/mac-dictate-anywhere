import XCTest
@testable import Dictate_Anywhere

@MainActor
final class ReleaseReadinessTests: XCTestCase {
    func testAssemblyAICancellationRespectsDisabledPreservation() async throws {
        let settings = Settings.shared
        let oldPreserve = settings.preserveCancelledSessions
        let oldEngine = settings.engineChoice
        let oldMute = settings.muteSystemAudioDuringRecordingEnabled
        defer {
            settings.preserveCancelledSessions = oldPreserve
            settings.engineChoice = oldEngine
            settings.muteSystemAudioDuringRecordingEnabled = oldMute
        }
        settings.preserveCancelledSessions = false
        settings.engineChoice = .assemblyAI
        settings.muteSystemAudioDuringRecordingEnabled = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let app = AppState(permissions: Permissions(statusProvider: { (true, false) }), recoveryStore: store)
        app.prepareSessionRecovery(for: app.assemblyAIEngine)
        app.assemblyAIEngine.recoveryCapture?.append(Array(repeating: 0.2, count: 16000))
        app.status = .recording
        await app.cancelDictation()
        XCTAssertTrue(store.entries.isEmpty, "Preservation is OFF, but cancellation retained a recording")
    }

    func testPlainNumberedInsertionDoesNotDuplicateFollowingNumbers() throws {
        let before = "1. Apples\n2. "
        let after = "\n3. Oranges"
        let context = makeContext(before: before, after: after)
        let plan = try XCTUnwrap(ModelInsertionPlan.decode(#"{"items":["Tangerines","Blueberries"],"space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
        let insertion = TextInserter().preparedTextForInsertion(plan.text,
            targetBundleIdentifier: nil, targetProcessIdentifier: 123, context: context,
            style: .original, knownTerms: [], modelInsertionPlan: plan, preserveModelFormatting: true)
        let edit = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: insertion, context: context)?.edit)
        XCTAssertEqual(edit.expectedValue, "1. Apples\n2. Tangerines\n3. Blueberries\n4. Oranges")
        XCTAssertEqual(edit.caretLocation, (before + insertion).utf16.count)
    }

    func testEditableStyleAndMidSentencePromptsReachSharedContextRequests() {
        let context = makeContext(before: "I want ", after: " today.")
        let prompt = AssemblyAIEngine.llmInstruction(customInstruction: "", context: context,
            shareSurroundingText: true, style: .formal,
            promptOverrides: [.init(AssemblyAIInternalPrompt.formal.rawValue): "AUDIT_CUSTOM_STYLE",
                AssemblyAIInternalPrompt.midSentence.rawValue: "AUDIT_CUSTOM_INSERTION"])
        XCTAssertTrue(prompt.contains("AUDIT_CUSTOM_STYLE"), "Visible style customization is silently ignored")
        XCTAssertTrue(prompt.contains("AUDIT_CUSTOM_INSERTION"), "Visible mid-sentence customization is silently ignored")
    }

    func testCancellationUsesSessionStartPreference() async throws {
        let settings = Settings.shared
        let oldPreserve = settings.preserveCancelledSessions
        let oldEngine = settings.engineChoice
        defer { settings.preserveCancelledSessions = oldPreserve; settings.engineChoice = oldEngine }
        settings.engineChoice = .assemblyAI
        for enabled in [false, true] {
            settings.preserveCancelledSessions = enabled
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = DictationRecoveryStore(directory: directory)
            let app = AppState(permissions: Permissions(statusProvider: { (true, false) }), recoveryStore: store)
            app.prepareSessionRecovery(for: app.assemblyAIEngine)
            let capture = try XCTUnwrap(app.assemblyAIEngine.recoveryCapture)
            capture.append([0.2, 0.3])
            settings.preserveCancelledSessions = !enabled
            app.status = .recording
            await app.cancelDictation()
            XCTAssertEqual(store.entries.count, enabled ? 1 : 0)
            XCTAssertEqual(FileManager.default.fileExists(atPath: capture.url.path), enabled)
        }
    }

    func testNumberingPreservesNestedTextAndStopsAtIndependentSection() throws {
        let before = "Shopping 🛒\n8) Apples\n9) "
        let after = "\n10) Oranges\n    1. Nested\n    continuation\n\n11) Flowers\nParagraph\n12) Unrelated"
        let insertion = "Tangerines\n10) Blueberries"
        let edit = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: insertion,
            context: makeContext(before: before, after: after))?.edit)
        XCTAssertEqual(edit.expectedValue, before + insertion + "\n11) Oranges\n    1. Nested\n    continuation\n\n12) Flowers\nParagraph\n12) Unrelated")
    }

    func testNumberingPreservesCRLFAndIndentedList() throws {
        let before = "  1. Apples\r\n  2. "
        let after = "\r\n  3. Oranges\r\n1. Outer list"
        let edit = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: "Pears\n  3. Grapes",
            context: makeContext(before: before, after: after))?.edit)
        XCTAssertEqual(edit.expectedValue, before + "Pears\n  3. Grapes\r\n  4. Oranges\r\n1. Outer list")
    }

    func testNumberingRejectsStaleContextSelectionsAndRichLists() {
        let before = "1. Apples\n2. "
        let after = "\n3. Oranges"
        var context = makeContext(before: before, after: after)
        let range = NSRange(location: before.utf16.count, length: 0)
        XCTAssertNil(PlainTextListEdit.prepare(value: before + "changed" + after,
            selection: range, insertion: "Pears\n3. Grapes", context: context))
        XCTAssertNil(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: range.location, length: 1), insertion: "Pears\n3. Grapes", context: context))
        context.capturedListItemInsertion = .emptyStructuralItem(itemText: "", previousItemText: "Apples", nextItemText: "Oranges")
        XCTAssertNil(PlainTextListEdit.prepare(value: before + after, selection: range,
            insertion: "Pears\nGrapes", context: context))
    }

    func testAllApplicableCustomPromptsSurviveLongPreferences() throws {
        let context = makeContext(before: "I want ", after: " today.")
        let overrides = ["baseCleanup": "BASE " + String(repeating: "b", count: 4000),
            "other": "DESTINATION " + String(repeating: "d", count: 4000),
            "formal": "STYLE " + String(repeating: "s", count: 4000),
            "midSentence": "FIELD " + String(repeating: "f", count: 4000)]
        let prompt = AssemblyAIEngine.llmInstruction(customInstruction: "USER " + String(repeating: "u", count: 4000),
            context: context, shareSurroundingText: true, style: .formal, promptOverrides: overrides)
        for marker in ["BASE", "DESTINATION", "STYLE", "FIELD", "USER"] { XCTAssertTrue(prompt.contains(marker)) }
        XCTAssertLessThanOrEqual(prompt.count, 2048)
        let json = try XCTUnwrap(prompt.components(separatedBy: "NEARBY DATA:\n").last?.components(separatedBy: "\n").first)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testSearchPromptAppliesAndMidSentencePromptDoesNotLeakIntoList() {
        let overrides = ["searchQuery": "SEARCH_CUSTOM", "midSentence": "MID_CUSTOM"]
        let search = AssemblyAIEngine.llmInstruction(customInstruction: "",
            context: makeContext(before: "", after: "", purpose: .searchQuery),
            shareSurroundingText: true, style: .original, promptOverrides: overrides)
        XCTAssertTrue(search.contains("SEARCH_CUSTOM"))
        let list = AssemblyAIEngine.llmInstruction(customInstruction: "",
            context: makeContext(before: "- Apples\n- ", after: "\n- Oranges"),
            shareSurroundingText: true, style: .formal, promptOverrides: overrides)
        XCTAssertFalse(list.contains("MID_CUSTOM"))
        XCTAssertFalse(list.contains("SEARCH_CUSTOM"))
        XCTAssertFalse(list.contains("INLINE:"))
    }

    private func makeContext(before: String, after: String, purpose: DictationFieldPurpose = .unknown) -> DictationContext {
        DictationContext(processIdentifier: 123, bundleIdentifier: "com.example.editor", appName: "Fixture",
            category: .other, documentURL: nil, documentTitle: nil, fieldRole: "AXTextArea", fieldSubrole: nil,
            fieldPurpose: purpose, textBeforeCursor: before, selectedText: "", textAfterCursor: after,
            isSecureField: false, isContextExcluded: false)
    }
}
