import XCTest
import os
@testable import Dictate_Anywhere

final class S1MiniPostProcessingTests: XCTestCase {
    func testModelRemovalInvalidatesThePreparedRuntimeRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-removal-\(UUID())")
        let manager = S1MiniModelManager(modelDirectory: directory)
        let previousRevision = manager.runtimeRevision
        try await manager.deleteModel()
        XCTAssertNotEqual(manager.runtimeRevision, previousRevision, "Reinstalling at the same path must not restore an old Ready status")
        XCTAssertFalse(manager.isModelDownloaded)
    }

    func testLiteralMarkerFallbackDoesNotClaimPreparedRuntime() async throws {
        await S1MiniPostProcessingService.unload()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-readiness-\(UUID()).gguf")
        let text = "Keep the literal <|im_start|> marker."
        let output = try await process(text, modelURL: url)
        XCTAssertEqual(output, text)
        let ready = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertFalse(ready)
    }

    #if DEBUG || PIPELINE_BENCHMARK
    func testRealContextReuseMatchesFreshRequestsAndClearsHistory() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check context reuse") }
        let url = URL(fileURLWithPath: path)
        let engine = S1MiniInferenceEngine.shared
        addTeardownBlock {
            await engine.configureInputDraftingForTesting(true)
            await engine.unload()
        }
        await engine.unload()
        let fixtures = [
            (id: "invoice", input: "Send invoice 43 on Thursday."),
            (id: "question", input: "When does the office open?"),
            (id: "name", input: "Please send the report to Nadia tomorrow."),
            (id: "repeated", input: "send invoice 43 to Nadia. send invoice 430 to Mara. do not cancel invoice 43.")
        ]
        for styling in S1MiniStyling.allCases {
            var baseline: [String: String] = [:]
            await engine.configureInputDraftingForTesting(false)
            for fixture in fixtures {
                await engine.discardInferenceContextForTesting()
                baseline[fixture.id] = try await S1MiniPostProcessingService.process(
                    text: fixture.input, modelURL: url, styling: styling,
                    structure: .prose, contextSetting: .general, context: nil)
            }
            await engine.configureInputDraftingForTesting(true)
            // Reverse order to catch both incorrect proposal acceptance and
            // names/numbers leaking from an earlier request's retained context.
            for fixture in fixtures.reversed() {
                let output = try await S1MiniPostProcessingService.process(
                    text: fixture.input, modelURL: url, styling: styling,
                    structure: .prose, contextSetting: .general, context: nil)
                XCTAssertEqual(output, baseline[fixture.id], "\(styling)/\(fixture.id)")
                let state = await engine.inferenceContextStateForTesting()
                XCTAssertTrue(state.allocated)
                XCTAssertEqual(state.maximumPosition, -1, "A completed request retained KV token positions")
                let ready = await S1MiniPostProcessingService.isPrepared(modelURL: url)
                XCTAssertTrue(ready, "Successful first use prepares the retained runtime")
            }
        }
        await engine.unload()
        let state = await engine.inferenceContextStateForTesting()
        XCTAssertFalse(state.allocated)
    }

    func testRealModelPathChangeReleasesContextBeforeReplacingWeights() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check context ownership") }
        let url = URL(fileURLWithPath: path)
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("s1-context-model-\(UUID()).gguf")
        try FileManager.default.linkItem(at: url, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        let engine = S1MiniInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
        _ = try await engine.transcriptChunks("Hello.", modelURL: alias)
        let state = await engine.inferenceContextStateForTesting()
        XCTAssertFalse(state.allocated, "A context must not outlive the model it references")
        let output = try await process("Send invoice 43 on Thursday.", modelURL: alias)
        XCTAssertTrue(output.contains("43"))
        XCTAssertTrue(output.lowercased().contains("thursday"))
        await engine.unload()
    }
    #endif

    #if DEBUG
    func testRealCancellationAfterPromptDiscardsContextAndNextRequestRecovers() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check cancelled context") }
        let url = URL(fileURLWithPath: path)
        let engine = S1MiniInferenceEngine.shared
        await engine.unload()
        try await engine.prewarm(from: url)
        PerfTrace.onIntervalCompleted = { name, _, _ in
            if name == "cleanup.prefillSchedule" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        defer { PerfTrace.onIntervalCompleted = nil }
        let cancelled = Task {
            try await self.process("Please send invoice 812 to Mara.", modelURL: url)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation after prompt evaluation")
        } catch is CancellationError {
            // The context contained a real prompt before cancellation.
        }
        PerfTrace.onIntervalCompleted = nil
        let discarded = await engine.inferenceContextStateForTesting()
        XCTAssertFalse(discarded.allocated)
        let readyAfterCancellation = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertFalse(readyAfterCancellation)
        let recovered = try await process("Keep invoice 43 for Nadia.", modelURL: url)
        XCTAssertTrue(recovered.contains("43"))
        XCTAssertTrue(recovered.lowercased().contains("nadia"))
        XCTAssertFalse(recovered.contains("812"))
        XCTAssertFalse(recovered.lowercased().contains("mara"))
        await engine.unload()
    }
    #endif

    func testRealPrewarmRunsInferenceOnceAndKeepsTheNextRequestIndependent() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check inference prewarm") }
        let url = URL(fileURLWithPath: path)
        await S1MiniPostProcessingService.unload()
        let firstReady = await S1MiniPostProcessingService.prewarm(modelURL: url)
        let runtimeReady = await S1MiniPostProcessingService.isPrepared(modelURL: url)
        XCTAssertEqual(runtimeReady, firstReady)
        XCTAssertTrue(firstReady)
        #if DEBUG || PIPELINE_BENCHMARK
        let prepared = await S1MiniInferenceEngine.shared.inferenceContextStateForTesting()
        XCTAssertTrue(prepared.allocated, "Prewarm must retain the inference allocations")
        XCTAssertEqual(prepared.maximumPosition, -1, "Synthetic warmup must clear its KV cache")
        #endif
        #if DEBUG
        let events = OSAllocatedUnfairLock(initialState: [String]())
        PerfTrace.onIntervalCompleted = { name, _, _ in
            if name == "cleanup.generate" { events.withLock { $0.append(name) } }
        }
        #endif
        let secondReady = await S1MiniPostProcessingService.prewarm(modelURL: url)
        XCTAssertTrue(secondReady)
        #if DEBUG
        PerfTrace.onIntervalCompleted = nil
        XCTAssertTrue(events.withLock { $0.isEmpty }, "An already-warm model must not repeat synthetic inference")
        #endif
        let output = try await process("Send invoice 43 on Friday no sorry Thursday.", modelURL: url)
        XCTAssertTrue(output.contains("43"))
        XCTAssertTrue(output.lowercased().contains("thursday"))
        XCTAssertFalse(output.lowercased().contains("hello"))
        XCTAssertFalse(output.lowercased().contains("friday"))
        await S1MiniPostProcessingService.unload()
    }

    func testLongTranscriptChunksPreserveSentencesAndEveryCharacter() throws {
        let text = "Please send the report.\nWe need it tomorrow. Keep the invoice for 23 dollars."
        let chunks = try S1MiniTranscriptChunker.chunks(text, maximumTokens: 7) {
            $0.split(whereSeparator: \.isWhitespace).count
        }
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.hasSuffix(".\n"))
        XCTAssertTrue(chunks.allSatisfy { $0.tokenCount <= 7 })
    }

    func testChunkAssemblyPreservesSourceSeparatorsAfterNormalizedRewrites() async throws {
        for text in ["  Keep invoice 43.\n\nSend invoice 44.\n\nKeep invoice 45.\t ",
                     "- Keep invoice 43.\n- Send invoice 44.\n- Keep invoice 45.\n",
                     "Keep 43. Send 44. Keep 45.", " \n\t"] {
            let chunks = try S1MiniTranscriptChunker.chunks(text, maximumTokens: 5) {
                $0.split(whereSeparator: \.isWhitespace).count
            }
            if text.contains("invoice") { XCTAssertGreaterThan(chunks.count, 1) }
            let output = try await S1MiniPostProcessingService.processChunks(chunks) { chunk in
                normalizePostProcessedTranscript(chunk.text).replacingOccurrences(of: "Keep", with: "Retain")
            }
            XCTAssertEqual(output, text.replacingOccurrences(of: "Keep", with: "Retain"))
        }
    }

    func testLongSentenceChunksAtWordBoundariesAndShortTextStaysWhole() throws {
        let text = "one two three four five six seven eight nine ten"
        let count: (String) -> Int = { $0.split(whereSeparator: \.isWhitespace).count }
        let chunks = try S1MiniTranscriptChunker.chunks(text, maximumTokens: 4, tokenCount: count)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.text.last?.isWhitespace == true })
        XCTAssertTrue(chunks.allSatisfy { $0.tokenCount == count($0.text) && $0.tokenCount <= 4 })
        XCTAssertEqual(try S1MiniTranscriptChunker.chunks("Keep 43.", maximumTokens: 4, tokenCount: count).map(\.text), ["Keep 43."])
        XCTAssertThrowsError(try S1MiniTranscriptChunker.chunks("unbroken", maximumTokens: 3, tokenCount: { $0.count }))
    }

    func testRealRepeatedLongTranscriptCannotLoseNumbersWhenModelIsAvailable() async throws {
        guard let path = realModelPath() else { throw XCTSkip("Install S1-mini to check real long-input cleanup") }
        let text = (1...110).map { "Please keep invoice \($0) and send the report tomorrow." }.joined(separator: " ")
        let url = URL(fileURLWithPath: path)
        let chunks = try await S1MiniInferenceEngine.shared.transcriptChunks(text, modelURL: url)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        let output = try await process(text, modelURL: url)
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.lowercased().contains("invoice"))
        XCTAssertTrue(output.lowercased().contains("tomorrow"))
        let numbers = output.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        XCTAssertEqual(Set(numbers), Set(1...110), "Cleanup lost an invoice number around a chunk boundary")
        await S1MiniPostProcessingService.unload()
    }

    func testPromptMatchesRequiredNonThinkingTrainingFormat() {
        let prompt = S1MiniPromptBuilder.prompt(
            transcript: "so um send it friday",
            styling: .semiFormal,
            structure: .prose,
            context: "general"
        )

        XCTAssertEqual(
            prompt,
            """
            <|im_start|>system
            You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.<|im_end|>
            <|im_start|>user
            [Styling: semi-formal] [Structure: prose] [Context: general]
            so um send it friday<|im_end|>
            <|im_start|>assistant
            <think>

            </think>

            """ + "\n"
        )
    }

    func testAutomaticContextUsesEmailOnlyForEmailDestinations() {
        XCTAssertEqual(S1MiniContextSetting.automatic.resolved(for: nil), "general")
        XCTAssertEqual(
            S1MiniContextSetting.automatic.resolved(for: context(category: .workMessaging)),
            "general"
        )
        XCTAssertEqual(
            S1MiniContextSetting.automatic.resolved(for: context(category: .email)),
            "email"
        )
    }

    func testRecommendedAppStylingUsesOnlyTrainedValues() {
        let styling = S1MiniAppStyling.recommended

        XCTAssertEqual(styling.styling(for: .email), .formal)
        XCTAssertEqual(styling.styling(for: .workMessaging), .semiFormal)
        XCTAssertEqual(styling.styling(for: .personalMessaging), .semiCasual)
        XCTAssertEqual(styling.styling(for: .other), .semiFormal)
        XCTAssertTrue(
            DictationContextCategory.allCases.allSatisfy {
                S1MiniStyling.allCases.contains(styling.styling(for: $0))
            }
        )
    }

    func testAppStylingCanOverrideEachCategoryIndependently() {
        var styling = S1MiniAppStyling.uniform(.semiFormal)

        styling.set(.formal, for: .email)
        styling.set(.casual, for: .personalMessaging)

        XCTAssertEqual(styling.styling(for: .email), .formal)
        XCTAssertEqual(styling.styling(for: .workMessaging), .semiFormal)
        XCTAssertEqual(styling.styling(for: .personalMessaging), .casual)
        XCTAssertEqual(styling.styling(for: .other), .semiFormal)
    }

    func testPinnedModelMetadata() {
        XCTAssertEqual(S1MiniModelSpec.byteCount, 484_219_808)
        XCTAssertEqual(
            S1MiniModelSpec.sha256,
            "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
        )
        XCTAssertTrue(S1MiniModelSpec.downloadURL.absoluteString.contains(S1MiniModelSpec.revision))
    }

    func testDownloadProgressFallsBackToPinnedSizeWhenServerLengthIsUnknown() {
        let fraction = S1MiniDownloadProgress.transferFraction(
            totalBytesWritten: S1MiniModelSpec.byteCount / 4,
            serverExpectedByteCount: NSURLSessionTransferSizeUnknown
        )

        XCTAssertEqual(fraction, 0.25, accuracy: 0.000_001)
    }

    func testDownloadProgressUsesPinnedSizeForMismatchedRedirectLength() {
        let fraction = S1MiniDownloadProgress.transferFraction(
            totalBytesWritten: S1MiniModelSpec.byteCount / 2,
            serverExpectedByteCount: 1_024
        )

        XCTAssertEqual(fraction, 0.5, accuracy: 0.000_001)
    }

    func testInstallationProgressDoesNotMoveBackwards() {
        XCTAssertEqual(
            S1MiniDownloadProgress.installationProgress(current: 0.6, transferFraction: 0.25),
            0.6,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            S1MiniDownloadProgress.installationProgress(current: 0, transferFraction: 0.5),
            0.49,
            accuracy: 0.000_001
        )
    }

    func testStreamingSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try S1MiniModelIntegrity.sha256(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testIntegrityRejectsWrongFileSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-invalid-\(UUID().uuidString)")
        try Data("not a model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try S1MiniModelIntegrity.validate(url)) { error in
            guard case S1MiniModelManagerError.unexpectedFileSize = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testInstallationRequiresDownloadedLicense() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-license-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let modelURL = directory.appendingPathComponent(S1MiniModelSpec.filename)
        XCTAssertTrue(FileManager.default.createFile(atPath: modelURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: modelURL)
        try handle.truncate(atOffset: UInt64(S1MiniModelSpec.byteCount))
        try handle.close()

        XCTAssertFalse(S1MiniModelManager(modelDirectory: directory).isModelDownloaded)

        try Data("S1-mini license".utf8).write(
            to: directory.appendingPathComponent("LICENSE"),
            options: .atomic
        )
        XCTAssertTrue(S1MiniModelManager(modelDirectory: directory).isModelDownloaded)
    }

    func testModelManagerValidatesAndDeletesInstalledModelWhenRealModelExists() async throws {
        let sourcePath = realModelPath()
        guard let sourcePath else {
            throw XCTSkip("Set S1_MINI_MODEL_PATH to run the verified model lifecycle test.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let installedURL = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try FileManager.default.linkItem(
            at: URL(fileURLWithPath: sourcePath),
            to: installedURL
        )
        try Data("S1-mini license".utf8).write(
            to: directory.appendingPathComponent("LICENSE"),
            options: .atomic
        )

        let manager = S1MiniModelManager(modelDirectory: directory)
        let validatedURL = try await manager.validatedModelURL()
        XCTAssertEqual(validatedURL, installedURL)
        XCTAssertTrue(manager.isModelDownloaded)

        try await manager.deleteModel()
        XCTAssertFalse(manager.isModelDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePath))
    }

    @MainActor
    func testStartupRefreshAndPrewarmShareOneIntegrityCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-concurrent-validation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelURL = directory.appendingPathComponent(S1MiniModelSpec.filename)
        try Data().write(to: modelURL)
        let modelFile = try FileHandle(forWritingTo: modelURL)
        try modelFile.truncate(atOffset: UInt64(S1MiniModelSpec.byteCount))
        try modelFile.close()
        try Data("license".utf8).write(to: directory.appendingPathComponent("LICENSE"))

        let started = expectation(description: "integrity check started")
        let gate = S1ValidationGate(started: started)
        let manager = S1MiniModelManager(modelDirectory: directory) { _ in
            try gate.validate()
        }
        let refresh = Task { await manager.refreshInstallationState() }
        await fulfillment(of: [started], timeout: 5)
        let prewarm = Task { try await manager.validatedModelURL() }
        try await Task.sleep(for: .milliseconds(30))

        gate.release()
        await refresh.value
        let validatedURL = try await prewarm.value
        XCTAssertEqual(validatedURL, manager.modelURL)
        XCTAssertEqual(gate.callCount, 1)
        XCTAssertTrue(manager.isModelDownloaded)
        XCTAssertFalse(manager.isVerifying)
    }

    @MainActor
    func testRefreshWithoutInstalledModelDoesNotReportDownloadFailure() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-not-installed-\(UUID())", isDirectory: true)
        let manager = S1MiniModelManager(modelDirectory: directory)

        await manager.refreshInstallationState()

        XCTAssertFalse(manager.isModelDownloaded)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isVerifying)
    }

    func testRealPinnedDownloadInstallAndDeleteWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["S1_MINI_DOWNLOAD_TEST"] == "1" else {
            throw XCTSkip("Set S1_MINI_DOWNLOAD_TEST=1 to exercise the live Hugging Face download.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-mini-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = S1MiniModelManager(modelDirectory: directory)
        let downloadTask = Task { try await manager.downloadModel() }
        for _ in 0..<100 where !manager.isDownloading {
            try await Task.sleep(for: .milliseconds(10))
        }

        var intermediateProgressSamples: [Double] = []
        while manager.isDownloading {
            let progress = manager.downloadProgress
            if progress > 0, progress < S1MiniDownloadProgress.installationFraction {
                intermediateProgressSamples.append(progress)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await downloadTask.value

        XCTAssertTrue(manager.isModelDownloaded)
        XCTAssertEqual(manager.downloadProgress, 1)
        XCTAssertFalse(
            intermediateProgressSamples.isEmpty,
            "The live download never published intermediate progress."
        )
        XCTAssertGreaterThan(
            Set(intermediateProgressSamples.map { Int($0 * 1_000) }).count,
            1,
            "The live download progress did not visibly advance."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.modelURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.licenseURL.path))
        let validatedURL = try await manager.validatedModelURL()
        XCTAssertEqual(validatedURL, manager.modelURL)

        try await manager.deleteModel()
        XCTAssertFalse(manager.isModelDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.modelURL.path))
    }

    func testRealModelWhenPathIsProvided() async throws {
        let path = realModelPath()
        guard let path else {
            throw XCTSkip("Set S1_MINI_MODEL_PATH to run the local inference smoke test.")
        }

        let modelURL = URL(fileURLWithPath: path)
        let correction = try await process(
            "so um i need to like send the the report by uh friday no wait make that thursday",
            modelURL: modelURL
        )
        XCTAssertFalse(correction.lowercased().contains(" um "))
        XCTAssertFalse(correction.lowercased().contains(" uh "))
        XCTAssertFalse(correction.contains("Friday"))
        XCTAssertTrue(correction.contains("Thursday"))

        let numberCorrection = try await process(
            "i think the answer is forty two no sorry forty three",
            modelURL: modelURL
        )
        XCTAssertTrue(numberCorrection.contains("43"), numberCorrection)
        XCTAssertFalse(numberCorrection.contains("42"), numberCorrection)

        let timeCorrection = try await process(
            "let's meet at half past two tomorrow uh actually make it three fifteen p m",
            modelURL: modelURL
        )
        XCTAssertTrue(timeCorrection.contains("3:15"), timeCorrection)
        XCTAssertFalse(timeCorrection.contains("2:30"), timeCorrection)

        let invoice = try await process(
            "the invoice came to twenty three thousand four hundred and fifty dollars and it's due on march third twenty twenty six",
            modelURL: modelURL
        )
        XCTAssertTrue(invoice.contains("$23,450"), invoice)
        XCTAssertTrue(invoice.contains("March 3"), invoice)
        XCTAssertTrue(invoice.contains("2026"), invoice)

        let email = try await process(
            "send it to support at superwhisper dot com",
            modelURL: modelURL
        )
        XCTAssertFalse(email.isEmpty)
        await S1MiniPostProcessingService.unload()
    }

    func testShortTranscriptSizingUsesOneExactCount() throws {
        var calls = 0
        let chunks = try S1MiniTranscriptChunker.chunks("Keep 43.", maximumTokens: 20) {
            calls += 1
            return $0.count
        }
        XCTAssertEqual(chunks, [S1MiniTranscriptChunk(text: "Keep 43.", tokenCount: 8)])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try S1MiniTranscriptChunker.chunks("", maximumTokens: 20) { $0.count }, [])
    }

    private func realModelPath() -> String? {
        let temporaryGatePath = "/private/tmp/dictate-anywhere-s1-mini-q4_k_m.gguf"
        return ProcessInfo.processInfo.environment["S1_MINI_MODEL_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (FileManager.default.fileExists(atPath: temporaryGatePath) ? temporaryGatePath : nil)
    }

    private func process(_ text: String, modelURL: URL) async throws -> String {
        try await S1MiniPostProcessingService.process(
            text: text,
            modelURL: modelURL,
            styling: .semiFormal,
            structure: .prose,
            contextSetting: .general,
            context: nil
        )
    }

    private func context(category: DictationContextCategory) -> DictationPostProcessingContext {
        DictationPostProcessingContext(
            category: category,
            style: .neutral,
            cursorPlacement: .emptyField,
            continuesExistingSentence: false,
            appName: nil,
            documentURL: nil,
            documentTitle: nil,
            fieldRole: nil,
            fieldPurpose: .unknown,
            textBeforeCursor: nil,
            selectedText: nil,
            textAfterCursor: nil
        )
    }

    func testPrewarmPolicyRequiresS1MiniEnglishAndEnabled() {
        XCTAssertTrue(S1MiniPrewarmPolicy.shouldPrewarm(
            mode: .s1Mini, language: .english, prewarmEnabled: true))
    }

    func testPrewarmPolicyRejectsNonS1MiniModes() {
        for mode: TranscriptPostProcessingMode in [.none, .fluidAudioVocabulary, .appleIntelligence, .ollama, .openRouter, .openAICompatible] {
            XCTAssertFalse(S1MiniPrewarmPolicy.shouldPrewarm(
                mode: mode, language: .english, prewarmEnabled: true),
                "mode \(mode) must not prewarm")
        }
    }

    func testPrewarmPolicyRejectsNonEnglishAndDisabledToggle() {
        XCTAssertFalse(S1MiniPrewarmPolicy.shouldPrewarm(
            mode: .s1Mini, language: .german, prewarmEnabled: true))
        XCTAssertFalse(S1MiniPrewarmPolicy.shouldPrewarm(
            mode: .s1Mini, language: .english, prewarmEnabled: false))
    }
}

