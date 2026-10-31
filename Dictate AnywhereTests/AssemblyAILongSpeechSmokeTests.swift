import XCTest
import Security
@testable import Dictate_Anywhere

/// Generate the fixture before opting in (default output directory /tmp/dictate-long-speech):
/// say -v Samantha -r 155 -f "Dictate AnywhereTests/Fixtures/en-long-dictation.txt" -o /tmp/dictate-long-speech/speech.aiff
/// afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/dictate-long-speech/speech.aiff /tmp/dictate-long-speech/speech.wav
/// Run with TEST_RUNNER_RUN_ASSEMBLYAI_LONG_SPEECH_TEST=1 and select this test class.
/// Explicit opt-in: sends only the caller-supplied synthetic fixture to the
/// real provider. Never runs in the ordinary test suite or logs credentials.
@MainActor
final class AssemblyAILongSpeechSmokeTests: XCTestCase {
    func testRealProviderLongSpeechAndCachedRecovery() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RUN_ASSEMBLYAI_LONG_SPEECH_TEST"] == "1", "Opt-in real-provider test")
        let root = URL(fileURLWithPath: env["ASSEMBLYAI_SPEECH_TEST_DIRECTORY"] ?? "/tmp/dictate-long-speech")
        let key = savedAPIKey()
        try XCTSkipUnless(!key.isEmpty, "No existing AssemblyAI credential available")
        let settings = Settings.shared
        let oldMode = settings.assemblyAIOutputMode
        let oldInstruction = settings.assemblyAIInstruction
        let oldPrompts = settings.assemblyAIPromptOverrides
        let oldLanguage = settings.assemblyAILanguage
        settings.assemblyAIOutputMode = .polished
        settings.assemblyAIInstruction = "Preserve every distinctive marker, deliberate repetition, and all substantive details. Do not summarize."
        for prompt in AssemblyAIInternalPrompt.allCases { settings.resetAssemblyAIPrompt(prompt) }
        settings.assemblyAILanguage = .english
        defer {
            settings.assemblyAIOutputMode = oldMode
            settings.assemblyAIInstruction = oldInstruction
            for prompt in AssemblyAIInternalPrompt.allCases {
                if let value = oldPrompts[prompt.rawValue] { settings.setAssemblyAIPrompt(value, for: prompt) }
                else { settings.resetAssemblyAIPrompt(prompt) }
            }
            settings.assemblyAILanguage = oldLanguage
        }
        let recovery = DictationRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let capture = try recovery.beginCapture()
        let reader = try RecoveryAudioReader(url: root.appendingPathComponent("speech.wav"))
        var sampleCount = 0
        while let samples = try reader.nextSamples() {
            sampleCount += samples.count
            capture.append(samples)
        }
        XCTAssertGreaterThan(sampleCount, 5 * 60 * 16_000, "Fixture must actually exceed five minutes")
        let entry = try await recovery.preserve(capture, preview: "", completedTranscript: nil)
        XCTAssertNotNil(entry)
        let engine = AssemblyAIEngine()
        engine.apiKey = { key }
        var requests: [[String: Any]] = []
        var audioRequests = 0
        engine.sendRequest = { request in
            let start = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if request.url?.path == "/v1/transcribe" { audioRequests += 1 }
            requests.append([
                "host": request.url?.host ?? "", "path": request.url?.path ?? "", "status": status,
                "seconds": Date().timeIntervalSince(start),
                "response": (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
            ])
            try JSONSerialization.data(withJSONObject: requests, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("requests.json"), options: .atomic)
            print("ASSEMBLYAI_LIVE_REQUEST path=\(request.url?.path ?? "") status=\(status) seconds=\(Date().timeIntervalSince(start))")
            return (data, response)
        }
        let started = Date()
        let polished = try await engine.transcribeRecording(at: capture.url)
        let elapsed = Date().timeIntervalSince(started)
        let raw = try XCTUnwrap(engine.lastRawTranscript)
        try raw.write(to: root.appendingPathComponent("raw.txt"), atomically: true, encoding: .utf8)
        try polished.write(to: root.appendingPathComponent("polished.txt"), atomically: true, encoding: .utf8)
        let markers = ["amber lantern", "cobalt compass", "silver meadow", "violet harbor", "copper orchard",
                       "emerald bridge", "golden notebook", "indigo waterfall", "scarlet telescope",
                       "turquoise garden", "coral mountain", "sapphire bicycle", "bronze umbrella"]
        let missingRaw = markers.filter { !raw.localizedCaseInsensitiveContains($0) }
        let missingPolished = markers.filter { !polished.localizedCaseInsensitiveContains($0) }
        let repeated = "i want to repeat this point because it matters"
        let normalized = raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        let repetitions = normalized.components(separatedBy: repeated).count - 1
        let results: [String: Any] = [
            "audio_seconds": Double(sampleCount) / 16_000, "elapsed_seconds": elapsed,
            "audio_requests": audioRequests, "all_requests": requests.count,
            "missing_raw_markers": missingRaw, "missing_polished_markers": missingPolished,
            "deliberate_repetitions_in_raw": repetitions, "cleanup_succeeded": engine.lastResultWasPolished,
            "source_audio": capture.url.path
        ]
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("results.json"), options: .atomic)
        XCTAssertTrue(missingRaw.isEmpty, "Missing raw markers: \(missingRaw)")
        XCTAssertTrue(missingPolished.isEmpty, "Missing polished markers: \(missingPolished)")
        XCTAssertEqual(repetitions, 2, "Overlap stitching must preserve intentional repetition")
        XCTAssertTrue(raw.localizedCaseInsensitiveContains("evening rain began"), "Final words were lost")
        XCTAssertTrue(engine.lastResultWasPolished, "The real whole-transcript cleanup must succeed")
        // Simulate recovery with the network unavailable: completed recognition
        // must come from disk. Verbatim mode does not need another cleanup call.
        settings.assemblyAIOutputMode = .verbatim
        engine.sendRequest = { _ in
            XCTFail("Recovery attempted to resend successfully cached audio")
            throw URLError(.notConnectedToInternet)
        }
        let recovered = try await engine.transcribeRecording(at: capture.url)
        XCTAssertEqual(recovered, raw)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.url.path))
        print("ASSEMBLYAI_LONG_SPEECH duration=\(Double(sampleCount) / 16_000) audio_requests=\(audioRequests) elapsed=\(elapsed) markers=\(markers.count - missingRaw.count)/\(markers.count) cached_recovery=true")
    }

    func testInstalledAppleLivePreviewWithLongSpeech() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RUN_ASSEMBLYAI_LONG_SPEECH_TEST"] == "1", "Opt-in long speech preview test")
        let root = URL(fileURLWithPath: env["ASSEMBLYAI_SPEECH_TEST_DIRECTORY"] ?? "/tmp/dictate-long-speech")
        let observation = LivePreviewObservation()
        guard let session = try await AppleSpeechEngine.makeInstalledLivePreviewSession(
            languageCode: "en", contextualVocabulary: [], onTranscript: { text, partial in
                observation.update(text, partial: partial)
            }) else { throw XCTSkip("English Apple Speech assets are not installed") }
        try await session.start()
        let reader = try RecoveryAudioReader(url: root.appendingPathComponent("speech.wav"))
        let start = Date()
        var fed = 0
        while let samples = try reader.nextSamples(maxSamples: 16_000) {
            session.append(samples: samples)
            fed += samples.count
            // Accelerated replay gives incremental callbacks time to run while
            // exercising the same on-device session used during dictation.
            try await Task.sleep(for: .milliseconds(50))
        }
        let updatesBeforeFinish = observation.snapshot().updates
        let final = await session.finish()
        let snapshot = observation.snapshot()
        try final.write(to: root.appendingPathComponent("apple-preview.txt"), atomically: true, encoding: .utf8)
        let result: [String: Any] = ["audio_seconds": Double(fed) / 16_000,
            "elapsed_seconds": Date().timeIntervalSince(start), "updates_before_finish": updatesBeforeFinish,
            "total_updates": snapshot.updates, "partial_updates": snapshot.partials,
            "first_update_seconds": snapshot.firstUpdate?.timeIntervalSince(start) ?? -1,
            "has_beginning": final.localizedCaseInsensitiveContains("amber lantern"),
            "has_ending": final.localizedCaseInsensitiveContains("evening rain began")]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("apple-preview-results.json"), options: .atomic)
        XCTAssertGreaterThan(updatesBeforeFinish, 0, "Preview must arrive while audio is still being supplied")
        XCTAssertGreaterThan(snapshot.partials, 0)
        XCTAssertTrue(final.localizedCaseInsensitiveContains("amber lantern"))
        XCTAssertTrue(final.localizedCaseInsensitiveContains("evening rain began"))
        print("APPLE_LONG_PREVIEW updates_before_finish=\(updatesBeforeFinish) partials=\(snapshot.partials) duration=\(Double(fed) / 16_000)")
    }

    private func savedAPIKey() -> String {
        let configured = Settings.shared.resolvedAssemblyAIAPIKey
        if !configured.isEmpty { return configured }
        // The debug app has a different keychain service from the installed
        // release. Read the same provider credential without changing either.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pixelforty.dictate-anywhere.assemblyai",
            kSecAttrAccount as String: "assemblyai-api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated private final class LivePreviewObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0
    private var partials = 0
    private var firstUpdate: Date?
    func update(_ text: String, partial: Bool) {
        lock.withLock {
            guard !text.isEmpty else { return }
            updates += 1
            if partial { partials += 1 }
            if firstUpdate == nil { firstUpdate = Date() }
        }
    }
    func snapshot() -> (updates: Int, partials: Int, firstUpdate: Date?) {
        lock.withLock { (updates, partials, firstUpdate) }
    }
}
