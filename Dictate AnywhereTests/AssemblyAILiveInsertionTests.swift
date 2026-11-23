import AppKit
import XCTest
@testable import Dictate_Anywhere

/// Explicitly opt in with TEST_RUNNER_DICTATE_ASSEMBLYAI_LIVE_TESTS=1 when
/// invoking xcodebuild. Uses the Dev app's configured provider and credentials;
/// sends only generated grocery audio and the fixture text below.
final class AssemblyAILiveInsertionTests: XCTestCase {
    #if DEBUG
    @MainActor
    func testLiveUploadAgainstFinishedRecording() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATE_ASSEMBLYAI_UPLOAD_TEST"] == "1")
        let engine = AssemblyAIEngine()
        try XCTSkipUnless(engine.isReady, "Configure an AssemblyAI key in the Dev app.")
        let region = Settings.shared.assemblyAIRegion
        let fixtures = [
            (spoken: "Please send the prototype to Maya.", languages: ["en"], keyterm: "Maya"),
            (spoken: "I'll meet you on Thursday, sorry, Friday, at four thirty.",
             languages: ["en"], keyterm: "Friday"),
            (spoken: "Let's send the Artboard Studio prototype before lunch. Merci beaucoup.",
             languages: ["en", "fr"], keyterm: "Artboard Studio"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var finishedTimes: [Double] = []
        var liveTimes: [Double] = []

        for (index, fixture) in fixtures.enumerated() {
            let url = directory.appendingPathComponent("upload-\(index).wav")
            let synthesis = Process()
            synthesis.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            synthesis.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", fixture.spoken]
            try synthesis.run()
            synthesis.waitUntilExit()
            XCTAssertEqual(synthesis.terminationStatus, 0)
            let reader = try RecoveryAudioReader(url: url)
            var samples: [Float] = []
            while let chunk = try reader.nextSamples() { samples.append(contentsOf: chunk) }
            XCTAssertFalse(samples.isEmpty)

            let config = AssemblyAIRequestConfiguration(
                sampleRate: AssemblyAIEngine.sampleRate, channels: 1, languageCodes: fixture.languages,
                sttPrompt: nil, keytermsPrompt: [fixture.keyterm],
                llmInstruction: "Return the dictation as a polished message. Resolve clear spoken self-corrections."
            )
            let boundary = UUID().uuidString
            func finished() async throws -> (response: AssemblyAIDictationResponse, milliseconds: Double) {
                await AssemblyAIEngine.warmConnection(region: region)
                let stop = ContinuousClock.now
                var request = AssemblyAIEngine.request(baseURL: region.baseURL, live: false,
                                                       apiKey: engine.apiKey(), boundary: boundary)
                request.httpBody = try AssemblyAIEngine.multipartBody(config: config, samples: samples, boundary: boundary)
                let (data, response) = try await engine.sendRequest(request)
                let decoded = try AssemblyAIEngine.decodeResponse(data: data, response: response)
                return (decoded, BenchmarkStatistics.elapsedMilliseconds(from: stop))
            }
            func live() async throws -> (response: AssemblyAIDictationResponse, milliseconds: Double) {
                let audio = AssemblyAILiveAudio()
                let upload = Task { try await engine.transcribeLive(audio: audio, configuration: config, region: region) }
                defer { upload.cancel(); audio.finish() }
                // Match a microphone feeding 100 ms of 16 kHz speech at a time.
                for offset in stride(from: 0, to: samples.count, by: 1_600) {
                    let end = min(samples.count, offset + 1_600)
                    audio.append(Array(samples[offset..<end]))
                    try await Task.sleep(for: .microseconds((end - offset) * 1_000_000 / AssemblyAIEngine.sampleRate))
                }
                let stop = ContinuousClock.now
                audio.finish()
                let decoded = try await upload.value
                return (decoded, BenchmarkStatistics.elapsedMilliseconds(from: stop))
            }

            let batch: (response: AssemblyAIDictationResponse, milliseconds: Double)
            let streamed: (response: AssemblyAIDictationResponse, milliseconds: Double)
            if index.isMultiple(of: 2) {
                batch = try await finished()
                streamed = try await live()
            } else {
                streamed = try await live()
                batch = try await finished()
            }
            finishedTimes.append(batch.milliseconds)
            liveTimes.append(streamed.milliseconds)
            for response in [batch.response, streamed.response] {
                XCTAssertTrue(response.text.localizedCaseInsensitiveContains(fixture.keyterm))
                XCTAssertTrue(response.llmResponse?.localizedCaseInsensitiveContains(fixture.keyterm) == true)
            }
            print("UPLOAD_COMPARISON fixture=\(index) audio_s=\(Double(samples.count) / 16_000) "
                  + "finished_ms=\(batch.milliseconds) live_ms=\(streamed.milliseconds) "
                  + "finished_raw=\(batch.response.text.debugDescription) live_raw=\(streamed.response.text.debugDescription) "
                  + "finished_polished=\(batch.response.llmResponse ?? "") live_polished=\(streamed.response.llmResponse ?? "")")
        }
        BenchmarkStatistics(finishedTimes).report(component: "assemblyai-finished")
        BenchmarkStatistics(liveTimes).report(component: "assemblyai-live")
    }
    #endif

    @MainActor
    func testLiveSentenceAndListInsertions() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DICTATE_ASSEMBLYAI_LIVE_TESTS"] == "1")
        let settings = Settings.shared
        try XCTSkipUnless(settings.assemblyAIOutputMode == .polished
            && settings.dictationContextAwarenessEnabled
            && settings.shareDictationContextWithRemoteProviders,
            "Requires Polished mode with context sharing enabled in the Dev app.")
        let engine = AssemblyAIEngine()
        try XCTSkipUnless(engine.isReady, "Configure an AssemblyAI key in the Dev app.")
        let testCapture = ProcessInfo.processInfo.environment["DICTATE_LIVE_CAPTURE_TESTS"] == "1"
        if testCapture {
            XCTAssertTrue(AXIsProcessTrusted(), "The signed test host needs existing Accessibility permission; this test never requests it.")
            guard AXIsProcessTrusted() else { return }
        }

        let fixtures = [
            (spoken: "tangerines", before: "I need to buy some groceries: apples, bananas,",
             after: " oranges, and some sourdough starter.",
             expected: "I need to buy some groceries: apples, bananas, tangerines, oranges, and some sourdough starter."),
            (spoken: "strawberries", before: "I need to buy:\n- Apples\n- Bananas\n- ",
             after: "\n- Oranges\n- Flowers",
             expected: "I need to buy:\n- Apples\n- Bananas\n- Strawberries\n- Oranges\n- Flowers"),
            (spoken: "strawberries", before: "I need to buy:\nApples\nBananas\n",
             after: "\nOranges\nFlowers",
             expected: "I need to buy:\nApples\nBananas\nStrawberries\nOranges\nFlowers"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, fixture) in fixtures.enumerated() {
            let audio = directory.appendingPathComponent("fixture-\(index).wav")
            let synthesis = Process()
            synthesis.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            synthesis.arguments = ["-o", audio.path, "--file-format=WAVE", "--data-format=LEI16@16000", fixture.spoken]
            try synthesis.run()
            synthesis.waitUntilExit()
            guard synthesis.terminationStatus == 0 else {
                XCTFail("Could not synthesize fixture audio")
                return
            }
            var context = DictationContext(
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: "com.example.insertion-fixture", appName: "Insertion Test",
                category: .other, documentURL: nil, documentTitle: nil,
                fieldRole: "AXTextArea", fieldSubrole: nil, fieldPurpose: .unknown,
                textBeforeCursor: fixture.before, selectedText: "", textAfterCursor: fixture.after,
                isSecureField: false, isContextExcluded: false
            )
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 260))
            editor.string = fixture.before + fixture.after
            editor.setSelectedRange(NSRange(location: fixture.before.utf16.count, length: 0))
            let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Dictation insertion test fixture"
            window.contentView = editor
            defer { window.close() }
            if testCapture {
                let pid = ProcessInfo.processInfo.processIdentifier
                // App activation and AX focus are asynchronous, especially on
                // the first fixture while the test host is still launching.
                for _ in 0..<20 {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(editor)
                    try await Task.sleep(for: .milliseconds(100))
                    context = await Task.detached {
                        DictationContextCapture.capture(processIdentifier: pid,
                            bundleIdentifier: "com.example.insertion-fixture", appName: "Insertion Test", rules: [])
                    }.value
                    if context.textBeforeCursor == fixture.before && context.textAfterCursor == fixture.after { break }
                }
                XCTAssertEqual(context.textBeforeCursor, fixture.before)
                XCTAssertEqual(context.textAfterCursor, fixture.after)
                guard context.hasTextPositionSnapshot else { return }
            }
            engine.setSessionDictationContext(context)
            let text = try await engine.transcribeRecording(at: audio)
            XCTAssertNotNil(engine.lastInsertionPlan, "Provider must return an insertion plan for fixture \(index)")
            let insertion = TextInserter().preparedTextForInsertion(
                text, targetBundleIdentifier: context.bundleIdentifier,
                targetProcessIdentifier: context.processIdentifier, context: context,
                style: settings.dictationWritingStyle(for: .other), knownTerms: [],
                modelInsertionPlan: engine.lastInsertionPlan,
                preserveModelFormatting: engine.lastResultWasPolished
            )
            editor.insertText(insertion, replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, fixture.expected, "Live provider fixture \(index)")
            print("Live insertion fixture \(index) (capture=\(testCapture)): \(editor.string.debugDescription)")
        }
    }
}
