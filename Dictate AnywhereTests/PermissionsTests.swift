import XCTest
@testable import Dictate_Anywhere

final class PermissionsTests: XCTestCase {
    @MainActor
    func testRefreshUpdatesMicrophonePermissionAfterReturningFromSettings() async {
        let status = MutablePermissionStatus(microphoneGranted: false)
        let permissions = Permissions(statusProvider: {
            (mic: status.microphoneGranted, accessibility: false)
        })

        await permissions.refresh()
        XCTAssertFalse(permissions.micGranted)

        // Simulate enabling Microphone in System Settings before returning to
        // the app, which triggers its active-state permission refresh.
        status.microphoneGranted = true
        await permissions.refresh()

        XCTAssertTrue(permissions.micGranted)
    }
}

private final class MutablePermissionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var microphoneValue: Bool

    init(microphoneGranted: Bool) {
        microphoneValue = microphoneGranted
    }

    var microphoneGranted: Bool {
        get { lock.withLock { microphoneValue } }
        set { lock.withLock { microphoneValue = newValue } }
    }
}
