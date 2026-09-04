import XCTest
@testable import Dictate_Anywhere

/// `OverlayWindow.show` runs on every overlay update, and `AppState` drives the
/// listening waveform at roughly thirty updates a second. These tests pin the
/// wiring between that redraw loop and the display lookup: one lookup while a
/// dictation is up, and a fresh one for the next dictation — including when the
/// next one starts before the previous overlay has finished hiding.
@MainActor
final class OverlayWindowScreenSessionTests: XCTestCase {

    /// Stands in for the window server and the accessibility API.
    private final class SpyResolver: OverlayScreenResolving {
        var displayIDToResolve: CGDirectDisplayID? = 2
        private(set) var resolveCount = 0
        private(set) var requestedTargets: [pid_t?] = []

        func displays() -> [OverlayDisplay] {
            [
                OverlayDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 955)),
                OverlayDisplay(id: 2, visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1410)),
            ]
        }

        func resolveDisplayID(forApplication processIdentifier: pid_t?) -> CGDirectDisplayID? {
            resolveCount += 1
            requestedTargets.append(processIdentifier)
            return displayIDToResolve
        }
    }

    private var resolver: SpyResolver!
    private var overlay: OverlayWindow!

    override func setUp() {
        super.setUp()
        resolver = SpyResolver()
        overlay = OverlayWindow(screenResolver: resolver)
    }

    override func tearDown() {
        overlay.hide(afterDelay: 0)
        overlay = nil
        resolver = nil
        super.tearDown()
    }

    private func showListening(updates: Int) {
        for update in 0..<updates {
            overlay.show(state: .listening(level: Float(update % 10) / 10, transcript: ""))
        }
    }

    func testRepeatedListeningUpdatesResolveTheDisplayOnce() {
        showListening(updates: 30)

        XCTAssertEqual(resolver.resolveCount, 1)
    }

    /// One dictation walks through several states without hiding in between;
    /// the overlay must not re-pick its display partway through.
    func testStateChangesWithinOneSessionKeepTheSameDisplay() {
        overlay.show(state: .listening(level: 0.2, transcript: "hello"))
        overlay.show(state: .processing)
        overlay.show(state: .success)

        XCTAssertEqual(resolver.resolveCount, 1)
    }

    func testHidingTheOverlayStartsANewSession() {
        showListening(updates: 5)
        overlay.hide(afterDelay: 0)

        showListening(updates: 5)

        XCTAssertEqual(resolver.resolveCount, 2)
    }

    /// A finished dictation schedules a delayed hide and immediately goes idle.
    /// Starting another dictation inside that delay cancels the hide, so the
    /// display choice has to be reset by the new dictation rather than relying
    /// on the hide that never fired.
    func testASessionStartedBeforeTheDelayedHideFiresChoosesADisplayAgain() {
        showListening(updates: 5)
        overlay.hide(afterDelay: 5.0)
        XCTAssertEqual(resolver.resolveCount, 1)

        resolver.displayIDToResolve = 1
        showListening(updates: 5)

        XCTAssertEqual(resolver.resolveCount, 2, "the interrupted hide must not carry its display into the new dictation")
    }

    func testBeginningASessionBeforeTheDelayedHideFiresChoosesADisplayAgain() {
        showListening(updates: 5)
        overlay.hide(afterDelay: 5.0)

        overlay.beginSession(targetProcessIdentifier: 4242)
        showListening(updates: 5)

        XCTAssertEqual(resolver.resolveCount, 2)
    }

    // MARK: - Not leaving the previous dictation on screen

    /// A finished dictation leaves its badge up for a second while the app goes
    /// straight back to idle, so the next dictation routinely starts before the
    /// hide fires. Cancelling that hide without dismissing anything would leave
    /// the previous badge on the previous monitor for the whole of the next
    /// dictation's startup — longer than if the hide had simply been left alone.
    func testBeginningASessionDismissesThePreviousDictationsOverlay() {
        showListening(updates: 3)
        overlay.show(state: .success)
        overlay.hide(afterDelay: 5.0)
        XCTAssertTrue(overlay.isVisible, "precondition: the success badge is still up")

        overlay.beginSession(targetProcessIdentifier: 4242)

        XCTAssertFalse(overlay.isVisible, "the previous badge must not survive into the next dictation's startup")
    }

    /// The pending hide is what would otherwise reset the screen session, so
    /// dismissing the old overlay must not take the new target with it.
    func testDismissingThePreviousOverlayKeepsTheNewSessionsTarget() {
        showListening(updates: 3)
        overlay.hide(afterDelay: 5.0)

        overlay.beginSession(targetProcessIdentifier: 4242)
        showListening(updates: 3)

        XCTAssertEqual(resolver.requestedTargets, [nil, 4242])
    }

    // MARK: - Following the app the text will land in

    /// The insertion target is captured before audio startup; the overlay must
    /// ask about that app, not whichever app is frontmost by the time the
    /// microphone is live and the overlay finally appears.
    func testResolvesAgainstTheCapturedInsertionTarget() {
        overlay.beginSession(targetProcessIdentifier: 4242)

        showListening(updates: 5)

        XCTAssertEqual(resolver.requestedTargets, [4242])
    }

    func testFallsBackToTheFrontmostApplicationWithoutACapturedTarget() {
        showListening(updates: 5)

        XCTAssertEqual(resolver.requestedTargets, [nil])
    }

    func testEachDictationResolvesTheDisplayExactlyOnce() {
        for _ in 0..<3 {
            showListening(updates: 10)
            overlay.show(state: .processing)
            overlay.hide(afterDelay: 0)
        }

        XCTAssertEqual(resolver.resolveCount, 3)
    }
}
