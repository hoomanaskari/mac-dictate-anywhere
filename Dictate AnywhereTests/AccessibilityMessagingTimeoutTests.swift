import XCTest
@testable import Dictate_Anywhere

/// The accessibility messaging timeout is process-global: the SDK documents
/// that setting it on the system-wide element "sets the timeout globally for
/// this process", and that passing 0 "resets the global timeout to its default
/// value". A timeout left in place would silently shorten every later
/// accessibility read the app makes — `TextInserter` talks to apps that are
/// legitimately slow — and would surface there rather than anywhere near the
/// overlay. These tests pin the restore to every exit path.
final class AccessibilityMessagingTimeoutTests: XCTestCase {
    private struct LookupFailure: Error {}

    func testAppliesTheTimeoutBeforeRunningTheBody() {
        var currentTimeout: Float?
        var timeoutSeenByBody: Float?

        AccessibilityMessagingTimeout.withTimeout(0.25, apply: { currentTimeout = $0 }) {
            timeoutSeenByBody = currentTimeout
        }

        XCTAssertEqual(timeoutSeenByBody, 0.25)
    }

    func testRestoresTheProcessDefaultAfterTheBodySucceeds() {
        var applied: [Float] = []

        AccessibilityMessagingTimeout.withTimeout(0.25, apply: { applied.append($0) }) {}

        XCTAssertEqual(applied, [0.25, 0])
    }

    func testRestoresTheProcessDefaultWhenTheBodyThrows() {
        var applied: [Float] = []

        XCTAssertThrowsError(
            try AccessibilityMessagingTimeout.withTimeout(0.25, apply: { applied.append($0) }) {
                throw LookupFailure()
            }
        )

        XCTAssertEqual(applied, [0.25, 0])
    }

    /// The overlay's real failure mode is not a thrown error but an
    /// accessibility read that comes back empty, which is what happens for apps
    /// exposing no usable geometry.
    func testRestoresTheProcessDefaultWhenTheBodyFindsNothing() {
        var applied: [Float] = []

        let location = AccessibilityMessagingTimeout.withTimeout(0.25, apply: { applied.append($0) }) {
            CGPoint?.none
        }

        XCTAssertNil(location)
        XCTAssertEqual(applied, [0.25, 0])
    }

    func testReturnsTheValueTheBodyProduced() {
        let location = AccessibilityMessagingTimeout.withTimeout(0.25, apply: { _ in }) {
            CGPoint(x: 12, y: 34)
        }

        XCTAssertEqual(location, CGPoint(x: 12, y: 34))
    }
}
