//
//  TextInserter.swift
//  Dictate Anywhere
//
//  Clipboard + paste (CGEvent Cmd+V) for inserting text into focused inputs.
//

import Foundation
import AppKit
import CoreGraphics

enum TextInsertionResult {
    case success
    case copiedOnly
    case failed
}

final class TextInserter {
    private var pendingSeparator = ""
    private var pendingSeparatorTargetBundleIdentifier: String?

    // MARK: - Public

    /// Inserts text into the currently focused input field
    func insertText(_ text: String) async -> TextInsertionResult {
        let targetBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let insertionText = preparedTextForInsertion(text, targetBundleIdentifier: targetBundleIdentifier)
        guard !insertionText.isEmpty else { return .failed }

        // Copy to clipboard first (always)
        guard await copyToClipboard(insertionText) else { return .failed }

        // Check accessibility permission
        guard hasAccessibilityPermission(promptIfNeeded: true) else {
            resetPendingSeparator()
            return .copiedOnly
        }

        // Small delay for clipboard to settle
        try? await Task.sleep(for: .milliseconds(80))

        // AppleScript is more reliable than synthetic HID key events for many apps.
        if await simulatePasteWithAppleScript() {
            prepareForNextInsertion(targetBundleIdentifier: targetBundleIdentifier)
            return .success
        }

        // Fallback: CGEvent paste
        if simulatePasteWithCGEvent() {
            try? await Task.sleep(for: .milliseconds(100))
            prepareForNextInsertion(targetBundleIdentifier: targetBundleIdentifier)
            return .success
        }

        resetPendingSeparator()
        return .copiedOnly
    }

    // MARK: - Private

    private func preparedTextForInsertion(_ text: String, targetBundleIdentifier: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let normalized = Self.hasTerminalPunctuation(trimmed) ? trimmed : trimmed + "."
        let separatorPrefix = separatorPrefixIfNeeded(for: targetBundleIdentifier, insertionText: normalized)
        return separatorPrefix + normalized
    }

    private func separatorPrefixIfNeeded(for targetBundleIdentifier: String?, insertionText: String) -> String {
        guard !pendingSeparator.isEmpty else { return "" }

        guard let targetBundleIdentifier,
              pendingSeparatorTargetBundleIdentifier == targetBundleIdentifier else {
            resetPendingSeparator()
            return ""
        }

        guard shouldInsertPendingSeparator(before: insertionText) else { return "" }

        return pendingSeparator
    }

    private func prepareForNextInsertion(targetBundleIdentifier: String?) {
        guard let targetBundleIdentifier else {
            resetPendingSeparator()
            return
        }

        pendingSeparator = " "
        pendingSeparatorTargetBundleIdentifier = targetBundleIdentifier
    }

    private func resetPendingSeparator() {
        pendingSeparator = ""
        pendingSeparatorTargetBundleIdentifier = nil
    }

    private func shouldInsertPendingSeparator(before insertionText: String) -> Bool {
        guard !Self.startsWithAttachedPunctuation(insertionText),
              let precedingText = textBeforeInsertionPoint(),
              !precedingText.isEmpty else {
            return false
        }

        return !Self.isWhitespaceOrNewline(precedingText)
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        let closingScalarValues: Set<UInt32> = [
            34, // "
            39, // '
            41, // )
            93, // ]
            125, // }
            0x2019,
            0x201D,
        ]
        let punctuationScalarValues: Set<UInt32> = [
            33, // !
            44, // ,
            46, // .
            58, // :
            59, // ;
            63, // ?
            0x2026,
        ]

        for scalar in text.unicodeScalars.reversed() {
            if closingScalarValues.contains(scalar.value) {
                continue
            }
            return punctuationScalarValues.contains(scalar.value)
        }

        return false
    }

    private static func startsWithAttachedPunctuation(_ text: String) -> Bool {
        let attachedPunctuationScalarValues: Set<UInt32> = [
            33, // !
            41, // )
            44, // ,
            46, // .
            58, // :
            59, // ;
            63, // ?
            93, // ]
            125, // }
            0x2026,
        ]

        guard let firstScalar = text.unicodeScalars.first else { return false }
        return attachedPunctuationScalarValues.contains(firstScalar.value)
    }

    private static func isWhitespaceOrNewline(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private func textBeforeInsertionPoint() -> String? {
        guard hasAccessibilityPermission(promptIfNeeded: false),
              let focusedElement = focusedAccessibilityElement(),
              let selectedRange = selectedTextRange(in: focusedElement) else {
            return nil
        }

        guard selectedRange.location != kCFNotFound else { return nil }
        guard selectedRange.location > 0 else { return "" }

        if let text = stringForRange(
            in: focusedElement,
            location: selectedRange.location - 1,
            length: 1
        ) {
            return text
        }

        return valueCharacterBeforeLocation(selectedRange.location, in: focusedElement)
    }

    private func focusedAccessibilityElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard error == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedElement as! AXUIElement)
    }

    private func selectedTextRange(in element: AXUIElement) -> CFRange? {
        var selectedRangeValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard error == .success,
              let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = selectedRangeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func stringForRange(in element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )
        guard error == .success else { return nil }
        return value as? String
    }

    private func valueCharacterBeforeLocation(_ location: Int, in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard error == .success, let text = value as? String else { return nil }

        let nsText = text as NSString
        guard location > 0, location <= nsText.length else { return nil }
        return nsText.substring(with: NSRange(location: location - 1, length: 1))
    }

    private func copyToClipboard(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general

        for _ in 0..<3 {
            pasteboard.clearContents()

            let didSet = pasteboard.setString(text, forType: .string)
            let readBack = pasteboard.string(forType: .string)
            if didSet, readBack == text {
                return true
            }

            try? await Task.sleep(for: .milliseconds(25))
        }

        return false
    }

    private func hasAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        guard promptIfNeeded else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func simulatePasteWithCGEvent() -> Bool {
        let vKeyCode: CGKeyCode = 9
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    private func simulatePasteWithAppleScript() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = """
                tell application "System Events"
                    keystroke "v" using command down
                end tell
                """
                var error: NSDictionary?
                if let scriptObject = NSAppleScript(source: script) {
                    scriptObject.executeAndReturnError(&error)
                    continuation.resume(returning: error == nil)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
