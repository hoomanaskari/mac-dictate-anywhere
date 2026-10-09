import XCTest
@testable import Dictate_Anywhere

#if DEBUG
@MainActor
final class AppleSpeechPreparationLifecycleTests: XCTestCase {
    func testOlderInvalidationCannotCancelNewerPreparedSession() async throws {
        try XCTSkipUnless(AppleSpeechEngine.isSupported, "Apple Speech preparation requires macOS 26 or later")
        let gate = AppleSpeechPreparationGate()
        let staleSession = AppleSpeechPreparationSession()
        let currentSession = AppleSpeechPreparationSession()
        let factory = AppleSpeechPreparationFactory(
            gate: gate, staleSession: staleSession, currentSession: currentSession
        )
        let engine = AppleSpeechEngine(sessionFactory: { language, vocabulary in
            try await factory.makeSession(language: language, vocabulary: vocabulary)
        })

        let stalePreparation = Task { try await engine.prepare() }
        await gate.waitUntilFactoryStarts()
        let oldInvalidation = Task { await engine.invalidatePreparedSession() }
        await gate.waitUntilFactoryIsCancelled()
        let currentPreparation = Task { try await engine.prepare() }
        try await currentPreparation.value
        XCTAssertTrue(engine.isReady)
        XCTAssertEqual(currentSession.cancelCount, 0)

        gate.release()
        _ = await oldInvalidation.value
        do {
            try await stalePreparation.value
            XCTFail("Invalidated preparation must not become ready")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected preparation error: \(error)")
        }

        XCTAssertTrue(engine.isReady, "An older invalidation must leave the newer session ready")
        XCTAssertEqual(staleSession.cancelCount, 1)
        XCTAssertEqual(currentSession.cancelCount, 0)
    }
}

@MainActor
private final class AppleSpeechPreparationSession: AppleSpeechSessionProtocol {
    private(set) var cancelCount = 0

    func start() async throws {}
    func append(samples: [Float]) {}
    func finish() async -> String { "" }
    func cancel() async { cancelCount += 1 }
    func updateContextualVocabulary(_ terms: [String]) async throws {}
}

@MainActor
private final class AppleSpeechPreparationGate {
    private var started = false
    private var cancelled = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<AppleSpeechPreparationSession, Error>?

    func makeSession(_ session: AppleSpeechPreparationSession) async throws -> AppleSpeechPreparationSession {
        started = true
        pendingSession = session
        startWaiter?.resume()
        startWaiter = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { resultWaiter = $0 }
        } onCancel: {
            Task { @MainActor in self.markCancelled() }
        }
    }

    func waitUntilFactoryStarts() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitUntilFactoryIsCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancelWaiter = $0 }
    }

    private func markCancelled() {
        cancelled = true
        cancelWaiter?.resume()
        cancelWaiter = nil
    }

    func release() {
        guard let resultWaiter, let pendingSession else { return }
        self.resultWaiter = nil
        self.pendingSession = nil
        resultWaiter.resume(returning: pendingSession)
    }

    private var pendingSession: AppleSpeechPreparationSession?
}

@MainActor
private final class AppleSpeechPreparationFactory {
    private let gate: AppleSpeechPreparationGate
    private let staleSession: AppleSpeechPreparationSession
    private let currentSession: AppleSpeechPreparationSession
    private var callCount = 0

    init(
        gate: AppleSpeechPreparationGate,
        staleSession: AppleSpeechPreparationSession,
        currentSession: AppleSpeechPreparationSession
    ) {
        self.gate = gate
        self.staleSession = staleSession
        self.currentSession = currentSession
    }

    func makeSession(
        language: SupportedLanguage,
        vocabulary: [String]
    ) async throws -> any AppleSpeechSessionProtocol {
        callCount += 1
        if callCount == 1 { return try await gate.makeSession(staleSession) }
        return currentSession
    }
}
#endif
