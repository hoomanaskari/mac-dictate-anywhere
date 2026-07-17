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

private protocol AppleSpeechSessionProtocol: AnyObject, Sendable {
    func start() async throws
    func append(samples: [Float])
    func finish() async -> String
    func cancel() async
}

final class AppleSpeechEngine: TranscriptionEngine {
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
    var currentTranscript: String {
        stateLock.withLock { transcript }
    }
    var audioSamples: [Float] {
        stateLock.withLock { levelSampleBuffer }
    }

    private let stateLock = NSLock()
    private var transcript = ""
    private var levelSampleBuffer: [Float] = []
    private var audioCaptureController: AudioCaptureController?
    private var preparedSession: (any AppleSpeechSessionProtocol)?
    private var activeSession: (any AppleSpeechSessionProtocol)?
    private var preparedLanguage: SupportedLanguage?
    private var preparedVocabulary: [String] = []
    private let levelSampleCap = 160_000

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "AppleSpeechEngine"
    )

    func levelSamples(count: Int) -> [Float] {
        stateLock.withLock {
            Array(levelSampleBuffer.suffix(max(0, count)))
        }
    }

    func prepare() async throws {
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
        do {
            try await Self.requestAuthorizationIfNeeded()
            let session = try await AppleSpeechSession(
                language: language,
                contextualVocabulary: vocabulary,
                onTranscript: { [weak self] text in
                    self?.setTranscript(text)
                }
            )
            preparedSession = session
            preparedLanguage = language
            preparedVocabulary = vocabulary
            isReady = true
            logger.info("Prepared Apple Speech for language=\(language.rawValue, privacy: .public)")
        } catch {
            preparedSession = nil
            preparedLanguage = nil
            preparedVocabulary = []
            isReady = false
            logger.error("Failed to prepare Apple Speech: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func startRecording(deviceID: AudioDeviceID?) async throws {
        guard Self.isSupported else {
            throw TranscriptionError.appleSpeechUnavailable
        }

        let language = Settings.shared.appleSpeechLanguage
        let vocabulary = appleContextualVocabulary()
        if !isReady
            || preparedSession == nil
            || preparedLanguage != language
            || preparedVocabulary != vocabulary {
            try await prepare()
        }

        guard let session = preparedSession else {
            throw TranscriptionError.engineNotReady
        }
        preparedSession = nil
        activeSession = session

        stateLock.withLock {
            transcript = ""
            levelSampleBuffer.removeAll(keepingCapacity: true)
        }

        do {
            try await session.start()
            audioCaptureController = try makeAudioCaptureController(deviceID: deviceID) { [weak self, weak session] samples in
                guard let self, let session else { return }
                self.appendLevelSamples(samples)
                session.append(samples: samples)
            }
            logger.info("Apple Speech recording started")
        } catch {
            await session.cancel()
            activeSession = nil
            logger.error("Failed to start Apple Speech recording: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func stopRecording() async -> String {
        audioCaptureController?.stop()
        audioCaptureController = nil

        guard let session = activeSession else { return currentTranscript }
        let finalTranscript = await session.finish()
        activeSession = nil
        setTranscript(finalTranscript)
        logger.info("Apple Speech recording finished with \(finalTranscript.count, privacy: .public) characters")
        return finalTranscript
    }

    func cancel() async {
        audioCaptureController?.stop()
        audioCaptureController = nil
        await activeSession?.cancel()
        activeSession = nil
        setTranscript("")
        stateLock.withLock {
            levelSampleBuffer.removeAll(keepingCapacity: false)
        }
    }

    func invalidatePreparedSession() async {
        await preparedSession?.cancel()
        preparedSession = nil
        preparedLanguage = nil
        preparedVocabulary = []
        isReady = false
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

    private func appleContextualVocabulary() -> [String] {
        guard Settings.shared.fluidAudioVocabularyEnabled else { return [] }
        return Settings.shared.customVocabulary
    }

    private func appendLevelSamples(_ samples: [Float]) {
        stateLock.withLock {
            levelSampleBuffer.append(contentsOf: samples)
            if levelSampleBuffer.count > levelSampleCap {
                levelSampleBuffer.removeFirst(levelSampleBuffer.count - levelSampleCap)
            }
        }
    }

    private func setTranscript(_ text: String) {
        stateLock.withLock {
            transcript = text
        }
    }

    fileprivate static func locale(for language: SupportedLanguage) -> Locale {
        let current = Locale.current
        if current.language.languageCode?.identifier == language.rawValue {
            return current
        }
        return Locale(identifier: language.rawValue)
    }

    @available(macOS 26.0, *)
    private static func requestAuthorizationIfNeeded() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        case let currentStatus:
            status = currentStatus
        }

        guard status == .authorized else {
            throw TranscriptionError.speechRecognitionPermissionDenied
        }
    }
}

@available(macOS 26.0, *)
private final class AppleSpeechSession: @unchecked Sendable, AppleSpeechSessionProtocol {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let onTranscript: @Sendable (String) -> Void
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let conversionLock = NSLock()
    private var analysisTask: Task<CMTime?, Error>?
    private var resultTask: Task<String, Error>?

    init(
        language: SupportedLanguage,
        contextualVocabulary: [String],
        onTranscript: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: AppleSpeechEngine.locale(for: language)
        ) else {
            throw TranscriptionError.appleSpeechLanguageUnsupported
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
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
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        self.onTranscript = onTranscript
        self.inputStream = stream
        self.inputContinuation = continuation
    }

    func start() async throws {
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
                onTranscript(finalized + volatile)
            }
            return finalized + volatile
        }

        analysisTask = Task { [analyzer, inputStream] in
            try await analyzer.analyzeSequence(inputStream)
        }
    }

    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        do {
            let sourceBuffer = try makePCMBuffer(from: samples)
            let buffer = try conversionLock.withLock {
                try convertIfNeeded(sourceBuffer)
            }
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        } catch {
            inputContinuation.finish()
        }
    }

    func finish() async -> String {
        inputContinuation.finish()
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
        inputContinuation.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        await analyzer.cancelAndFinishNow()
        analysisTask = nil
        resultTask = nil
    }

    private func convertIfNeeded(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if source.format == analyzerFormat {
            return source
        }

        guard let converter = AVAudioConverter(from: source.format, to: analyzerFormat) else {
            throw TranscriptionError.audioFormatError
        }
        let ratio = analyzerFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            throw TranscriptionError.audioFormatError
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? TranscriptionError.audioFormatError
        }
        return output
    }
}
