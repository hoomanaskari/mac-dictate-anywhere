import AppKit
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class TextInsertionFinalizationTests: XCTestCase {
    // An AX timeout can still deliver Paste later. Finalization must leave that
    // operation's complete replacement and selected range intact.
    func testUncertainListPasteRetainsInputsForLateDelivery() async throws {
        let before = "1. Apples\n2. "
        let after = "\n3. Oranges"
        let insertion = "Bananas\n3. Cherries"
        let preparation = try XCTUnwrap(PlainTextListEdit.prepare(value: before + after,
            selection: NSRange(location: before.utf16.count, length: 0), insertion: insertion,
            context: context(before: before, after: after)))
        let edit = try XCTUnwrap(preparation.edit)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(edit.replacement, forType: .string)
        let changeCount = pasteboard.changeCount
        var selection = edit.range
        var fallbackCount = 0
        let delivery = await TextInserter.deliverToTarget(
            isTargetReady: { true }, pasteScript: { .possiblyDispatched },
            pasteEvent: { fallbackCount += 1; return true })
        await TextInserter.finalizeListPaste(delivery: delivery, insertionText: insertion,
            replacementText: edit.replacement, clipboardChangeCount: changeCount, pasteboard: pasteboard,
            finishEdit: { false },
            restoreSelection: { selection = NSRange(location: before.utf16.count, length: 0) })
        XCTAssertEqual(fallbackCount, 0)
        let latePaste = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(((before + after) as NSString).replacingCharacters(in: selection, with: latePaste),
            "1. Apples\n2. Bananas\n3. Cherries\n4. Oranges")
        XCTAssertEqual(pasteboard.changeCount, changeCount)
    }

    // A valid final numbered item has no downstream ordinals to replace and
    // must still reach ordinary paste. A stale snapshot must remain rejected.
    func testLastNumberedItemAllowsOrdinaryPasteButRejectsStaleSnapshot() throws {
        let before = "1. Apples\n2. "
        let insertion = "Bananas\n3. Cherries"
        let captured = context(before: before, after: "")
        let selection = NSRange(location: before.utf16.count, length: 0)
        let preparation = try XCTUnwrap(PlainTextListEdit.prepare(value: before, selection: selection,
            insertion: insertion, context: captured))
        XCTAssertNil(preparation.edit, "A verified no-op must allow the ordinary paste path")
        XCTAssertNil(PlainTextListEdit.prepare(value: "changed " + before, selection: selection,
            insertion: insertion, context: captured), "A stale snapshot must not become a no-op")
    }

    // Both successful verification and pre-dispatch rollback can suspend while
    // the user copies something else, including the same replacement text.
    func testListFinalizationPreservesNewerClipboardContents() async {
        let replacement = "Bananas\n3. Cherries\n4. Oranges"
        for delivery in [PasteDeliveryOutcome.success, .possiblyDispatched, .copiedOnly] {
            for newerCopy in [String?.none, "new user copy", replacement] {
                let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
                defer { pasteboard.releaseGlobally() }
                pasteboard.setString(replacement, forType: .string)
                let changeCount = pasteboard.changeCount
                let userCopy: () async -> Void = {
                    await Task.yield()
                    if let newerCopy {
                        pasteboard.clearContents()
                        pasteboard.setString(newerCopy, forType: .string)
                    }
                }
                await TextInserter.finalizeListPaste(delivery: delivery, insertionText: "Bananas\n3. Cherries",
                    replacementText: replacement, clipboardChangeCount: changeCount, pasteboard: pasteboard,
                    finishEdit: { await userCopy(); return true }, restoreSelection: { await userCopy() })
                XCTAssertEqual(pasteboard.string(forType: .string), newerCopy ?? "Bananas\n3. Cherries")
            }
        }
    }

    private func context(before: String, after: String) -> DictationContext {
        DictationContext(processIdentifier: 123, bundleIdentifier: "com.example.editor", appName: "Fixture",
            category: .other, documentURL: nil, documentTitle: nil, fieldRole: "AXTextArea", fieldSubrole: nil,
            fieldPurpose: .unknown, textBeforeCursor: before, selectedText: "", textAfterCursor: after,
            isSecureField: false, isContextExcluded: false)
    }
}
