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
    func insertText(
        _ text: String,
        context: DictationContext? = nil,
        style: DictationWritingStyle? = nil,
        knownTerms: [String] = [],
        pasteAutomatically: Bool = true
    ) async -> TextInsertionResult {
        let targetBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let insertionText = preparedTextForInsertion(
            text,
            targetBundleIdentifier: targetBundleIdentifier,
            context: context,
            style: style,
            knownTerms: knownTerms
        )
        guard !insertionText.isEmpty else { return .failed }

        // Copy to clipboard first (always)
        guard await copyToClipboard(insertionText) else { return .failed }
        guard pasteAutomatically else {
            resetPendingSeparator()
            return .copiedOnly
        }

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

    private func preparedTextForInsertion(
        _ text: String,
        targetBundleIdentifier: String?,
        context: DictationContext?,
        style: DictationWritingStyle?,
        knownTerms: [String]
    ) -> String {
        if let context,
           let style,
           Self.shouldUseContextualInsertion(
               context: context,
               targetBundleIdentifier: targetBundleIdentifier
           ) {
            resetPendingSeparator()
            return Self.contextualizedForInsertion(
                text,
                context: context,
                style: style,
                knownTerms: knownTerms
            )
        }

        let normalized = Self.normalizedForInsertion(text)
        guard !normalized.isEmpty else { return "" }
        let separatorPrefix = separatorPrefixIfNeeded(for: targetBundleIdentifier, insertionText: normalized)
        return separatorPrefix + normalized
    }

    /// Trims insertion-boundary whitespace without inventing punctuation.
    static func normalizedForInsertion(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldUseContextualInsertion(
        context: DictationContext,
        targetBundleIdentifier: String?
    ) -> Bool {
        context.bundleIdentifier == targetBundleIdentifier
            && (context.hasTextPositionSnapshot || context.fieldPurpose == .searchQuery)
    }

    /// Applies the retained cursor snapshot and category style without reading
    /// the destination again after the target app is reactivated.
    static func contextualizedForInsertion(
        _ text: String,
        context: DictationContext,
        style: DictationWritingStyle,
        knownTerms: [String] = []
    ) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }

        if context.fieldPurpose == .searchQuery {
            body = removingLightFinalPeriod(from: body)
            body = lowercasingLeadingOrdinaryWord(
                in: body,
                preserving: knownTerms + context.lexicalHints
            )
        } else if context.continuesExistingSentence {
            body = removingMidSentenceTerminalPunctuation(
                from: body,
                textAfterCursor: context.textAfterCursor
            )
            body = lowercasingLeadingOrdinaryWord(
                in: body,
                preserving: knownTerms + context.lexicalHints
            )
        }

        let hasFollowingText = !(context.textAfterCursor ?? "").isEmpty
        let effectiveStyle = style.sanitized(for: context.category)
        if (effectiveStyle == .casual || effectiveStyle == .veryCasual),
           !hasFollowingText,
           isShortSingleMessage(body) {
            body = removingLightFinalPeriod(from: body)
        }

        let prefix = contextualSeparator(
            left: context.textBeforeCursor,
            right: body,
            rightStartsWithAttachedPunctuation: startsWithAttachedPunctuation(body)
        )
        let suffix = contextualSeparator(
            left: body,
            right: context.textAfterCursor,
            rightStartsWithAttachedPunctuation: startsWithAttachedPunctuation(context.textAfterCursor ?? "")
        )
        return prefix + body + suffix
    }

    private static func lowercasingLeadingOrdinaryWord(
        in text: String,
        preserving knownTerms: [String]
    ) -> String {
        let allowedLeadingCharacters = CharacterSet(charactersIn: "\"'‘’“”([{「『【《")
        var wordStart: String.Index?

        for index in text.indices {
            let character = text[index]
            if character.isLetter {
                wordStart = index
                break
            }
            if character.isWhitespace
                || character.unicodeScalars.allSatisfy({ allowedLeadingCharacters.contains($0) }) {
                continue
            }
            return text
        }

        guard let wordStart else { return text }
        var wordEnd = text.index(after: wordStart)
        while wordEnd < text.endIndex {
            let character = text[wordEnd]
            guard character.isLetter || character == "'" || character == "’" || character == "-" else {
                break
            }
            wordEnd = text.index(after: wordEnd)
        }

        let word = String(text[wordStart..<wordEnd])
        guard word != "I",
              word.first?.isUppercase == true,
              !word.dropFirst().contains(where: \Character.isUppercase) else {
            return text
        }

        let normalizedWord = word.lowercased()
        let preservedLeadingWords = Set(knownTerms.compactMap { term -> String? in
            let leadingWord = term.split(whereSeparator: {
                !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-"
            }).first
            return leadingWord.map { String($0).lowercased() }
        })
        guard !preservedLeadingWords.contains(normalizedWord) else { return text }

        var result = text
        let nextIndex = result.index(after: wordStart)
        result.replaceSubrange(wordStart..<nextIndex, with: String(result[wordStart]).lowercased())
        return result
    }

    private static func removingMidSentenceTerminalPunctuation(
        from text: String,
        textAfterCursor: String?
    ) -> String {
        let closingCharacters = CharacterSet(charactersIn: "\"')]}’”」』】》")
        var removableCharacters = CharacterSet(charactersIn: ".。!?！？…")
        let followingText = (textAfterCursor ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if startsWithAttachedPunctuation(followingText) {
            removableCharacters.formUnion(CharacterSet(charactersIn: ",;:，；："))
        }

        var scalars = Array(text.unicodeScalars)
        var punctuationEnd = scalars.count
        while punctuationEnd > 0, closingCharacters.contains(scalars[punctuationEnd - 1]) {
            punctuationEnd -= 1
        }

        var punctuationStart = punctuationEnd
        while punctuationStart > 0, removableCharacters.contains(scalars[punctuationStart - 1]) {
            punctuationStart -= 1
        }
        guard punctuationStart < punctuationEnd else { return text }

        scalars.removeSubrange(punctuationStart..<punctuationEnd)
        return String(String.UnicodeScalarView(scalars))
    }

    private static func contextualSeparator(
        left: String?,
        right: String?,
        rightStartsWithAttachedPunctuation: Bool
    ) -> String {
        guard let left, let right, !left.isEmpty, !right.isEmpty,
              let leftScalar = left.unicodeScalars.last,
              let rightScalar = right.unicodeScalars.first else { return "" }
        if CharacterSet.whitespacesAndNewlines.contains(leftScalar)
            || CharacterSet.whitespacesAndNewlines.contains(rightScalar)
            || rightStartsWithAttachedPunctuation
            || "([{\"'“".unicodeScalars.contains(leftScalar)
            || CJKText.endsWithCJK(left)
            || CJKText.startsWithCJK(right) {
            return ""
        }
        return " "
    }

    private static func isShortSingleMessage(_ text: String) -> Bool {
        guard !text.contains("\n"), text.split(whereSeparator: \Character.isWhitespace).count <= 20 else {
            return false
        }
        let bodyWithoutLastScalar = String(text.unicodeScalars.dropLast())
        return !bodyWithoutLastScalar.contains(".")
            && !bodyWithoutLastScalar.contains("。")
            && !bodyWithoutLastScalar.contains("!")
            && !bodyWithoutLastScalar.contains("?")
    }

    private static func removingLightFinalPeriod(from text: String) -> String {
        let closingCharacters = CharacterSet(charactersIn: "\"')]}’”」』】》")
        var scalars = Array(text.unicodeScalars)
        var index = scalars.count - 1
        while index > 0, closingCharacters.contains(scalars[index]) {
            index -= 1
        }
        guard scalars[index] == "." || scalars[index] == "。" else { return text }
        scalars.remove(at: index)
        return String(String.UnicodeScalarView(scalars))
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

    /// Chinese text needs no space when joined to preceding text.
    static func needsSeparator(before insertionText: String) -> Bool {
        !startsWithAttachedPunctuation(insertionText) && !CJKText.startsWithCJK(insertionText)
    }

    private func shouldInsertPendingSeparator(before insertionText: String) -> Bool {
        guard Self.needsSeparator(before: insertionText),
              let precedingText = textBeforeInsertionPoint(),
              !precedingText.isEmpty else {
            return false
        }
        return !Self.isWhitespaceOrNewline(precedingText)
    }

    static func startsWithAttachedPunctuation(_ text: String) -> Bool {
        let attachedPunctuationScalarValues: Set<UInt32> = Set([
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
        ]).union(CJKText.cjkAttachedLeadingPunctuation)

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
