import Observation
import SwiftUI
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class OverlayContentTests: XCTestCase {
    func testPreviewPreservesEmptyAndCharacterLimitBoundaries() {
        let limit = OverlayPreviewText.maximumCharacters
        for length in [0, 1, limit - 1, limit, limit + 1] {
            let transcript = String(repeating: "a", count: length)
            let expected = length > limit ? "…" + String(repeating: "a", count: limit) : transcript
            XCTAssertEqual(OverlayPreviewText.trimmed(transcript), expected, "length=\(length)")
        }
    }

    func testPreviewKeepsCompleteUnicodeCharacters() {
        for pattern in ["Café déjà vu. ", "这是听写文本。", "👩🏽‍💻 👨‍👩‍👧‍👦 🇳🇱 e\u{301} "] {
            let transcript = String(repeating: pattern, count: 100)
            let expected = "…" + String(transcript.suffix(OverlayPreviewText.maximumCharacters))
            XCTAssertEqual(OverlayPreviewText.trimmed(transcript), expected)
        }
    }

    func testEveryReadingSizeBoundsLongUnicodePreviews() {
        let transcript = String(repeating: "👩🏽‍💻 这是听写文本 Café e\u{301} ", count: 1_000)
        for size in OverlaySize.allCases {
            let text = OverlayPreviewText.trimmed(transcript, maximumCharacters: size.characterLimit)
            XCTAssertEqual(text, "…" + String(transcript.suffix(size.characterLimit)))
        }
    }

    func testLevelOnlyUpdatesDoNotInvalidateTranscriptContent() {
        let model = OverlayModel()
        let transcript = String(repeating: "Long dictation preview. ", count: 1_000)
        model.updateListening(level: 0, transcript: transcript)
        let content = OverlayTranscriptContent(model: model, size: .comfortable, textColor: .white)
        let changes = observe { _ = content.body }

        for update in 0..<600 {
            model.updateListening(level: Float(update % 10) / 10, transcript: transcript)
        }

        XCTAssertEqual(changes.count, 0, "waveform updates must not invalidate the preview body")
        print("OVERLAY_OBSERVATION level_updates=600 transcript_invalidations=\(changes.count)")
        model.updateListening(level: 0.5, transcript: "A new transcript")
        XCTAssertEqual(changes.count, 1, "the preview must still observe transcript changes")
    }

    func testDisabledPreviewDoesNotObserveTranscript() {
        let model = OverlayModel()
        let content = ListeningOverlayContent(model: model, showTextPreview: false, textColor: .white)
        let changes = observe { _ = content.body }

        model.updateListening(level: 0.5, transcript: "Text that will not be displayed")

        XCTAssertEqual(changes.count, 0)
    }

    func testPreviewObservesCorrectionsClearingAndResumedText() {
        let model = OverlayModel()
        model.updateListening(level: 0.4, transcript: "first")
        let content = OverlayTranscriptContent(model: model, size: .comfortable, textColor: .white)
        for transcript in ["other", "", "resumed"] {
            let changes = observe { _ = content.body }
            model.updateListening(level: 0.4, transcript: transcript)
            XCTAssertEqual(changes.count, 1, "transcript=\(transcript)")
            XCTAssertEqual(model.transcript, transcript)
        }
    }

    func testWaveformObservesLevelWithoutTranscript() {
        let model = OverlayModel()
        model.updateListening(level: 0.4, transcript: "first")
        let waveform = OverlayWaveformContent(model: model)
        let changes = observe { _ = waveform.body }

        model.updateListening(level: 0.4, transcript: "corrected")
        XCTAssertEqual(changes.count, 0)
        model.updateListening(level: 0.6, transcript: "corrected")
        XCTAssertEqual(changes.count, 1)
    }

    func testListeningDataDoesNotInvalidatePillPresentation() {
        let model = OverlayModel()
        let changes = observe {
            _ = model.overlayState
            _ = model.isVisible
            _ = model.cancellationProgress
        }
        model.updateListening(level: 0.6, transcript: "hello")
        XCTAssertEqual(changes.count, 0)
        model.updateState(.processing)
        XCTAssertEqual(changes.count, 1)
    }

    func testStatusStatesReleaseListeningDataAndAllowANewSession() {
        let model = OverlayModel()
        let states: [OverlayState] = [.processing, .success, .copiedOnly, .preparingModel(name: "Speech")]
        for state in states {
            model.updateListening(level: 0.8, transcript: "Previous dictation")
            model.updateState(state)
            XCTAssertEqual(model.overlayState, state)
            XCTAssertEqual(model.audioLevel, 0)
            XCTAssertEqual(model.transcript, "")
        }
        model.updateListening(level: 0.2, transcript: "New session")
        model.updateState(.listening)
        XCTAssertEqual(model.overlayState, .listening)
        XCTAssertEqual(model.audioLevel, 0.2)
        XCTAssertEqual(model.transcript, "New session")
    }

    private func observe(_ read: () -> Void) -> OverlayObservationChanges {
        let changes = OverlayObservationChanges()
        withObservationTracking(read, onChange: { changes.record() })
        return changes
    }
}

nonisolated private final class OverlayObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
