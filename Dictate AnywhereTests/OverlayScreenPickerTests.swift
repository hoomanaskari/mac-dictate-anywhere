import XCTest
@testable import Dictate_Anywhere

/// Tests for the display-selection math behind the dictation overlay.
///
/// The layout is a two-display desktop: the primary 1920x1080 display at the
/// origin, and a secondary 1440x900 display placed to its left, which gives the
/// secondary a negative x origin exactly like a real left-hand monitor.
final class OverlayScreenPickerTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let leftSecondary = CGRect(x: -1440, y: 0, width: 1440, height: 900)

    private var screens: [CGRect] { [primary, leftSecondary] }

    private var pointOnPrimary: CGPoint { CGPoint(x: 960, y: 540) }
    private var pointOnSecondary: CGPoint { CGPoint(x: -720, y: 450) }

    // MARK: - A layout measured in the field

    /// The desktop this bug was actually reproduced on: a 1512x982 built-in
    /// display as primary, with a 2560x1440 ultrawide to its right whose
    /// greater height puts its origin below the primary's. The accessibility
    /// point is the real focused-window position VS Code reported while a text
    /// box on the ultrawide had focus.
    func testChoosesTheUltrawideForAWindowMeasuredOnIt() {
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let ultrawide = CGRect(x: 1512, y: -458, width: 2560, height: 1440)

        let focusPoint = OverlayScreenPicker.appKitPoint(
            fromAccessibilityPoint: CGPoint(x: 1512, y: 30),
            primaryFrame: builtIn
        )

        XCTAssertEqual(focusPoint, CGPoint(x: 1512, y: 952))
        XCTAssertEqual(
            OverlayScreenPicker.pickScreenIndex(
                screenFrames: [builtIn, ultrawide],
                focusPoint: focusPoint,
                mouseLocation: CGPoint(x: 466, y: 475)
            ),
            1,
            "the overlay must follow the focused window, not the pointer on the built-in display"
        )
    }

    // MARK: - Screen selection

    func testPicksScreenContainingFocusedTextField() {
        let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens,
            focusPoint: pointOnSecondary,
            mouseLocation: nil
        )

        XCTAssertEqual(index, 1)
    }

    func testPrefersFocusedTextFieldOverMousePointer() {
        let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens,
            focusPoint: pointOnSecondary,
            mouseLocation: pointOnPrimary
        )

        XCTAssertEqual(index, 1)
    }

    func testFallsBackToMousePointerWhenFocusIsUnavailable() {
        let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens,
            focusPoint: nil,
            mouseLocation: pointOnSecondary
        )

        XCTAssertEqual(index, 1)
    }

    func testFallsBackToMousePointerWhenFocusIsOffAllDisplays() {
        let offscreen = CGPoint(x: 10_000, y: 10_000)

        let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens,
            focusPoint: offscreen,
            mouseLocation: pointOnSecondary
        )

        XCTAssertEqual(index, 1)
    }

    func testFallsBackToPrimaryWhenNoPointMatchesADisplay() {
        let offscreen = CGPoint(x: 10_000, y: 10_000)

        let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens,
            focusPoint: offscreen,
            mouseLocation: offscreen
        )

        XCTAssertEqual(index, 0)
    }

    func testReturnsNilWhenThereAreNoDisplays() {
        let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: [],
            focusPoint: pointOnPrimary,
            mouseLocation: pointOnPrimary
        )

        XCTAssertNil(index)
    }

    // MARK: - Accessibility coordinate conversion

    func testAccessibilityPointFlipsIntoAppKitCoordinates() {
        // AX measures down from the top-left of the primary display; AppKit
        // measures up from its bottom-left.
        let converted = OverlayScreenPicker.appKitPoint(
            fromAccessibilityPoint: CGPoint(x: 300, y: 80),
            primaryFrame: primary
        )

        XCTAssertEqual(converted.x, 300)
        XCTAssertEqual(converted.y, 1000)
    }

    func testAccessibilityPointAboveThePrimaryDisplayConvertsToPositiveY() {
        // A display stacked above the primary reports negative AX y values.
        let converted = OverlayScreenPicker.appKitPoint(
            fromAccessibilityPoint: CGPoint(x: 100, y: -600),
            primaryFrame: primary
        )

        XCTAssertEqual(converted.y, 1680)
    }

    // MARK: - Overlay placement

    func testOverlayOriginIsBottomCenteredOnTheChosenDisplay() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1920, height: 1030)

        let origin = OverlayScreenPicker.overlayOrigin(
            inVisibleFrame: visibleFrame,
            size: CGSize(width: 208, height: 130),
            bottomMargin: 16
        )

        XCTAssertEqual(origin.x, 856)
        XCTAssertEqual(origin.y, 41)
    }

    func testOverlayOriginStaysOnADisplayWithANegativeOrigin() {
        let visibleFrame = CGRect(x: -1440, y: 0, width: 1440, height: 875)

        let origin = OverlayScreenPicker.overlayOrigin(
            inVisibleFrame: visibleFrame,
            size: CGSize(width: 208, height: 130),
            bottomMargin: 16
        )

        XCTAssertEqual(origin.x, -824)
        XCTAssertEqual(origin.y, 16)
        XCTAssertTrue(visibleFrame.contains(CGPoint(x: origin.x, y: origin.y)))
    }
}
