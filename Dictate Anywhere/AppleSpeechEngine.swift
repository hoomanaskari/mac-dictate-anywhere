//
//  AppleSpeechEngine.swift
//  Dictate Anywhere
//
//  On-device SpeechAnalyzer / SpeechTranscriber engine for macOS 26 and later.
//

import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Speech
import os

protocol AppleSpeechSessionProtocol: AnyObject, Sendable {
    func start() async throws
    func append(samples: [Float])
    func finish() async -> String
    func cancel() async
    func updateContextualVocabulary(_ terms: [String]) async throws
}

final class AppleSpeechEngine: TranscriptionEngine {
    typealias SessionFactory = @MainActor @Sendable (
        SupportedLanguage, [String]
    ) async throws -> any AppleSpeechSessionProtocol

    private let sessionFactory: SessionFactory?

    init(sessionFactory: SessionFactory? = nil) {
        self.sessionFactory = sessionFactory
    }

    static var isOperatingSystemSupported: Bool {
        #if DEBUG
        if let simulatedOperatingSystemMajorVersion {
            return simulatedOperatingSystemMajorVersion >= 26
        }
        #endif

        guard #available(macOS 26.0, *) else { return false }
        return true
    }

    static var operatingSystemDisplayName: String {
        #if DEBUG
        if let simulatedOperatingSystemMajorVersion {
            return "macOS \(simulatedOperatingSystemMajorVersion)"
        }
        #endif

        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)"
    }

    static var isSupported: Bool {
        guard isOperatingSystemSupported else { return false }
        guard #available(macOS 26.0, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    #if DEBUG
    private static var simulatedOperatingSystemMajorVersion: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "--simulate-macos-major-version"),
           arguments.indices.contains(flagIndex + 1),
           let value = Int(arguments[flagIndex + 1]) {
            return value
        }
        let value = ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_SIMULATED_MACOS_MAJOR_VERSION"]
        return value.flatMap(Int.init)
    }
    #endif

    private(set) var isReady = false
    var requiresContextBeforeFinalization: Bool { true }
    var currentTranscript: String {
        stateLock.withLock { transcript }
    }
    var audioSamples: [Float] {
        stateLock.withLock { levelSampleBuffer.samples }
    }

    private let stateLock = NSLock()
    private var transcript = ""
    /// One-shot guard for the `stt.firstPartial` trace event. Guarded by
    /// `stateLock` because live transcript callbacks arrive off the main actor.
    private var firstPartialEmitted = false
    private var levelSampleBuffer = AudioLevelSampleBuffer()
    private var audioCaptureController: AudioCaptureController?
    var recoveryCapture: RecoveryAudioCapture?
    private var preparedSession: (any AppleSpeechSessionProtocol)?
    private var preparationTask: Task<Void, Error>?
    private var preparationIdentity: (language: SupportedLanguage, vocabulary: [String])?
    private var preparationGeneration = UUID()
    private var activeSession: (any AppleSpeechSessionProtocol)?
    private var preparedLanguage: SupportedLanguage?
    private var preparedVocabulary: [String] = []
    private var sessionContextualVocabulary: [String] = []
    private let audioCaptureStartupTimeout: TimeInterval = 5
    private let audioCaptureSetupQueue = DispatchQueue(
        label: "com.dictate-anywhere.apple-speech-audio-startup",
        qos: .userInitiated
    )
    private var audioCaptureStartupCancellation: AudioCaptureStartupCancellation?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppleSpeechEngine"
    )

    func levelSamples(count: Int) -> [Float] {
        stateLock.withLock {
            levelSampleBuffer.latest(count: count)
        }
    }

    func setSessionContextualVocabulary(_ terms: [String]) {
        sessionContextualVocabulary = terms
    }

    func updateSessionContextualVocabulary(_ terms: [String]) async {
        sessionContextualVocabulary = terms
        do {
            try await activeSession?.updateContextualVocabulary(appleContextualVocabulary())
        } catch {
            logger.notice("Could not update live contextual vocabulary: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prepare() async throws {
        let trace = PerfTrace.begin("stt.enginePrepare")
        defer { trace.end() }
        guard Self.isSupported else {
            isReady = false
            throw TranscriptionError.appleSpeechUnavailable
        }
        guard #available(macOS 26.0, *) else {
            isReady = false
            throw TranscriptionError.appleSpeechUnavailable
        }

        let language = Settings.shared.appleSpeechLanguage
        let vocabulary = appleContextualVocabulary()
        if preparedSession != nil, preparedLanguage == language, preparedVocabulary == vocabulary {
            isReady = true
            return
        }
        if let preparationTask,
           preparationIdentity?.language == language,
           preparationIdentity?.vocabulary == vocabulary {
            try await preparationTask.value
            return
        }

        let invalidatedGeneration = await invalidatePreparedSession()
        guard preparationGeneration == invalidatedGeneration,
              Settings.shared.appleSpeechLanguage == language,
              appleContextualVocabulary() == vocabulary else {
            throw CancellationError()
        }
        let generation = UUID()
        preparationGeneration = generation
        preparationIdentity = (language, vocabulary)
        let factory = sessionFactory
        let task = Task { @MainActor [weak self] in
            let session: any AppleSpeechSessionProtocol
            if let factory {
                session = try await factory(language, vocabulary)
            } else {
                session = try await AppleSpeechSession(
                    requestedLocale: Self.locale(for: language),
                    contextualVocabulary: vocabulary,
                    onTranscript: { [weak self] text, isPartial in
                        self?.setTranscript(text)
                        if isPartial { self?.markFirstPartialIfNeeded(text: text) }
                    }
                )
            }
            guard let self, self.preparationGeneration == generation, !Task.isCancelled else {
                await session.cancel()
                throw CancellationError()
            }
            self.preparedSession = session
            self.preparedLanguage = language
            self.preparedVocabulary = vocabulary
            self.isReady = true
            self.logger.info("Prepared Apple Speech for language=\(language.rawValue, privacy: .public)")
        }
        preparationTask = task
        do {
            try await task.value
            if preparationGeneration == generation {
                preparationTask = nil
                preparationIdentity = nil
            }
        } catch {
            if preparationGeneration == generation {
                preparationTask = nil
                preparationIdentity = nil
                preparedSession = nil
                preparedLanguage = nil
                preparedVocabulary = []
                isReady = false
            }
            logger.error("Failed to prepare Apple Speech: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func startRecording(deviceID: AudioDeviceID?) async throws {
        let trace = PerfTrace.begin("audio.startup")
        defer { trace.end() }
        guard Self.isSupported else {
            throw TranscriptionError.appleSpeechUnavailable
        }

        // Cancellation must cover preparation as well as the microphone
        // factory, including the fresh session needed after a previous stop.
        audioCaptureStartupCancellation?.cancel()
        let startupCancellation = AudioCaptureStartupCancellation()
        audioCaptureStartupCancellation = startupCancellation
        let recoveryCapture = self.recoveryCapture

        let language = Settings.shared.appleSpeechLanguage
        let vocabulary = appleContextualVocabulary()
        if !isReady
            || preparedSession == nil
            || preparedLanguage != language
            || preparedVocabulary != vocabulary {
            try await prepare()
        }

        guard audioCaptureStartupCancellation === startupCancellation else { throw CancellationError() }
        guard let session = preparedSession else {
            throw TranscriptionError.engineNotReady
        }
        preparedSession = nil
        activeSession = session

        stateLock.withLock {
            transcript = ""
            firstPartialEmitted = false
            levelSampleBuffer.reset(keepingCapacity: true)
        }
        let usesExplicitMicrophoneSelection = Settings.shared.selectedMicrophoneUID != nil

        do {
            try await PerfTrace.measure("stt.appleSpeechSessionStart") {
                try await session.start()
            }
            // Context may have arrived while the recognizer was preparing.
            if preparedVocabulary != appleContextualVocabulary() {
                await updateSessionContextualVocabulary(sessionContextualVocabulary)
            }
            let controller = try await startAudioCaptureOffMainActor(
                timeout: audioCaptureStartupTimeout,
                queue: audioCaptureSetupQueue,
                cancellation: startupCancellation
            ) { [self, session] in
                try makeAudioCaptureController(
                    deviceID: deviceID,
                    usesExplicitMicrophoneSelection: usesExplicitMicrophoneSelection
                ) { [weak self, weak session] samples in
                    recoveryCapture?.append(samples)
                    guard let self, let session else { return }
                    self.appendLevelSamples(samples)
                    session.append(samples: samples)
                }
            }
            guard audioCaptureStartupCancellation === startupCancellation,
                  activeSession === session else {
                controller.stop()
                throw CancellationError()
            }
            audioCaptureStartupCancellation = nil
            audioCaptureController = controller
            logger.info("Apple Speech recording started")
        } catch {
            if audioCaptureStartupCancellation === startupCancellation {
                audioCaptureStartupCancellation = nil
            }
            await session.cancel()
            if activeSession === session {
                activeSession = nil
            }
            logger.error("Failed to start Apple Speech recording: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    #if DEBUG
    func installAudioCaptureControllerForTesting(_ controller: AudioCaptureController) {
        audioCaptureController = controller
    }
    #endif

    func stopAudioCapture() {
        stopAudioCapture(outcome: "completed")
    }

    private func stopAudioCapture(outcome: StaticString) {
        guard let captureController = audioCaptureController else { return }
        audioCaptureController = nil
        let trace = PerfTrace.begin("audio.teardown")
        captureController.stop()
        trace.end(outcome: outcome)
    }

    func stopRecording() async -> String {
        let trace = PerfTrace.begin("stt.stopToFinal")
        defer { trace.end() }
        stopAudioCapture()

        guard let session = activeSession else { return currentTranscript }
        let finalTranscript = await PerfTrace.measure("stt.finalize") {
            await session.finish()
        }
        activeSession = nil
        setTranscript(finalTranscript)
        logger.info("Apple Speech recording finished with \(finalTranscript.count, privacy: .public) characters")
        return finalTranscript
    }

    func cancel() async {
        audioCaptureStartupCancellation?.cancel()
        audioCaptureStartupCancellation = nil
        stopAudioCapture(outcome: "cancelled")
        await activeSession?.cancel()
        activeSession = nil
        setTranscript("")
        stateLock.withLock {
            firstPartialEmitted = false
            levelSampleBuffer.reset(keepingCapacity: false)
        }
    }

    func transcribeRecording(at url: URL) async throws -> String {
        let trace = PerfTrace.begin("stt.transcribe")
        defer { trace.end() }
        guard #available(macOS 26.0, *), Self.isSupported else { throw TranscriptionError.appleSpeechUnavailable }
        let session = try await AppleSpeechSession(
            requestedLocale: Self.locale(for: Settings.shared.appleSpeechLanguage),
            contextualVocabulary: appleContextualVocabulary(), onTranscript: { _, _ in }
        )
        return try await session.transcribeFile(at: url)
    }

    @discardableResult
    func invalidatePreparedSession() async -> UUID {
        let generation = UUID()
        preparationGeneration = generation
        let preparation = preparationTask
        preparationTask = nil
        preparationIdentity = nil
        let session = preparedSession
        preparedSession = nil
        preparedLanguage = nil
        preparedVocabulary = []
        isReady = false
        preparation?.cancel()
        _ = try? await preparation?.value
        await session?.cancel()
        return generation
    }

    static func supportedLanguages() async -> [SupportedLanguage] {
        guard Self.isSupported else { return [] }
        guard #available(macOS 26.0, *) else { return [] }

        var result: [SupportedLanguage] = []
        for language in SupportedLanguage.allCases {
            if await SpeechTranscriber.supportedLocale(equivalentTo: locale(for: language)) != nil {
                result.append(language)
            }
        }
        return result
    }

    /// Languages whose on-device Speech assets are already installed —
    /// distinct from `supportedLanguages()`, which only reports what the
    /// framework *could* support. Auto-switching must never trigger a
    /// silent asset download, so callers use this to gate mappings that
    /// would otherwise call through to `prepare()`.
    static func installedLanguages() async -> [SupportedLanguage] {
        guard Self.isSupported else { return [] }
        guard #available(macOS 26.0, *) else { return [] }

        let installedLocales = await SpeechTranscriber.installedLocales
        let installedIdentifiers = Set(installedLocales.map { $0.identifier(.bcp47) })

        var result: [SupportedLanguage] = []
        for language in SupportedLanguage.allCases {
            guard let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale(for: language)) else {
                continue
            }
            if installedIdentifiers.contains(canonical.identifier(.bcp47)) {
                result.append(language)
            }
        }
        return result
    }

    private func appleContextualVocabulary() -> [String] {
        var terms = sessionContextualVocabulary
        if Settings.shared.fluidAudioVocabularyEnabled {
            terms.append(contentsOf: Settings.shared.customVocabulary)
        }

        var seen: Set<String> = []
        return terms.filter {
            let normalized = $0.lowercased()
            return !$0.isEmpty && seen.insert(normalized).inserted
        }
    }

    private func appendLevelSamples(_ samples: [Float]) {
        stateLock.withLock {
            levelSampleBuffer.append(samples)
        }
    }

    private func setTranscript(_ text: String) {
        stateLock.withLock {
            transcript = text
        }
    }

    /// Emits the one-shot `stt.firstPartial` event for live transcript text.
    /// Only live callbacks emit: a final-only result (stop path) leaves the
    /// event absent, which itself reports that no live partial appeared.
    private func markFirstPartialIfNeeded(text: String) {
        let shouldEmit = stateLock.withLock { () -> Bool in
            guard !firstPartialEmitted,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            firstPartialEmitted = true
            return true
        }
        if shouldEmit {
            PerfTrace.event("stt.firstPartial")
        }
    }

    static func locale(for language: SupportedLanguage) -> Locale {
        locale(forLanguageCode: language.rawValue)
    }

    static func locale(forLanguageCode languageCode: String) -> Locale {
        // SpeechTranscriber distinguishes zh-CN/zh-TW/zh-HK; our single
        // Chinese case is Simplified, so pin the region explicitly.
        if languageCode == "zh" { return Locale(identifier: "zh-CN") }
        if languageCode == "yue" { return Locale(identifier: "yue-HK") }
        let current = Locale.current
        if current.language.languageCode?.identifier == languageCode {
            return current
        }
        return Locale(identifier: languageCode)
    }

    static func makeInstalledLivePreviewSession(
        languageCode: String,
        contextualVocabulary: [String],
        onTranscript: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> (any AppleSpeechSessionProtocol)? {
        guard #available(macOS 26.0, *), Self.isSupported else { return nil }
        let requestedLocale = locale(forLanguageCode: languageCode)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else { return nil }

        let installedIdentifiers = Set(
            await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        )
        guard installedIdentifiers.contains(supportedLocale.identifier(.bcp47)) else { return nil }

        return try await AppleSpeechSession(
            requestedLocale: supportedLocale,
            contextualVocabulary: contextualVocabulary,
            allowsAssetInstallation: false,
            onTranscript: onTranscript
        )
    }
}

@available(macOS 26.0, *)
final class AppleSpeechSession: @unchecked Sendable, AppleSpeechSessionProtocol {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let inputConverter: PCMStreamConverter
    private let onTranscript: @Sendable (String, Bool) -> Void
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let conversionLock = NSLock()
    private var inputClosed = false
    private var inputBufferCount = 0
    private var convertedBufferCount = 0
    private var inputSampleCount = 0
    private var rejectedInputBufferCount = 0
    private var analysisTask: Task<CMTime?, Error>?
    private var resultTask: Task<String, Error>?

    init(
        requestedLocale: Locale,
        contextualVocabulary: [String],
        allowsAssetInstallation: Bool = true,
        onTranscript: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw TranscriptionError.appleSpeechLanguageUnsupported
        }

        // Apple's preset supplies volatile previews plus authoritative final
        // results. Keep its decoder/compute policy under framework control.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard allowsAssetInstallation else {
                throw TranscriptionError.appleSpeechLanguageUnsupported
            }
            try await PerfTrace.measure("stt.appleSpeechAssetInstall") {
                try await installationRequest.downloadAndInstall()
            }
        }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
              let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: sourceFormat
              ) else {
            throw TranscriptionError.audioFormatError
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualVocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualVocabulary
            try await analyzer.setContext(context)
        }
        try await PerfTrace.measure("stt.appleSpeechAnalyzerPrepare") {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.inputConverter = try PCMStreamConverter(from: sourceFormat, to: analyzerFormat)
        self.onTranscript = onTranscript
        self.inputStream = stream
        self.inputContinuation = continuation
    }

    func start() async throws {
        startResults()
        analysisTask = Task { [analyzer, inputStream] in
            try await analyzer.analyzeSequence(inputStream)
        }
    }

    func updateContextualVocabulary(_ terms: [String]) async throws {
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        try await analyzer.setContext(context)
    }

    private func startResults() {
        resultTask = Task { [transcriber, onTranscript] in
            var finalized = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    volatile = ""
                } else {
                    volatile = text
                }
                onTranscript(
                    finalized + volatile,
                    !result.isFinal && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            return finalized + volatile
        }

    }

    func transcribeFile(at url: URL) async throws -> String {
        let reader = try ConvertedRecoveryAudioReader(url: url, outputFormat: analyzerFormat)
        // Pull audio only when the analyzer requests the next chunk. The live
        // microphone's push stream would otherwise buffer the entire file.
        let stream = AsyncThrowingStream<AnalyzerInput, Error>(unfolding: {
            try Task.checkCancellation()
            guard let buffer = try reader.nextBuffer() else { return nil }
            return AnalyzerInput(buffer: buffer)
        })
        startResults()
        do {
            if let lastSample = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await resultTask?.value ?? ""
            resultTask = nil
            try Task.checkCancellation()
            return text
        } catch {
            await cancel()
            throw error
        }
    }

    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        conversionLock.withLock {
            guard !inputClosed else { return }
            inputBufferCount += 1
            inputSampleCount += samples.count
            do {
                let source = try makePCMBuffer(from: samples)
                if source.format != analyzerFormat { convertedBufferCount += 1 }
                enqueue(try inputConverter.convert(source))
            } catch {
                rejectedInputBufferCount += 1
                inputClosed = true
                inputContinuation.finish()
            }
        }
    }

    func finish() async -> String {
        closeInput(flushTail: true)
        let counts = conversionLock.withLock {
            ["input_buffers": inputBufferCount, "converted_buffers": convertedBufferCount,
             "rejected_input_buffers": rejectedInputBufferCount, "input_samples": inputSampleCount]
        }
        PerfTrace.event("stt.appleSpeechInputSummary", counts: counts)
        do {
            let lastSample = try await analysisTask?.value
            if let lastSample {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let finalText = try await resultTask?.value ?? ""
            analysisTask = nil
            resultTask = nil
            return finalText
        } catch {
            await analyzer.cancelAndFinishNow()
            analysisTask = nil
            resultTask?.cancel()
            resultTask = nil
            return ""
        }
    }

    func cancel() async {
        closeInput(flushTail: false)
        analysisTask?.cancel()
        resultTask?.cancel()
        await analyzer.cancelAndFinishNow()
        analysisTask = nil
        resultTask = nil
    }

    // Both helpers run under conversionLock, keeping final tail delivery after
    // the last append and before stream termination, including concurrent Stop.
    private func enqueue(_ buffers: [AVAudioPCMBuffer]) {
        for buffer in buffers {
            if case .enqueued = inputContinuation.yield(AnalyzerInput(buffer: buffer)) {} else {
                rejectedInputBufferCount += 1
            }
        }
    }

    private func closeInput(flushTail: Bool) {
        conversionLock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            if flushTail {
                do { enqueue(try inputConverter.finish()) }
                catch { rejectedInputBufferCount += 1 }
            }
            inputContinuation.finish()
        }
    }
}
