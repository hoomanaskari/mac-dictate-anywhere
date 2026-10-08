//
//  OverlayScreenResolver.swift
//  Dictate Anywhere
//
//  Supplies the display geometry the dictation overlay places itself against.
//

import AppKit

/// Source of the display information the overlay needs.
///
/// Split out of `OverlayWindow` so the once-per-session lookup can be tested
/// without attaching monitors or granting accessibility permission.
protocol OverlayScreenResolving {
    /// The attached displays, primary first, with visible frames in AppKit
    /// global coordinates. Cheap enough to read on every overlay update.
    func displays() -> [OverlayDisplay]

    /// Expensive: this is the call that crosses a process boundary to ask an
    /// application where it is, so callers resolve once per dictation.
    ///
    /// - Parameter processIdentifier: the app the transcript will be pasted
    ///   into, or nil to follow whichever app is frontmost.
    func resolveDisplayID(forApplication processIdentifier: pid_t?) -> CGDirectDisplayID?
}

/// Resolves the overlay's display from the real window server.
struct SystemOverlayScreenResolver: OverlayScreenResolving {
    /// The overlay has to appear the instant the hotkey fires, so an
    /// unresponsive app must never block the main thread for long.
    private static let messagingTimeout: Float = 0.25

    func displays() -> [OverlayDisplay] {
        NSScreen.screens.map {
            OverlayDisplay(id: $0.displayID, visibleFrame: $0.visibleFrame)
        }
    }

    func resolveDisplayID(forApplication processIdentifier: pid_t?) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        if screens.count == 1 {
            return screens[0].displayID
        }

        guard let index = OverlayScreenPicker.pickScreenIndex(
            screenFrames: screens.map(\.frame),
            focusPoint: focusedLocation(forApplication: processIdentifier),
            mouseLocation: NSEvent.mouseLocation
        ) else {
            return nil
        }

        return screens[index].displayID
    }

    // MARK: - Focus lookup

    /// Global location of whatever is receiving keystrokes, so the overlay
    /// lands on the display being dictated into. Nil when accessibility is
    /// unavailable or the focused app reports no usable geometry.
    ///
    /// Everything here is asked of one specific application. The system-wide
    /// element's `kAXFocusedUIElement` looks like the obvious way to do this
    /// and is not usable: it has been observed returning a stale element
    /// belonging to a different process entirely — Terminal's text area while
    /// Firefox was frontmost, on the opposite display — which would put the
    /// overlay on a screen the dictated text is not going to.
    private func focusedLocation(forApplication processIdentifier: pid_t?) -> CGPoint? {
        guard let primaryFrame = NSScreen.screens.first?.frame,
              let targetPid = processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }

        // The timeout has to be set on the system-wide element; that is what
        // makes it apply to this process's messages, including the ones below.
        let systemWide = AXUIElementCreateSystemWide()
        let application = AXUIElementCreateApplication(targetPid)

        let axPoint = AccessibilityMessagingTimeout.withTimeout(
            Self.messagingTimeout,
            apply: { _ = AXUIElementSetMessagingTimeout(systemWide, $0) }
        ) { () -> CGPoint? in
            focusedElementPosition(in: application) ?? focusedWindowPosition(in: application)
        }

        guard let axPoint else { return nil }

        return OverlayScreenPicker.appKitPoint(fromAccessibilityPoint: axPoint, primaryFrame: primaryFrame)
    }

    /// Position of the control receiving keystrokes, for apps that expose one.
    private func focusedElementPosition(in application: AXUIElement) -> CGPoint? {
        guard let element = copyElement(kAXFocusedUIElementAttribute, from: application) else { return nil }
        return position(of: element) ?? containingWindowPosition(of: element)
    }

    /// Position of the application's focused window.
    ///
    /// Chromium- and Gecko-based apps — VS Code, Slack, Firefox, Electron apps
    /// generally — keep their accessibility tree switched off until they detect
    /// a screen reader, so `kAXFocusedUIElement` answers `kAXErrorNoValue` for
    /// them however it is asked. Their windows are ordinary windows and stay
    /// visible to accessibility, and a window is enough to choose a display.
    private func focusedWindowPosition(in application: AXUIElement) -> CGPoint? {
        guard let window = copyElement(kAXFocusedWindowAttribute, from: application) else { return nil }
        return position(of: window)
    }

    private func copyElement(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            let positionValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = positionValue as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Some apps expose no position on the focused element itself; its window
    /// is a good enough stand-in for picking a display.
    private func containingWindowPosition(of element: AXUIElement) -> CGPoint? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return position(of: windowValue as! AXUIElement)
    }
}

private extension NSScreen {
    /// The display's `CGDirectDisplayID`, which stays with the physical display
    /// across reconfiguration.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
