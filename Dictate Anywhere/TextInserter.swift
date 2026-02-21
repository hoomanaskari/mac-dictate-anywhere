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
    // MARK: - Public

    /// Inserts text into the currently focused input field
    func insertText(_ text: String) async -> TextInsertionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        // Copy to clipboard first (always)
        guard await copyToClipboard(trimmed) else { return .failed }

        // Check accessibility permission
        guard hasAccessibilityPermission(promptIfNeeded: true) else { return .copiedOnly }

        // Small delay for clipboard to settle
        try? await Task.sleep(for: .milliseconds(80))

        // AppleScript is more reliable than synthetic HID key events for many apps.
        if await simulatePasteWithAppleScript() {
            return .success
        }

        // Fallback: CGEvent paste
        if simulatePasteWithCGEvent() {
            try? await Task.sleep(for: .milliseconds(100))
            return .success
        }

        return .copiedOnly
    }

    // MARK: - Private

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