private nonisolated final class S1ValidationGate: @unchecked Sendable {
    private let started: XCTestExpectation
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var count = 0

    init(started: XCTestExpectation) { self.started = started }

    var callCount: Int { lock.withLock { count } }

    func validate() throws {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        if first { started.fulfill() }
        guard releaseSemaphore.wait(timeout: .now() + 5) == .success else {
            throw S1MiniModelManagerError.checksumMismatch
        }
    }

    func release() {
        releaseSemaphore.signal()
        releaseSemaphore.signal()
    }
}

extension S1MiniPostProcessingTests {
    func testLongPlanningBoundsSizingWorkAndRetainsExactAcceptedCounts() throws {
        let text = String(repeating: "Please keep invoice 42 and send the report tomorrow.\n", count: 2_600)
        var traversed = 0
        var largest = 0
        let chunks = try S1MiniTranscriptChunker.chunks(text, maximumTokens: 1_024) { candidate in
            traversed += candidate.utf8.count
            largest = max(largest, candidate.utf8.count)
            return (candidate.utf8.count + 3) / 4
        }
        XCTAssertEqual(chunks.map(\.text).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.tokenCount == ($0.text.utf8.count + 3) / 4 && $0.tokenCount <= 1_024 })
        XCTAssertLessThanOrEqual(largest, 8_192)
        XCTAssertLessThan(traversed, text.utf8.count * 20)
    }
}
