import XCTest
@testable import Dictate_Anywhere

final class S1MiniPostProcessingTests: XCTestCase {
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
}
