//
//  TextInserter.swift
//  Dictate Anywhere
//
//  Clipboard + paste (CGEvent Cmd+V) for inserting text into focused inputs.
//

import Foundation
import AppKit
import CoreGraphics
import os

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
        targetProcessIdentifier: pid_t? = nil,
        pasteAutomatically: Bool = true,
        modelInsertionPlan: ModelInsertionPlan? = nil,
        preserveModelFormatting: Bool = false
    ) async -> TextInsertionResult {
        let trace = PerfTrace.begin("insertion.deliver")
        var deliverOutcome: StaticString = "failed"
        defer { trace.end(outcome: deliverOutcome) }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let targetApplication = targetProcessIdentifier.flatMap {
            NSRunningApplication(processIdentifier: $0)
        } ?? frontmostApplication
        let resolvedTargetProcessIdentifier = targetApplication?.processIdentifier
        let targetBundleIdentifier = targetApplication?.bundleIdentifier
        let insertionText = PerfTrace.measure("insertion.prepare") {
            preparedTextForInsertion(
                text,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessIdentifier: resolvedTargetProcessIdentifier,
                context: context,
                style: style,
                knownTerms: knownTerms,
                modelInsertionPlan: modelInsertionPlan,
                preserveModelFormatting: preserveModelFormatting
            )
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere", category: "TextInsertion")
        logger.info("insertionFormatting: model=\(preserveModelFormatting) explicitSpacing=\(modelInsertionPlan != nil) inputUpper=\(text.first(where: \.isLetter)?.isUppercase == true) outputUpper=\(insertionText.first(where: \.isLetter)?.isUppercase == true) leadingSpace=\(insertionText.hasPrefix(" ")) trailingSpace=\(insertionText.hasSuffix(" "))")
        guard !insertionText.isEmpty else { return .failed }

        // Copy to clipboard first (always)
        guard await copyToClipboard(insertionText) else { return .failed }
        guard pasteAutomatically else {
            resetPendingSeparator()
            deliverOutcome = "copiedOnly"
            return .copiedOnly
        }

        // Check accessibility permission
        guard hasAccessibilityPermission(promptIfNeeded: true) else {
            resetPendingSeparator()
            deliverOutcome = "copiedOnly"
            return .copiedOnly
        }

        // Small delay for clipboard to settle
        try? await Task.sleep(for: .milliseconds(80))

        // Plain-text numbering needs one verified replacement, not a second
        // blind edit after pasting. If the snapshot is stale, leave the text on
        // the clipboard rather than replacing someone else's changes.
        var listEdit: (AXUIElement, PlainTextListEdit)?
        if let context, context.processIdentifier == resolvedTargetProcessIdentifier,
           PlainTextListEdit.needsRenumbering(insertion: insertionText, context: context) {
            let listEditTrace = PerfTrace.begin("insertion.listEdit")
            defer { listEditTrace.end() }
            guard let pid = resolvedTargetProcessIdentifier,
                  let element = Self.focusedTextElement(processIdentifier: pid),
                  Self.processIdentifier(of: element) == resolvedTargetProcessIdentifier,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == resolvedTargetProcessIdentifier,
                  let range = selectedTextRange(in: element),
                  let value = Self.textValue(of: element), (value as NSString).length <= 100_000,
                  Self.snapshotMatches(value: value, range: range, context: context) else {
                logger.info("plainListEdit: live snapshot unavailable or changed")
                resetPendingSeparator()
                deliverOutcome = "copiedOnly"
                return .copiedOnly
            }
            if let edit = PlainTextListEdit.prepare(value: value,
                selection: NSRange(location: range.location, length: range.length),
                insertion: insertionText, context: context) {
                guard await copyToClipboard(edit.replacement) else { return .failed }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == resolvedTargetProcessIdentifier,
                      Self.textValue(of: element) == value,
                      selectedTextRange(in: element).map({ $0.location == range.location && $0.length == range.length }) == true else {
                    _ = await copyToClipboard(insertionText)
                    deliverOutcome = "copiedOnly"
                    return .copiedOnly
                }
                let didSelect = Self.setSelection(edit.range, in: element)
                if didSelect {
                    for _ in 0..<10 {
                        if selectedTextRange(in: element).map({ $0.location == edit.range.location && $0.length == edit.range.length }) == true { break }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                guard didSelect,
                      selectedTextRange(in: element).map({ $0.location == edit.range.location && $0.length == edit.range.length }) == true,
                      Self.textValue(of: element) == value,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == resolvedTargetProcessIdentifier else {
                    logger.info("plainListEdit: selection verification failed, set=\(didSelect)")
                    _ = Self.setSelection(NSRange(location: range.location, length: range.length), in: element)
                    _ = await copyToClipboard(insertionText)
                    deliverOutcome = "copiedOnly"
                    return .copiedOnly
                }
                listEdit = (element, edit)
            }
        }

        // AppleScript is more reliable than synthetic HID key events for many apps.
        if await simulatePasteWithAppleScript() {
            await finishListEdit(listEdit, insertionText: insertionText)
            prepareForNextInsertion(targetBundleIdentifier: targetBundleIdentifier)
            deliverOutcome = "success"
            return .success
        }

        // Fallback: CGEvent paste
        if simulatePasteWithCGEvent() {
            try? await Task.sleep(for: .milliseconds(100))
            await finishListEdit(listEdit, insertionText: insertionText)
            prepareForNextInsertion(targetBundleIdentifier: targetBundleIdentifier)
            deliverOutcome = "success"
            return .success
        }

        if let (element, edit) = listEdit {
            _ = Self.setSelection(NSRange(location: edit.range.location, length: 0), in: element)
            _ = await copyToClipboard(insertionText)
        }
        resetPendingSeparator()
        deliverOutcome = "copiedOnly"
        return .copiedOnly
    }

    private func finishListEdit(_ pending: (AXUIElement, PlainTextListEdit)?, insertionText: String) async {
        guard let (element, edit) = pending else { return }
        let trace = PerfTrace.begin("insertion.listEditVerify")
        defer { trace.end() }
        for _ in 0..<10 {
            if Self.textValue(of: element) == edit.expectedValue {
                // Leave the cursor after the new items, not after old neighbors.
                if let range = selectedTextRange(in: element), range.length == 0,
                   range.location == edit.range.location + (edit.replacement as NSString).length {
                    _ = Self.setSelection(NSRange(location: edit.caretLocation, length: 0), in: element)
                }
                if NSPasteboard.general.string(forType: .string) == edit.replacement {
                    _ = await copyToClipboard(insertionText)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // A slow editor may still have a paste queued. Keep its replacement on
        // the clipboard until observed; changing it now could drop old text.
    }

    private static func focusedTextElement(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        return DictationContextCapture.focusedTextElement(in: application, processIdentifier: processIdentifier)
    }

    private static func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private static func textValue(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func snapshotMatches(value: String, range: CFRange, context: DictationContext) -> Bool {
        let value = value as NSString
        guard range.length == 0, range.location >= 0, range.location <= value.length,
              let before = context.textBeforeCursor, let after = context.textAfterCursor,
              context.selectedText?.isEmpty != false else { return false }
        return value.substring(to: range.location).hasSuffix(before)
            && value.substring(from: range.location).hasPrefix(after)
    }

    // MARK: - Private

    func preparedTextForInsertion(
        _ text: String,
        targetBundleIdentifier: String?,
        targetProcessIdentifier: pid_t?,
        context: DictationContext?,
        style: DictationWritingStyle?,
        knownTerms: [String],
        modelInsertionPlan: ModelInsertionPlan? = nil,
        preserveModelFormatting: Bool = false
    ) -> String {
        if let plan = modelInsertionPlan,
           Self.normalizedForInsertion(plan.text) == Self.normalizedForInsertion(text) {
            resetPendingSeparator()
            if let context,
               context.processIdentifier == targetProcessIdentifier,
               !context.isSecureField, !context.isContextExcluded,
               context.listItemInsertion != nil || Self.hasInlineCommaBoundary(context)
                || (!plan.text.contains(where: \.isNewline) && Self.standaloneLineConvention(context) != nil) {
                // The provider can return standalone punctuation/spacing even
                // with explicit instructions. Confirmed list or comma boundaries
                // supply the local formatting contract for every provider path.
                return Self.contextualizedForInsertion(
                    plan.text, context: context, style: .original, knownTerms: knownTerms
                )
            }
            return plan.insertionText
        }
        if let context,
           let style,
           Self.shouldUseContextualInsertion(
               context: context,
               targetProcessIdentifier: targetProcessIdentifier
           ) {
            resetPendingSeparator()
            return Self.contextualizedForInsertion(
                text,
                context: context,
                style: style,
                knownTerms: knownTerms,
                preserveModelFormatting: preserveModelFormatting && !Self.hasInlineCommaBoundary(context)
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

    static func hasInlineCommaBoundary(_ context: DictationContext) -> Bool {
        guard !context.isSecureField, !context.isContextExcluded,
              context.listItemInsertion == nil,
              let before = context.textBeforeCursor, let after = context.textAfterCursor,
              let last = before.lastIndex(where: { !$0.isWhitespace }),
              before[last] == "," || before[last] == "，",
              !before[before.index(after: last)...].contains(where: \.isNewline) else { return false }
        let leadingWhitespace = after.prefix(while: \.isWhitespace)
        return !leadingWhitespace.contains(where: \.isNewline)
    }

    /// A single insertion between consecutive nonempty lines can match their
    /// case/punctuation without declaring the field a list or splitting prose.
    private static func standaloneLineConvention(_ context: DictationContext) -> DictationListInsertion? {
        guard !context.isSecureField, !context.isContextExcluded,
              context.fieldPurpose != .searchQuery, context.selectedText?.isEmpty != false,
              let before = context.textBeforeCursor, let after = context.textAfterCursor,
              before.last?.isNewline == true, after.first?.isNewline == true else { return nil }
        let previous = String(before.dropLast()).components(separatedBy: .newlines).last ?? ""
        let next = String(after.dropFirst()).components(separatedBy: .newlines).first ?? ""
        let neighbors = [previous, next].map { $0.trimmingCharacters(in: .whitespaces) }
        guard neighbors.allSatisfy({ !$0.isEmpty }) else { return nil }
        return DictationListInsertion.matchingNeighbors(neighbors, needsSpaceAfterMarker: false)
    }

    static func shouldUseContextualInsertion(
        context: DictationContext,
        targetProcessIdentifier: pid_t?
    ) -> Bool {
        context.processIdentifier == targetProcessIdentifier
            && (context.hasTextPositionSnapshot || context.listItemInsertion != nil || context.fieldPurpose == .searchQuery)
    }

    /// Applies the retained cursor snapshot and category style without reading
    /// the destination again after the target app is reactivated.
    static func contextualizedForInsertion(
        _ text: String,
        context: DictationContext,
        style: DictationWritingStyle,
        knownTerms: [String] = [],
        preserveModelFormatting: Bool = false
    ) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        let listInsertion = context.fieldPurpose == .searchQuery ? nil
            : context.listItemInsertion ?? (body.contains(where: \.isNewline) ? nil : standaloneLineConvention(context))

        if let list = listInsertion {
            // The model chooses semantic item boundaries. Apply the same local
            // convention to each item, never split arbitrary commas or "and".
            body = body.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated().map { index, item in
                    var item = item
                    if list.omitsFinalPeriod {
                        item = removingListFragmentPeriod(from: item, preserving: knownTerms)
                    } else if let period = list.requiredFinalPeriod {
                        item = addingListPeriodIfNeeded(to: item, period: period)
                    }
                    switch list.capitalization {
                    case .uppercase:
                        item = capitalizingLeadingOrdinaryWord(in: item, preserving: knownTerms)
                    case .lowercase:
                        item = lowercasingLeadingOrdinaryWord(in: item, preserving: knownTerms + context.lexicalHints)
                    case nil:
                        break
                    }
                    return (index == 0 ? "" : list.continuationPrefix(itemOffset: index)) + item
                }.joined(separator: "\n")
        } else if preserveModelFormatting {
            // Preserve model choices when there is no confirmed list convention.
        } else if context.fieldPurpose == .searchQuery {
            body = removingLightFinalPeriod(from: body)
            body = lowercasingLeadingOrdinaryWord(
                in: body,
                preserving: knownTerms + context.lexicalHints
            )
        } else if context.continuesExistingSentence || hasInlineCommaBoundary(context) {
            if hasInlineCommaBoundary(context), body.contains(where: \.isNewline) {
                let delimiter = context.textBeforeCursor?.last(where: { !$0.isWhitespace }) == "，" ? "，" : ", "
                body = body.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { item in
                        lowercasingLeadingOrdinaryWord(
                            in: removingMidSentenceTerminalPunctuation(from: item, textAfterCursor: ","),
                            preserving: knownTerms + context.lexicalHints
                        )
                    }.joined(separator: delimiter)
            }
            body = removingMidSentenceTerminalPunctuation(
                from: body,
                textAfterCursor: context.textAfterCursor
            )
            body = lowercasingLeadingOrdinaryWord(
                in: body,
                preserving: knownTerms + context.lexicalHints
            )
            body = addingParallelListDelimiterIfNeeded(
                to: body,
                textBeforeCursor: context.textBeforeCursor,
                textAfterCursor: context.textAfterCursor
            )
        }

        let hasFollowingText = !(context.textAfterCursor ?? "").isEmpty
        let effectiveStyle = style.sanitized(for: context.category)
        if (effectiveStyle == .casual || effectiveStyle == .veryCasual),
           !preserveModelFormatting,
           listInsertion == nil,
           !hasFollowingText,
           isShortSingleMessage(body) {
            body = removingLightFinalPeriod(from: body)
        }

        let prefix = listInsertion.map { $0.needsSpaceAfterMarker ? " " : "" } ?? contextualSeparator(
            left: context.textBeforeCursor,
            right: body,
            rightStartsWithAttachedPunctuation: startsWithAttachedPunctuation(body)
        )
        let suffix = listInsertion?.isEmptyStructuralItem == true ? "" : contextualSeparator(
            left: body,
            right: context.textAfterCursor,
            rightStartsWithAttachedPunctuation: startsWithAttachedPunctuation(context.textAfterCursor ?? "")
        )
        return prefix + body + suffix
    }

    private static func capitalizingLeadingOrdinaryWord(in text: String, preserving knownTerms: [String]) -> String {
        guard let start = text.firstIndex(where: { $0.isLetter || $0.isNumber }),
              text[start].isLowercase else { return text }
        let word = String(text[start...].prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
        // Sentence capitalization must not turn iPhone/eBay into IPhone/EBay.
        guard !word.dropFirst().contains(where: \.isUppercase),
              !knownTerms.contains(where: { $0.split(separator: " ").first?.lowercased() == word.lowercased() })
        else { return text }
        var result = text
        result.replaceSubrange(start..<text.index(after: start), with: String(text[start]).uppercased())
        return result
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

    private static func addingParallelListDelimiterIfNeeded(
        to text: String,
        textBeforeCursor: String?,
        textAfterCursor: String?
    ) -> String {
        let before = (textBeforeCursor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let after = (textAfterCursor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let listDelimiter = before.last, listDelimiter == "," || listDelimiter == "，",
              !after.isEmpty,
              after.first != listDelimiter,
              let finalScalar = text.unicodeScalars.last,
              !CharacterSet(charactersIn: ",;:，；：").contains(finalScalar) else {
            return text
        }

        let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        let followingClause = after.prefix { !sentenceEndings.contains($0) }
        guard followingClause.contains(listDelimiter) else { return text }
        return text + String(listDelimiter)
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

    /// A fragment-style list has no word-count limit. Preserve multi-sentence
    /// dictation, ellipses, abbreviations, and punctuation inside known terms;
    /// remove only the ordinary final period supplied for a standalone fragment.
    private static func removingListFragmentPeriod(from text: String, preserving knownTerms: [String]) -> String {
        guard !text.contains(where: \.isNewline) else { return text }
        let withoutPeriod = removingLightFinalPeriod(from: text)
        guard withoutPeriod != text,
              !knownTerms.contains(where: { term in
                  term.hasSuffix(".") && text.lowercased().hasSuffix(term.lowercased())
              }) else { return text }
        let characters = Array(withoutPeriod)
        for (index, character) in characters.enumerated() {
            if "。!?！？…".contains(character) { return text }
            if character == "." {
                // Decimal points do not make a phrase a multi-sentence item.
                let isDecimal = index > 0 && index + 1 < characters.count
                    && characters[index - 1].isNumber && characters[index + 1].isNumber
                if !isDecimal { return text }
            }
        }
        return withoutPeriod
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

    private static func addingListPeriodIfNeeded(to text: String, period: Character) -> String {
        var characters = Array(text)
        var end = characters.count
        while end > 0, "\"')]}’”」』】》".contains(characters[end - 1]) { end -= 1 }
        guard end > 0, !".。!?！？…:：;；".contains(characters[end - 1]) else { return text }
        characters.insert(period, at: end)
        return String(characters)
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
        let trace = PerfTrace.begin("insertion.clipboard")
        defer { trace.end() }
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
        let trace = PerfTrace.begin("insertion.pasteEvent")
        defer { trace.end() }
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
        let trace = PerfTrace.begin("insertion.pasteScript")
        defer { trace.end() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = """
                tell application "System Events"
                    keystroke "v" using command down
                end tell
                """
                var error: NSDictionary?
                let createTrace = PerfTrace.begin("insertion.pasteScriptCreate")
                let scriptObject = NSAppleScript(source: script)
                createTrace.end(outcome: scriptObject == nil ? "failed" : "success")
                if let scriptObject {
                    scriptObject.executeAndReturnError(&error)
                    continuation.resume(returning: error == nil)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
