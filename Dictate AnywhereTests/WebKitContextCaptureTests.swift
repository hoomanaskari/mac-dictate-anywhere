import AppKit
import XCTest
@testable import Dictate_Anywhere

/// Separate disposable WebKit process; never reads another user's app. Keeping
/// WebKit out of the test host also avoids reentrant self-AX calls off its main thread.
@MainActor
final class WebKitContextCaptureTests: XCTestCase {
    func testEmptyWebKitComposerIgnoresSurroundingPage() async throws {
        try await captureFixture(staleSelection: false)
    }

    func testEmptyWebKitComposerRejectsStalePageSelection() async throws {
        try await captureFixture(staleSelection: true)
    }

    func testWebKitAttachmentDoesNotBecomeProseBeforeTheCaret() async throws {
        try await captureFixture(staleSelection: false, attachment: true)
    }

    private func captureFixture(staleSelection: Bool, attachment: Bool = false) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATE_WEBKIT_CAPTURE_TESTS"] == "1")
        try XCTSkipUnless(AXIsProcessTrusted(), "Requires the test app's existing Accessibility permission")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("main.swift")
        try Self.hostSource.write(to: source, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("WebKitFixture")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", source.path, "-o", executable.path]
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        guard compile.terminationStatus == 0 else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [staleSelection ? "stale" : "normal", attachment ? "attachment" : "plain"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let pid = process.processIdentifier
        var context: DictationContext?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let captured = await Task.detached {
                DictationContextCapture.capture(processIdentifier: pid,
                    bundleIdentifier: "com.example.disposable-webkit", appName: "WebKit fixture", rules: [])
            }.value
            if captured.fieldRole == "AXTextArea" { context = captured; break }
        }
        let captured = try XCTUnwrap(context, "Fixture did not expose the editor")
        print("WebKit fixture attachment=\(attachment) before=\(captured.textBeforeCursor.debugDescription) after=\(captured.textAfterCursor.debugDescription)")
        XCTAssertEqual(captured.fieldRole, "AXTextArea")
        if !staleSelection { XCTAssertTrue(captured.hasTextPositionSnapshot) }
        // WebKit represents an empty <p><br></p> as a structural newline.
        XCTAssertEqual((captured.textBeforeCursor ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(captured.selectedText ?? "", "")
        XCTAssertEqual((captured.textAfterCursor ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertFalse(captured.continuesExistingSentence)
        let text = attachment ? "how about we set up error tracking for PostHog?" : "Also, does the production point at Vercel or Netlify?"
        let insertion = TextInserter().preparedTextForInsertion(text,
            targetBundleIdentifier: captured.bundleIdentifier, targetProcessIdentifier: pid,
            context: captured, style: .formal, knownTerms: [])
        XCTAssertEqual(insertion, attachment ? "How about we set up error tracking for PostHog?" : text)
    }

    private static let hostSource = #"""
        import AppKit
        import WebKit
        final class Host: NSObject, NSApplicationDelegate, WKNavigationDelegate {
            var window: NSWindow!
            var webView: WKWebView!
            func applicationDidFinishLaunching(_ notification: Notification) {
                webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
                window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Disposable WebKit dictation fixture"
                window.contentView = webView
                webView.navigationDelegate = self
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                let image = CommandLine.arguments.contains("attachment") ? "<img alt='Screenshot' width='40' height='40' src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2240%22 height=%2240%22%3E%3Crect width=%2240%22 height=%2240%22 fill=%22red%22/%3E%3C/svg%3E'>" : ""
                webView.loadHTMLString("<p id='reference'>Previous conversation without punctuation</p><div id='editor' contenteditable='true' role='textbox' aria-multiline='true'>\(image)<p id='prose'><br></p></div><p>Text following the composer</p>", baseURL: nil)
            }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                let target = CommandLine.arguments.contains("stale") ? "document.getElementById('reference').firstChild, 12" : "document.getElementById('prose'), 0"
                webView.evaluateJavaScript("const editor = document.getElementById('editor'); editor.focus(); const r = document.createRange(); r.setStart(\(target)); r.collapse(true); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);")
            }
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let host = Host()
        application.delegate = host
        application.run()
        """#
}
