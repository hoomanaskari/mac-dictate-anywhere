import XCTest
@testable import Dictate_Anywhere

/// Choosing the overlay's display is expensive: it crosses a process boundary
/// to ask the target application where it is. The overlay repositions on every
/// update, so that choice is made once per dictation and reused — but it has to
/// be reused safely, which means surviving display reconfiguration and never
/// outliving the dictation it belongs to.
final class OverlayScreenSessionTests: XCTestCase {
    private let builtIn = OverlayDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 955))
    private let middle = OverlayDisplay(id: 2, visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1410))
    private let right = OverlayDisplay(id: 3, visibleFrame: CGRect(x: 4072, y: 0, width: 1920, height: 1055))

    /// Stands in for the window server and the accessibility API.
    private final class SpyResolver: OverlayScreenResolving {
        var displayList: [OverlayDisplay]
        var displayIDToResolve: CGDirectDisplayID?
        private(set) var resolveCount = 0
        private(set) var requestedTargets: [pid_t?] = []

        init(displayList: [OverlayDisplay], displayIDToResolve: CGDirectDisplayID?) {
            self.displayList = displayList
            self.displayIDToResolve = displayIDToResolve
        }

        func displays() -> [OverlayDisplay] {
            displayList
        }

        func resolveDisplayID(forApplication processIdentifier: pid_t?) -> CGDirectDisplayID? {
            resolveCount += 1
            requestedTargets.append(processIdentifier)
            return displayIDToResolve
        }
    }

    private func makeResolver(
        displays: [OverlayDisplay]? = nil,
        resolving displayID: CGDirectDisplayID? = 2
    ) -> SpyResolver {
        SpyResolver(displayList: displays ?? [builtIn, middle, right], displayIDToResolve: displayID)
    }

    // MARK: - One lookup per session

    /// The listening waveform updates about thirty times a second, and none of
    /// those updates may pay for a fresh cross-process lookup.
    func testResolvesTheDisplayOnceAcrossRepeatedUpdates() {
        let resolver = makeResolver()
        let session = OverlayScreenSession(resolver: resolver)

        for _ in 0..<30 {
            _ = session.visibleFrame()
        }

        XCTAssertEqual(resolver.resolveCount, 1)
    }

    func testReturnsTheVisibleFrameOfTheChosenDisplay() {
        let session = OverlayScreenSession(resolver: makeResolver(resolving: middle.id))

        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)
    }

    /// Re-choosing mid-dictation would let the overlay hop displays in the
    /// middle of a sentence just because the pointer wandered.
    func testKeepsTheFirstDisplayEvenWhenTheResolverWouldNowChooseAnother() {
        let resolver = makeResolver(resolving: middle.id)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)

        resolver.displayIDToResolve = builtIn.id

        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)
        XCTAssertEqual(resolver.resolveCount, 1)
    }

    func testRereadsDisplayGeometryOnEveryUpdate() {
        let resolver = makeResolver(resolving: middle.id)
        let session = OverlayScreenSession(resolver: resolver)

        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)

        let grown = OverlayDisplay(id: middle.id, visibleFrame: CGRect(x: 1512, y: -458, width: 2560, height: 1440))
        resolver.displayList = [builtIn, grown, right]

        XCTAssertEqual(session.visibleFrame(), grown.visibleFrame)
    }

    // MARK: - Session boundaries

    func testEndingTheSessionChoosesADisplayAgain() {
        let resolver = makeResolver(resolving: middle.id)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)

        session.end()
        resolver.displayIDToResolve = builtIn.id

        XCTAssertEqual(session.visibleFrame(), builtIn.visibleFrame)
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    /// A new dictation must never inherit the previous dictation's display,
    /// even when it begins before the previous overlay has finished hiding.
    func testBeginningASessionChoosesADisplayAgain() {
        let resolver = makeResolver(resolving: middle.id)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)

        session.begin(targetProcessIdentifier: nil)
        resolver.displayIDToResolve = right.id

        XCTAssertEqual(session.visibleFrame(), right.visibleFrame)
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    // MARK: - Following the app the text will land in

    func testAsksAboutTheSessionsTargetApplication() {
        let resolver = makeResolver()
        let session = OverlayScreenSession(resolver: resolver)

        session.begin(targetProcessIdentifier: 4242)
        _ = session.visibleFrame()

        XCTAssertEqual(resolver.requestedTargets, [4242])
    }

    /// The target is captured before audio startup and the transcript is pasted
    /// into it afterwards, so the overlay must follow that app even if the user
    /// brings a different one forward while the microphone is starting.
    func testKeepsTheCapturedTargetAcrossAFrontmostAppChange() {
        let resolver = makeResolver()
        let session = OverlayScreenSession(resolver: resolver)
        session.begin(targetProcessIdentifier: 4242)

        _ = session.visibleFrame()
        session.end()
        session.begin(targetProcessIdentifier: 4242)
        _ = session.visibleFrame()

        XCTAssertEqual(resolver.requestedTargets, [4242, 4242])
    }

    func testAsksAboutTheFrontmostApplicationWhenNoTargetWasCaptured() {
        let resolver = makeResolver()
        let session = OverlayScreenSession(resolver: resolver)

        _ = session.visibleFrame()

        XCTAssertEqual(resolver.requestedTargets, [nil])
    }

    // MARK: - Displays changing underneath a live session

    /// Identity has to be the physical display, not its position in the list.
    /// Removing a display ahead of the chosen one shifts every later index, so
    /// an index-based cache would silently point at a different monitor.
    func testKeepsTheSamePhysicalDisplayWhenAnEarlierDisplayIsUnplugged() {
        let resolver = makeResolver(resolving: right.id)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), right.visibleFrame)

        resolver.displayList = [builtIn, right]
        resolver.displayIDToResolve = builtIn.id

        XCTAssertEqual(session.visibleFrame(), right.visibleFrame, "the overlay must stay on the display it chose")
        XCTAssertEqual(resolver.resolveCount, 1, "a surviving display needs no fresh lookup")
    }

    /// The reordering has to move the chosen display to a different position,
    /// or an index-based cache would keep passing by coincidence.
    func testKeepsTheSamePhysicalDisplayWhenTheDisplayOrderChanges() {
        let resolver = makeResolver(resolving: middle.id)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)

        // `middle` moves from index 1 to index 0; index 1 now holds `builtIn`.
        resolver.displayList = [middle, builtIn, right]

        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)
        XCTAssertEqual(resolver.resolveCount, 1)
    }

    /// The chosen display going away mid-dictation is the one case that does
    /// need a fresh lookup, or the overlay would be stranded off-screen.
    func testChoosesAgainWhenTheChosenDisplayIsUnplugged() {
        let resolver = makeResolver(resolving: middle.id)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)

        resolver.displayList = [builtIn, right]
        resolver.displayIDToResolve = right.id

        XCTAssertEqual(session.visibleFrame(), right.visibleFrame)
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    // MARK: - Nothing to place the overlay on

    func testReturnsNilWhenThereAreNoDisplays() {
        let session = OverlayScreenSession(resolver: makeResolver(displays: [], resolving: 1))

        XCTAssertNil(session.visibleFrame())
    }

    func testReturnsNilWhenNoDisplayCanBeChosen() {
        let session = OverlayScreenSession(resolver: makeResolver(resolving: nil))

        XCTAssertNil(session.visibleFrame())
    }

    func testReturnsNilWhenTheChosenDisplayIsNotAttached() {
        let session = OverlayScreenSession(resolver: makeResolver(resolving: 99))

        XCTAssertNil(session.visibleFrame())
    }

    /// A failed choice must not be cached as if it were a decision, or the
    /// overlay would stay unplaced for the rest of the dictation.
    func testRetriesAfterAFailedChoice() {
        let resolver = makeResolver(resolving: nil)
        let session = OverlayScreenSession(resolver: resolver)
        XCTAssertNil(session.visibleFrame())

        resolver.displayIDToResolve = middle.id

        XCTAssertEqual(session.visibleFrame(), middle.visibleFrame)
    }
}
