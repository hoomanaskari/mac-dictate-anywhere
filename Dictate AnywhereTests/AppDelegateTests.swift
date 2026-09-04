import XCTest
import AppKit
@testable import Dictate_Anywhere

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationDidBecomeActiveRefreshesPermissionState() async {
        let status = MutableAppDelegatePermissionStatus(microphoneGranted: false)
        let permissions = Permissions(statusProvider: {
            (mic: status.microphoneGranted, accessibility: false)
        })
        await permissions.refresh()
        XCTAssertFalse(permissions.micGranted)

        let appState = AppState(permissions: permissions)
        let appDelegate = AppDelegate(appState: appState)
        status.microphoneGranted = true

        appDelegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        for _ in 0..<100 where !appState.permissions.micGranted {
            await Task.yield()
        }

        XCTAssertTrue(appState.permissions.micGranted)
    }
}

private final class MutableAppDelegatePermissionStatus: @unchecked Sendable {
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
