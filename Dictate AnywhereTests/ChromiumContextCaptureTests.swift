import AppKit
import XCTest
@testable import Dictate_Anywhere

/// Opt-in integration test against a separate Chrome process and disposable
/// profile. Never connects to the user's browser profile or Codex window.
final class ChromiumContextCaptureTests: XCTestCase {
    @MainActor
    func testColdChromiumEditorExposesCursorContext() async throws {
        try await runChromeFixture(isList: false)
    }

    @MainActor
    func testColdChromiumRichListInsertion() async throws {
        try await runChromeFixture(isList: true)
    }

    @MainActor
    func testChromiumMultiwordListItem() async throws {
        try await runChromeFixture(isList: true, spoken: "sourdough starter", expectedItem: "Sourdough starter")
    }

    @MainActor
    func testChromiumLongerListPhrase() async throws {
        try await runChromeFixture(isList: true, spoken: "fresh sourdough starter from the local bakery",
            expectedItem: "Fresh sourdough starter from the local bakery")
    }

    @MainActor
    func testChromiumSentenceListKeepsPeriods() async throws {
        try await runChromeFixture(isList: true, spoken: "buy sourdough starter", expectedItem: "Buy sourdough starter.",
            neighbors: ["Buy apples.", "Buy bananas.", "Buy oranges.", "Buy flowers."])
    }

    @MainActor
    func testChromiumInlineMultiwordPhrase() async throws {
        try await runChromeFixture(isList: false, spoken: "fresh tangerines", expectedItem: "fresh tangerines")
    }

    @MainActor
    func testChromiumEnumeratedBulletItems() async throws {
        try await runChromeFixture(isList: true, spoken: "tangerines, blueberries",
            expectedItems: ["Tangerines", "Blueberries"])
    }

    @MainActor
    func testChromiumEnumeratedNumberedItems() async throws {
        try await runChromeFixture(isList: true, spoken: "tangerines, blueberries",
            expectedItems: ["Tangerines", "Blueberries"], ordered: true)
    }

    @MainActor
    func testChromiumEnumeratedInlineItems() async throws {
        try await runChromeFixture(isList: false, spoken: "tangerines, blueberries",
            expectedItem: "tangerines, blueberries")
    }

    @MainActor
    func testChromiumEnumeratedItemsAtEndOfInlineSeries() async throws {
        try await runChromeFixture(isList: false, spoken: "tangerines, blueberries",
            expectedItem: "tangerines, blueberries", inlineAtEnd: true)
    }

    @MainActor
    func testChromiumEnumerationKeepsCompoundItemsTogether() async throws {
        try await runChromeFixture(isList: true, spoken: "macaroni and cheese, sourdough starter",
            expectedItems: ["Macaroni and cheese", "Sourdough starter"])
    }

    @MainActor
    func testChromiumEnumeratedNumberedActions() async throws {
        try await runChromeFixture(isList: true, spoken: "wash the vegetables, chop the onions, preheat the oven",
            neighbors: ["Plan the menu", "Buy ingredients", "Cook dinner", "Serve the meal"],
            expectedItems: ["Wash the vegetables", "Chop the onions", "Preheat the oven"], ordered: true)
    }

    @MainActor
    func testChromiumPlainNumberedListRenumbersFollowingItems() async throws {
        try await runChromeFixture(isList: false, spoken: "tangerines, blueberries", plainNumbered: true)
    }

    @MainActor
    func testChromiumRotationExplanationStaysProse() async throws {
        let prose = "Snapping for rotation in this app is reversed. For everything else, I have to hold down Shift to snap. For rotation, I have to hold down Shift to stop snapping."
        try await runChromeFixture(isList: false, spoken: prose, prose: prose)
    }

    @MainActor
    func testEmptyChromiumComposerDoesNotInheritPageText() async throws {
        try await runChromeFixture(isList: false, prose: "Alright, dig really deep.", surroundingPageText: true)
    }

    @MainActor
    func testEmptyChromiumComposerRejectsStalePageSelection() async throws {
        try await runChromeFixture(isList: false, prose: "Alright, dig really deep.",
            surroundingPageText: true, stalePageSelection: true)
    }

    @MainActor
    func testScopedChromiumMarkersPreserveRichListContext() async throws {
        try await runChromeFixture(isList: true, surroundingPageText: true)
    }

    @MainActor
    func testScopedChromiumMarkersPreserveInlineContext() async throws {
        try await runChromeFixture(isList: false, surroundingPageText: true)
    }

