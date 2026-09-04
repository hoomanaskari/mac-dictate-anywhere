import XCTest
@testable import Dictate_Anywhere

@MainActor
final class PermissionLifecycleTests: XCTestCase {
    func testGrantedFirstPermissionDoesNotStartRecordingAfterHoldRelease() async {
        let permissionRequested = expectation(description: "microphone permission requested")
        let permissionResponse = SuspendedPermissionResponse {
            permissionRequested.fulfill()
        }
        let appState = AppState(microphonePermissionRequester: {
            await permissionResponse.waitForResolution()
        })
        let binding = HotkeyBinding(
            id: UUID(),
            keyCode: nil,
            modifiersRawValue: HotkeyModifiers([.function]).rawValue,
            displayName: "fn",
            mode: .holdToRecord
        )

        appState.hotkeyService.onKeyDown?(binding)
        await fulfillment(of: [permissionRequested], timeout: 1)
        XCTAssertTrue(appState.isHoldToRecordKeyDown)

        appState.hotkeyService.onKeyUp?(binding)
        for _ in 0..<100 where appState.isHoldToRecordKeyDown {
            await Task.yield()
        }
        XCTAssertFalse(appState.isHoldToRecordKeyDown)
        await permissionResponse.resolve(granted: true)
        await Task.yield()

        XCTAssertTrue(appState.permissions.micGranted)
        XCTAssertEqual(appState.status, .idle)
    }
}

private actor SuspendedPermissionResponse {
    private let onRequest: @Sendable () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?

    init(onRequest: @escaping @Sendable () -> Void) {
        self.onRequest = onRequest
    }

    func waitForResolution() async -> Bool {
        onRequest()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}
