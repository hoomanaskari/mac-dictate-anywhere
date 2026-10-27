import AppKit
import XCTest
@testable import Dictate_Anywhere

@MainActor
final class UpdatePresentationTests: XCTestCase {
    func testScheduledNoticeUsesForegroundPathOnceAfterCallbackReturns() async {
        var events: [String] = []
        let session = UpdatePresentationSession(activateApplication: { events.append("activate") },
            presentationChanged: { events.append("appearance") })
        session.showUpdate(driverHandlesPresentation: false) { events.append("foreground update") }
        session.showUpdate(driverHandlesPresentation: false) { events.append("duplicate") }
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(events, ["appearance", "activate", "activate"])
        await drainMainQueue()
        XCTAssertEqual(events.filter { $0 == "foreground update" }.count, 1)
        XCTAssertFalse(events.contains("duplicate"))
    }

    func testUserInitiatedPresentationDoesNotRecursivelyCheckForUpdates() async {
        let session = UpdatePresentationSession(activateApplication: {}, presentationChanged: {})
        var checks = 0
        session.showUpdate(driverHandlesPresentation: true) { checks += 1 }
        await drainMainQueue()
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(checks, 0)
        session.finish()
        XCTAssertFalse(session.isActive)
    }

    func testFinishingOrReplacingSessionCancelsQueuedForegroundRequest() async {
        let session = UpdatePresentationSession(activateApplication: {}, presentationChanged: {})
        var oldChecks = 0
        var newChecks = 0
        session.showUpdate(driverHandlesPresentation: false) { oldChecks += 1 }
        session.finish()
        session.showUpdate(driverHandlesPresentation: false) { newChecks += 1 }
        await drainMainQueue()
        XCTAssertEqual(oldChecks, 0)
        XCTAssertEqual(newChecks, 1)
        session.finish()
    }

    func testDockPresenceTracksUpdateAndMainWindowVisibility() {
        XCTAssertEqual(AppDelegate.activationPolicy(preferred: .accessory, mainWindowIsVisible: false, updateIsVisible: true), .regular)
        XCTAssertEqual(AppDelegate.activationPolicy(preferred: .accessory, mainWindowIsVisible: false, updateIsVisible: false), .accessory)
        XCTAssertEqual(AppDelegate.activationPolicy(preferred: .accessory, mainWindowIsVisible: true, updateIsVisible: false), .regular)
        XCTAssertEqual(AppDelegate.activationPolicy(preferred: .regular, mainWindowIsVisible: false, updateIsVisible: false), .regular)
    }

    func testAvailabilityCueStartsOnDiscoveryAndClearsAtSessionEnd() {
        var changes = 0
        let session = UpdatePresentationSession(activateApplication: {}, presentationChanged: { changes += 1 })
        session.prepareToPresent()
        XCTAssertNil(session.availableVersion, "A manual check or modal permission prompt is not a found update")
        session.showUpdate(driverHandlesPresentation: true, availableVersion: "2.12.19") {}
        XCTAssertEqual(session.availableVersion, "2.12.19")
        XCTAssertEqual(changes, 2)
        session.finish()
        XCTAssertNil(session.availableVersion)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(changes, 3)
    }

    func testIndicatorReusesDecorationAndPreservesTemplateIconAndButtonInteraction() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        button.image = image
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: appearance)
            UpdateAvailabilityIndicator.apply(version: "2.12.19", to: button, updateItem: item)
            let dot = try XCTUnwrap(button.subviews.first { $0 is UpdateAvailabilityIndicator })
            XCTAssertFalse(dot.isHidden)
            XCTAssertEqual(dot.frame.maxX, button.bounds.maxX - 1)
            if button.isFlipped {
                XCTAssertEqual(dot.frame.minY, button.bounds.minY + 1, "The dot belongs at the top, including in AppKit's flipped button coordinates")
            } else {
                XCTAssertEqual(dot.frame.maxY, button.bounds.maxY - 1)
            }
            XCTAssertNil(dot.hitTest(NSPoint(x: 3, y: 3)))
            XCTAssertEqual(item.title, "Update available…")
            XCTAssertTrue(button.image === image)
            XCTAssertTrue(button.toolTip?.contains("2.12.19") == true)
        }
        XCTAssertEqual(button.subviews.filter { $0 is UpdateAvailabilityIndicator }.count, 1)
        UpdateAvailabilityIndicator.apply(version: nil, to: button, updateItem: item)
        XCTAssertTrue(button.subviews.first { $0 is UpdateAvailabilityIndicator }?.isHidden == true)
        XCTAssertEqual(item.title, "Check for Updates…")
        XCTAssertEqual(button.toolTip, "Dictate Anywhere")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