    @MainActor
    private func runChromeFixture(isList: Bool, spoken: String? = nil, expectedItem: String? = nil,
                                  neighbors: [String] = ["Apples", "Bananas", "Oranges", "Flowers"],
                                  expectedItems: [String]? = nil, ordered: Bool = false,
                                  inlineAtEnd: Bool = false, plainNumbered: Bool = false,
                                  prose: String? = nil, surroundingPageText: Bool = false,
                                  stalePageSelection: Bool = false) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATE_CHROMIUM_CAPTURE_TESTS"] == "1")
        let executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: executable))
        XCTAssertTrue(AXIsProcessTrusted(), "Requires existing Dev-app Accessibility permission.")
        guard AXIsProcessTrusted() else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = prose != nil ? "" : plainNumbered ? "1. Apples\n2. Bananas\n3. " : "I need to buy some groceries: apples, bananas,"
        let after = prose != nil ? "" : plainNumbered ? "\n4. Oranges\n5. Flowers" : inlineAtEnd ? "" : " oranges, and some sourdough starter."
        let listTag = ordered ? "ol" : "ul"
        let contents = isList
            ? "<p>I need to buy:</p><\(listTag)><li>\(neighbors[0])</li><li>\(neighbors[1])</li><li id='target'><br></li><li>\(neighbors[2])</li><li>\(neighbors[3])</li></\(listTag)>"
            : before + after
        let cursor = prose != nil ? "r.setStart(e, 0);" : isList ? "r.setStart(document.getElementById('target'), 0);" : "r.setStart(e.firstChild, \(before.utf16.count));"
        let editorHTML = plainNumbered ? "<textarea id='editor'>\(contents)</textarea>"
            : "<div id='editor' contenteditable='true' role='textbox' aria-multiline='true'>\(contents)</div>"
        let selectionJS = plainNumbered ? "e.setSelectionRange(\(before.utf16.count), \(before.utf16.count));"
            : "const r = document.createRange(); \(cursor) r.collapse(true); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);"
        let html = """
        <!doctype html><title>Dictation capture fixture</title>
        \(surroundingPageText ? "<p id='reference'>Previous conversation without punctuation</p>" : "")
        \(editorHTML)
        \(surroundingPageText ? "<p>Text after the composer</p>" : "")
        <script>
        window.onload = () => {
          const e = document.getElementById('editor'); e.focus();
          \(selectionJS)
          \(stalePageSelection ? "const stale = document.createRange(); stale.setStart(document.getElementById('reference').firstChild, 12); stale.collapse(true); window.getSelection().removeAllRanges(); window.getSelection().addRange(stale);" : "")
        };
        </script>
        """
        let page = directory.appendingPathComponent("fixture.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--user-data-dir=\(directory.appendingPathComponent("profile").path)",
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--disable-extensions", "--use-mock-keychain", "--app=\(page.absoluteString)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier { break }
            if let app = NSRunningApplication(processIdentifier: process.processIdentifier), app.isFinishedLaunching {
                app.activate()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Capture-only fixtures can read their own process while backgrounded.
        // Live paste still requires the explicit foreground check below.
        if !surroundingPageText {
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier,
                "Only the isolated fixture may be inspected by this test.")
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier else { return }
        }
        try await Task.sleep(for: .milliseconds(500))
        let pid = process.processIdentifier
        var context = await Task.detached {
            DictationContextCapture.capture(processIdentifier: pid,
                bundleIdentifier: "com.google.Chrome", appName: "Chrome fixture", rules: [])
        }.value
        // Enabling Chromium AX rebuilds the tree asynchronously. Wait for this
        // fixture's known selection before testing transcription and insertion.
        for _ in 0..<5 {
            let ready = isList ? context.capturedListItemInsertion != nil
                : context.textBeforeCursor == before && context.textAfterCursor == after
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
            context = await Task.detached {
                DictationContextCapture.capture(processIdentifier: pid,
                    bundleIdentifier: "com.google.Chrome", appName: "Chrome fixture", rules: [])
            }.value
        }
        print("Cold Chromium capture: snapshot=\(context.hasTextPositionSnapshot) role=\(context.fieldRole ?? "none")")
        if isList {
            XCTAssertNotNil(context.capturedListItemInsertion)
            XCTAssertTrue(context.textBeforeCursor?.contains(neighbors[1]) == true)
            XCTAssertTrue(context.textAfterCursor?.contains(neighbors[2]) == true)
        } else {
            XCTAssertEqual(context.textBeforeCursor, before)
            XCTAssertEqual(context.textAfterCursor, after)
        }
        _ = try XCTUnwrap(context.textBeforeCursor)
        _ = try XCTUnwrap(context.textAfterCursor)
        if surroundingPageText, let prose {
            let insertion = TextInserter().preparedTextForInsertion(prose,
                targetBundleIdentifier: "com.google.Chrome", targetProcessIdentifier: pid,
                context: context, style: .formal, knownTerms: [])
            XCTAssertEqual(insertion, prose, "An empty composer must preserve sentence casing and have no boundary spaces")
        }

        // Optional full live path: real capture -> configured provider ->
        // production clipboard/paste -> re-read the isolated editor result.
        if ProcessInfo.processInfo.environment["DICTATE_ASSEMBLYAI_LIVE_TESTS"] == "1" {
            let engine = AssemblyAIEngine()
            XCTAssertTrue(engine.isReady)
            guard engine.isReady else { return }
            let spoken = spoken ?? (isList ? "strawberries" : "tangerines")
            let audio = directory.appendingPathComponent("dictation.wav")
            let synthesis = Process()
            synthesis.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            synthesis.arguments = ["-o", audio.path, "--file-format=WAVE", "--data-format=LEI16@16000", spoken]
            try synthesis.run()
            synthesis.waitUntilExit()
            XCTAssertEqual(synthesis.terminationStatus, 0)
            engine.setSessionDictationContext(context)
            let text = try await engine.transcribeRecording(at: audio)
            print("Synthetic fixture model text: \(text.debugDescription)")
            XCTAssertNotNil(engine.lastInsertionPlan)
            XCTAssertFalse(try XCTUnwrap(engine.lastRawTranscript).isEmpty)
            if prose != nil {
                XCTAssertFalse(text.contains(where: \.isNewline), "Ordinary prose must not become fragment lines")
                XCTAssertTrue(text.first?.isUppercase == true)
                for phrase in ["snapping for rotation", "in this app is reversed", "everything else", "hold down shift to snap", "hold down shift to stop snapping"] {
                    XCTAssertTrue(text.localizedCaseInsensitiveContains(phrase), "Missing meaning: \(phrase)")
                }
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            try await Task.sleep(for: .milliseconds(150))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                XCTFail("Fixture lost focus; refusing to paste into another app")
                return
            }
            let clipboard = NSPasteboard.general
            let savedItems = (clipboard.pasteboardItems ?? []).map { original in
                let item = NSPasteboardItem()
                for type in original.types {
                    if let data = original.data(forType: type) { item.setData(data, forType: type) }
                }
                return item
            }
            let inserter = TextInserter()
            let insertion = inserter.preparedTextForInsertion(text,
                targetBundleIdentifier: "com.google.Chrome", targetProcessIdentifier: pid,
                context: context, style: .original, knownTerms: [],
                modelInsertionPlan: engine.lastInsertionPlan, preserveModelFormatting: engine.lastResultWasPolished)
            defer {
                if clipboard.string(forType: .string) == insertion {
                    clipboard.clearContents()
                    clipboard.writeObjects(savedItems)
                }
            }
            let result = await inserter.insertText(text, context: context, style: .original,
                targetProcessIdentifier: pid, modelInsertionPlan: engine.lastInsertionPlan,
                preserveModelFormatting: engine.lastResultWasPolished)
            XCTAssertEqual(result, .success)
            // Filling the empty <li> removes its <br> placeholder. Assert the
            // intended final rendered text, not the empty item's old newline.
            let item = expectedItem ?? (isList ? "Strawberries" : "tangerines")
            let allItems = Array(neighbors.prefix(2)) + (expectedItems ?? [item]) + Array(neighbors.suffix(2))
            let expectedList = allItems.enumerated().map { index, value in
                (ordered ? "\(index + 1). " : "• ") + value
            }.joined()
            let expected = prose != nil ? text : (plainNumbered ? before + "Tangerines\n4. Blueberries\n5. Oranges\n6. Flowers" : isList ? "I need to buy:" + expectedList
                : before + " " + item + (inlineAtEnd ? "" : "," + after))
            var actual = ""
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                let updated = await Task.detached {
                    DictationContextCapture.capture(processIdentifier: pid,
                        bundleIdentifier: "com.google.Chrome", appName: "Chrome fixture", rules: [])
                }.value
                actual = (updated.textBeforeCursor ?? "") + (updated.selectedText ?? "") + (updated.textAfterCursor ?? "")
                if actual == expected { break }
            }
            print("Live Chromium pasted result: \(actual.debugDescription)")
            XCTAssertEqual(actual, expected)
        }
    }
}
