//
//  TextInserter.swift
//  Dictate Anywhere
//
//  Clipboard + paste (CGEvent Cmd+V) for inserting text into focused inputs.
//

import Foundation
import AppKit
import CoreGraphics
import Carbon
import os

enum TextInsertionResult {
    case success
    case copiedOnly
    case failed
}

enum PasteScriptOutcome: Equatable, Sendable {
    case success
    case automationDenied
    case possiblyDispatched
    case targetUnavailable
    case preDispatchFailed

    static func fromAppleScriptError(_ error: NSDictionary?) -> PasteScriptOutcome {
        guard let error else { return .success }
        if (error[NSAppleScript.errorNumber] as? Int) == Int(errAEEventNotPermitted) {
            return .automationDenied
        }
        return .possiblyDispatched
    }
}

nonisolated func pasteTargetProofMatches(
    expected: CFRange,
    actual: CFRange,
    sameFocusedElement: Bool
) -> Bool {
    sameFocusedElement
        && expected.location == actual.location
        && expected.length == actual.length
}

/// Compiles and executes the paste script on one serial queue. The queue owns
/// the non-Sendable NSAppleScript; no other thread reads or executes it.
private nonisolated final class PasteScriptRunner: @unchecked Sendable {
    private static let source = """
        on pasteIntoProcess(targetPID)
            tell application "System Events"
                set targets to application processes whose unix id is targetPID
                if (count of targets) is not 1 then return 1
                tell item 1 of targets
                    if not frontmost then return 1
                    -- AX menu clicks are addressed to this process. System Events'
                    -- keystroke command can reach a different app after a focus change.
                    repeat with topItem in menu bar items of menu bar 1
                        repeat with candidate in menu items of menu 1 of topItem
                            set matchesPaste to false
                            try
                                if (value of attribute "AXMenuItemCmdChar" of candidate) is "V" and ¬
                                   (value of attribute "AXMenuItemCmdModifiers" of candidate) is 0 and ¬
                                   enabled of candidate then
                                    set matchesPaste to true
                                end if
                            end try
                            if matchesPaste then
                                try
                                    click candidate
                                    return 0
                                on error
                                    -- Once click is attempted, an error cannot
                                    -- prove the target did not receive Paste.
                                    return 3
                                end try
                            end if
                        end repeat
                    end repeat
                    return 2
                end tell
            end tell
            return 1
        end pasteIntoProcess
        """

    private let queue = DispatchQueue(label: "com.dictate-anywhere.paste-script", qos: .userInitiated)
    private var cachedScript: NSAppleScript?

    func precompile() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: compiledScript() != nil)
            }
        }
    }

    func paste(targetProcessIdentifier: pid_t) async -> PasteScriptOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let script = compiledScript() else {
                    continuation.resume(returning: .preDispatchFailed)
                    return
                }
                var error: NSDictionary?
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID)
                )
                event.setParam(NSAppleEventDescriptor(string: "pasteintoprocess"), forKeyword: AEKeyword(keyASSubroutineName))
                let arguments = NSAppleEventDescriptor.list()
                arguments.insert(NSAppleEventDescriptor(int32: targetProcessIdentifier), at: 1)
                event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
                let result = script.executeAppleEvent(event, error: &error)
                if error != nil {
                    continuation.resume(returning: PasteScriptOutcome.fromAppleScriptError(error))
                    return
                }
                switch result.int32Value {
                case 0:
                    continuation.resume(returning: .success)
                case 1:
                    continuation.resume(returning: .targetUnavailable)
                case 2:
                    continuation.resume(returning: .preDispatchFailed)
                default:
                    continuation.resume(returning: .possiblyDispatched)
                }
            }
        }
    }

    private func compiledScript() -> NSAppleScript? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let cachedScript { return cachedScript }
        let trace = PerfTrace.begin("insertion.pasteCompile")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: Self.source),
              script.compileAndReturnError(&error) else {
            trace.end(outcome: "failed")
            return nil
        }
        cachedScript = script
        trace.end()
        return script
    }
}

/// Performs small, process-addressed Accessibility reads and Paste actions on
/// one serial worker so synchronous AX IPC never occupies the main actor.
private nonisolated final class InsertionAccessibilityWorker: @unchecked Sendable {
    private struct TargetIdentity: Equatable, Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let launchTime: TimeInterval
    }

    private struct CachedPasteItem {
        let target: TargetIdentity
        let element: AXUIElement
    }

    private struct PasteCandidate {
        let menuItem: AXUIElement
        let focusedElement: AXUIElement
        let selectedRange: CFRange
    }

    private struct RequiredPasteTarget {
        let focusedElement: AXUIElement
        let selection: CFRange
        let originalValue: String
    }

    struct PreparedListEdit: @unchecked Sendable {
        let element: AXUIElement
        let originalRange: CFRange
        let originalValue: String
        let edit: PlainTextListEdit
    }

    private let queue = DispatchQueue(label: "com.dictate-anywhere.insertion-accessibility", qos: .userInitiated)
    private let messageTimeout: Float = 0.025
    private var cachedPasteItem: CachedPasteItem?

    func characterBeforeInsertionPoint(
        processIdentifier: pid_t,
        isTargetReady: @escaping @MainActor @Sendable () -> Bool
    ) async -> String? {
        guard await MainActor.run(body: isTargetReady) else { return nil }
        let character: String? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: characterBeforeInsertionPointOnQueue(processIdentifier: processIdentifier))
            }
        }
        guard await MainActor.run(body: isTargetReady) else { return nil }
        return character
    }

    func prepareListEdit(
        insertion: String,
        context: DictationContext,
        processIdentifier: pid_t,
        isTargetReady: @escaping @MainActor @Sendable () -> Bool
    ) async -> PreparedListEdit? {
        guard await MainActor.run(body: isTargetReady) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let deadline = ContinuousClock.now + .milliseconds(350)
                let application = AXUIElementCreateApplication(processIdentifier)
                setTimeout(on: application)
                guard let element = focusedElement(in: application),
                      self.processIdentifier(of: element) == processIdentifier,
                      let range = selectedTextRange(in: element), range.location >= 0,
                      let value = textValue(of: element), (value as NSString).length <= 100_000,
                      snapshotMatches(value: value, range: range, context: context),
                      let edit = PlainTextListEdit.prepare(
                        value: value,
                        selection: NSRange(location: range.location, length: range.length),
                        insertion: insertion,
                        context: context
                      ),
                      ContinuousClock.now < deadline else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PreparedListEdit(
                    element: element, originalRange: range, originalValue: value, edit: edit
                ))
            }
        }
    }

    func selectListEdit(_ pending: PreparedListEdit, targetApplication: NSRunningApplication) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let deadline = ContinuousClock.now + .milliseconds(300)
                guard let application = appFor(pending.element),
                      targetApplication.isActive, !targetApplication.isTerminated,
                      focusedElement(in: application).map({ CFEqual($0, pending.element) }) == true,
                      textValue(of: pending.element) == pending.originalValue,
                      selectedTextRange(in: pending.element).map({
                        $0.location == pending.originalRange.location && $0.length == pending.originalRange.length
                      }) == true,
                      setSelection(pending.edit.range, in: pending.element) else {
                    continuation.resume(returning: false)
                    return
                }
                for _ in 0..<8 {
                    guard ContinuousClock.now < deadline, targetApplication.isActive,
                          !targetApplication.isTerminated,
                          focusedElement(in: application).map({ CFEqual($0, pending.element) }) == true else { break }
                    if selectedTextRange(in: pending.element).map({
                        $0.location == pending.edit.range.location && $0.length == pending.edit.range.length
                    }) == true,
                       textValue(of: pending.element) == pending.originalValue {
                        continuation.resume(returning: true)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if targetApplication.isActive, !targetApplication.isTerminated,
                   focusedElement(in: application).map({ CFEqual($0, pending.element) }) == true,
                   textValue(of: pending.element) == pending.originalValue,
                   selectedTextRange(in: pending.element).map({
                    $0.location == pending.edit.range.location && $0.length == pending.edit.range.length
                   }) == true {
                    _ = setSelection(
                        NSRange(location: pending.originalRange.location, length: pending.originalRange.length),
                        in: pending.element
                    )
                }
                continuation.resume(returning: false)
            }
        }
    }

    func restoreListEditSelection(_ pending: PreparedListEdit, targetApplication: NSRunningApplication) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if targetApplication.isActive, !targetApplication.isTerminated,
                   let application = appFor(pending.element),
                   focusedElement(in: application).map({ CFEqual($0, pending.element) }) == true,
                   textValue(of: pending.element) == pending.originalValue,
                   selectedTextRange(in: pending.element).map({
                    $0.location == pending.edit.range.location && $0.length == pending.edit.range.length
                   }) == true {
                    _ = setSelection(
                        NSRange(location: pending.originalRange.location, length: pending.originalRange.length),
                        in: pending.element
                    )
                }
                continuation.resume()
            }
        }
    }

    func finishListEdit(_ pending: PreparedListEdit, targetApplication: NSRunningApplication) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let deadline = ContinuousClock.now + .milliseconds(500)
                guard let application = appFor(pending.element) else {
                    continuation.resume(returning: false)
                    return
                }
                while ContinuousClock.now < deadline, targetApplication.isActive,
                      !targetApplication.isTerminated,
                      focusedElement(in: application).map({ CFEqual($0, pending.element) }) == true {
                    if textValue(of: pending.element) == pending.edit.expectedValue {
                        if let range = selectedTextRange(in: pending.element), range.length == 0,
                           range.location == pending.edit.range.location + (pending.edit.replacement as NSString).length,
                           focusedElement(in: application).map({ CFEqual($0, pending.element) }) == true {
                            _ = setSelection(NSRange(location: pending.edit.caretLocation, length: 0), in: pending.element)
                        }
                        continuation.resume(returning: true)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.025)
                }
                continuation.resume(returning: false)
            }
        }
    }

    private func appFor(_ element: AXUIElement) -> AXUIElement? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success, processIdentifier > 0 else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        setTimeout(on: application)
        return application
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        return AXUIElementGetPid(element, &processIdentifier) == .success ? processIdentifier : nil
    }

    private func textValue(of element: AXUIElement) -> String? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        setTimeout(on: element)
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private func snapshotMatches(value: String, range: CFRange, context: DictationContext) -> Bool {
        let value = value as NSString
        guard range.length == 0, range.location >= 0, range.location <= value.length,
              let before = context.textBeforeCursor, let after = context.textAfterCursor,
              context.selectedText?.isEmpty != false,
              value.substring(to: range.location).hasSuffix(before),
              value.substring(from: range.location).hasPrefix(after) else { return false }
        return true
    }

    func paste(
        targetApplication: NSRunningApplication,
        requiredListEdit: PreparedListEdit? = nil
    ) async -> PasteScriptOutcome {
        guard let launchDate = targetApplication.launchDate else { return .preDispatchFailed }
        let target = TargetIdentity(
            processIdentifier: targetApplication.processIdentifier,
            bundleIdentifier: targetApplication.bundleIdentifier,
            launchTime: launchDate.timeIntervalSince1970
        )
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard targetApplication.isActive, !targetApplication.isTerminated else {
                    continuation.resume(returning: .targetUnavailable)
                    return
                }
                let requiredTarget = requiredListEdit.map {
                    RequiredPasteTarget(
                        focusedElement: $0.element,
                        selection: CFRange(location: $0.edit.range.location, length: $0.edit.range.length),
                        originalValue: $0.originalValue
                    )
                }
                guard let candidate = pasteCandidate(for: target, requiredTarget: requiredTarget) else {
                    continuation.resume(returning: .preDispatchFailed)
                    return
                }
                guard targetApplication.isActive, !targetApplication.isTerminated else {
                    continuation.resume(returning: .targetUnavailable)
                    return
                }
                guard cacheStillMatches(candidate.menuItem, target: target),
                      isPasteMenuItem(candidate.menuItem, target: target),
                      focusAndSelectionMatch(candidate, processIdentifier: target.processIdentifier),
                      requiredTarget.map({
                        pasteTargetProofMatches(
                            expected: $0.selection,
                            actual: candidate.selectedRange,
                            sameFocusedElement: CFEqual(candidate.focusedElement, $0.focusedElement)
                        ) && textValue(of: $0.focusedElement) == $0.originalValue
                      }) ?? true else {
                    invalidate(candidate.menuItem, target: target)
                    continuation.resume(returning: .preDispatchFailed)
                    return
                }
                guard targetApplication.isActive, !targetApplication.isTerminated else {
                    invalidate(candidate.menuItem, target: target)
                    continuation.resume(returning: .targetUnavailable)
                    return
                }
                let result = AXUIElementPerformAction(candidate.menuItem, kAXPressAction as CFString)
                if result == .success {
                    continuation.resume(returning: .success)
                } else {
                    invalidate(candidate.menuItem, target: target)
                    // After AXPress is issued, every error is ambiguous: AX
                    // does not prove that the target app did not handle it.
                    continuation.resume(returning: .possiblyDispatched)
                }
            }
        }
    }

    private func pasteCandidate(
        for target: TargetIdentity,
        requiredTarget: RequiredPasteTarget? = nil
    ) -> PasteCandidate? {
        dispatchPrecondition(condition: .onQueue(queue))
        let application = AXUIElementCreateApplication(target.processIdentifier)
        setTimeout(on: application)
        guard let focusedElement = focusedElement(in: application),
              processIdentifier(of: focusedElement) == target.processIdentifier else { return nil }
        if let requiredTarget {
            guard CFEqual(focusedElement, requiredTarget.focusedElement),
                  let range = selectedTextRange(in: focusedElement),
                  pasteTargetProofMatches(
                    expected: requiredTarget.selection,
                    actual: range,
                    sameFocusedElement: true
                  ) else { return nil }
        }
        if let cachedPasteItem, cachedPasteItem.target == target,
           isPasteMenuItem(cachedPasteItem.element, target: target) {
            return candidate(menuItem: cachedPasteItem.element, capturedFocusedElement: focusedElement,
                             application: application)
        }
        cachedPasteItem = nil

        let deadline = ContinuousClock.now + .milliseconds(300)
        guard let menuBar = copyElement(kAXMenuBarAttribute as String, from: application),
              let topLevelItems = childElements(of: menuBar) else { return nil }

        for topLevelItem in topLevelItems.prefix(8) {
            guard ContinuousClock.now < deadline else { return nil }
            guard let menuContents = childElements(of: topLevelItem) else { continue }
            let menuItems: [AXUIElement]
            if let menu = menuContents.first,
               ContinuousClock.now < deadline,
               role(of: menu) == (kAXMenuRole as String),
               ContinuousClock.now < deadline,
               let children = childElements(of: menu) {
                menuItems = children
            } else {
                menuItems = menuContents
            }
            for menuItem in menuItems.prefix(32) {
                guard ContinuousClock.now < deadline else { return nil }
                guard let character = commandCharacter(of: menuItem),
                      ContinuousClock.now < deadline,
                      character.caseInsensitiveCompare("V") == .orderedSame,
                      ContinuousClock.now < deadline,
                      commandModifiers(of: menuItem) == 0,
                      ContinuousClock.now < deadline,
                      isEnabled(menuItem),
                      ContinuousClock.now < deadline,
                      processIdentifier(of: menuItem) == target.processIdentifier else { continue }
                cachedPasteItem = CachedPasteItem(target: target, element: menuItem)
                return candidate(menuItem: menuItem, capturedFocusedElement: focusedElement,
                                 application: application)
            }
        }
        return nil
    }

    private func cacheStillMatches(_ item: AXUIElement, target: TargetIdentity) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let cachedPasteItem else { return false }
        return cachedPasteItem.target == target && CFEqual(cachedPasteItem.element, item)
    }

    private func isPasteMenuItem(_ item: AXUIElement, target: TargetIdentity) -> Bool {
        commandCharacter(of: item)?.caseInsensitiveCompare("V") == .orderedSame
            && commandModifiers(of: item) == 0
            && isEnabled(item)
            && processIdentifier(of: item) == target.processIdentifier
    }

    private func candidate(
        menuItem: AXUIElement,
        capturedFocusedElement: AXUIElement,
        application: AXUIElement
    ) -> PasteCandidate? {
        guard let currentFocus = focusedElement(in: application),
              CFEqual(currentFocus, capturedFocusedElement),
              let currentRange = selectedTextRange(in: currentFocus) else { return nil }
        return PasteCandidate(menuItem: menuItem, focusedElement: capturedFocusedElement, selectedRange: currentRange)
    }

    private func focusAndSelectionMatch(_ candidate: PasteCandidate, processIdentifier: pid_t) -> Bool {
        guard let focused = focusedElement(processIdentifier: processIdentifier),
              CFEqual(focused, candidate.focusedElement),
              let selectedRange = selectedTextRange(in: focused) else { return false }
        return selectedRange.location == candidate.selectedRange.location
            && selectedRange.length == candidate.selectedRange.length
    }

    private func invalidate(_ item: AXUIElement, target: TargetIdentity) {
        dispatchPrecondition(condition: .onQueue(queue))
        if cachedPasteItem?.target == target, let cached = cachedPasteItem?.element, CFEqual(cached, item) {
            cachedPasteItem = nil
        }
    }

    private func characterBeforeInsertionPointOnQueue(processIdentifier: pid_t) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        let application = AXUIElementCreateApplication(processIdentifier)
        setTimeout(on: application)
        guard let focused = focusedElement(in: application),
              self.processIdentifier(of: focused) == processIdentifier,
              let selectedRange = selectedTextRange(in: focused),
              selectedRange.location != kCFNotFound else { return nil }
        guard selectedRange.location > 0 else { return "" }

        var range = CFRange(location: selectedRange.location - 1, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let rangeStatus = AXUIElementCopyParameterizedAttributeValue(
            focused, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        )
        var precedingCharacter = rangeStatus == .success ? value as? String : nil
        if precedingCharacter == nil {
            var fullValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &fullValue) == .success,
               let text = fullValue as? String {
                let nsText = text as NSString
                if selectedRange.location <= nsText.length {
                    precedingCharacter = nsText.substring(with: NSRange(location: selectedRange.location - 1, length: 1))
                }
            }
        }
        guard focusedElement(in: application).map({ CFEqual($0, focused) }) == true,
              let currentRange = selectedTextRange(in: focused),
              currentRange.location == selectedRange.location,
              currentRange.length == selectedRange.length else { return nil }
        return precedingCharacter
    }

    private func focusedElement(in application: AXUIElement) -> AXUIElement? {
        copyElement(kAXFocusedUIElementAttribute as String, from: application)
    }

    private func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        setTimeout(on: application)
        return focusedElement(in: application)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement]? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        return children
    }

    private func copyElement(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = unsafeBitCast(value, to: AXUIElement.self)
        setTimeout(on: result)
        return result
    }

    private func commandCharacter(of element: AXUIElement) -> String? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func role(of element: AXUIElement) -> String? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func commandModifiers(of element: AXUIElement) -> UInt32? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.uint32Value
    }

    private func isEnabled(_ element: AXUIElement) -> Bool {
        setTimeout(on: element)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success
            && (value as? NSNumber)?.boolValue == true
    }

    private func selectedTextRange(in element: AXUIElement) -> CFRange? {
        setTimeout(on: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func setTimeout(on element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, messageTimeout)
    }
}

final class TextInserter {
    private var pendingSeparator = ""
    private var pendingSeparatorTargetBundleIdentifier: String?
    private let pasteScriptRunner = PasteScriptRunner()
    private let accessibilityWorker = InsertionAccessibilityWorker()
    private let permissions: Permissions

    init(permissions: Permissions = Permissions()) {
        self.permissions = permissions
    }

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
        // An explicit destination must never fall back to a different frontmost app.
        let targetApplication: NSRunningApplication?
        if let targetProcessIdentifier {
            targetApplication = NSRunningApplication(processIdentifier: targetProcessIdentifier)
        } else {
            targetApplication = frontmostApplication
        }
        let targetIsReady: @MainActor @Sendable () -> Bool = {
            guard let targetApplication, !targetApplication.isTerminated else { return false }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApplication.processIdentifier
        }
        let resolvedTargetProcessIdentifier = targetApplication?.processIdentifier
        let targetBundleIdentifier = targetApplication?.bundleIdentifier
        let hasMatchingInsertionPlan = modelInsertionPlan.map {
            Self.normalizedForInsertion($0.text) == Self.normalizedForInsertion(text)
        } == true
        let usesCapturedContext = !hasMatchingInsertionPlan
            && context != nil
            && style != nil
            && context.map {
                Self.shouldUseContextualInsertion(context: $0, targetProcessIdentifier: resolvedTargetProcessIdentifier)
            } == true
        let separatorContext: String?
        if !hasMatchingInsertionPlan,
           !usesCapturedContext,
           !pendingSeparator.isEmpty,
           pendingSeparatorTargetBundleIdentifier == targetBundleIdentifier,
           Self.needsSeparator(before: text),
           permissions.checkAccessibilityForUse(promptIfNeeded: false),
           let processIdentifier = resolvedTargetProcessIdentifier {
            separatorContext = await accessibilityWorker.characterBeforeInsertionPoint(
                processIdentifier: processIdentifier,
                isTargetReady: targetIsReady
            )
        } else {
            separatorContext = nil
        }
        let insertionText = PerfTrace.measure("insertion.prepare") {
            preparedTextForInsertion(
                text,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessIdentifier: resolvedTargetProcessIdentifier,
                context: context,
                style: style,
                knownTerms: knownTerms,
                modelInsertionPlan: modelInsertionPlan,
                preserveModelFormatting: preserveModelFormatting,
                precedingTextForSeparator: separatorContext
            )
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere", category: "TextInsertion")
        logger.info("insertionFormatting: model=\(preserveModelFormatting) explicitSpacing=\(modelInsertionPlan != nil) inputUpper=\(text.first(where: \.isLetter)?.isUppercase == true) outputUpper=\(insertionText.first(where: \.isLetter)?.isUppercase == true) leadingSpace=\(insertionText.hasPrefix(" ")) trailingSpace=\(insertionText.hasSuffix(" "))")
        guard !insertionText.isEmpty else { return .failed }

        // Copy to clipboard first (always)
        guard await copyToClipboard(insertionText) else { return .failed }
        guard pasteAutomatically, targetIsReady() else {
            resetPendingSeparator()
            deliverOutcome = "copiedOnly"
            return .copiedOnly
        }

        // Check accessibility permission
        guard permissions.checkAccessibilityForUse(promptIfNeeded: true) else {
            resetPendingSeparator()
            deliverOutcome = "copiedOnly"
            return .copiedOnly
        }

        // Copying already verified read-back. Only wait if another pasteboard
        // read cannot yet see the text, with the former delay as a deadline.
        let clipboardReadyTrace = PerfTrace.begin("insertion.clipboardReady")
        let clipboardDeadline = ContinuousClock.now + .milliseconds(80)
        while NSPasteboard.general.string(forType: .string) != insertionText {
            guard !Task.isCancelled, ContinuousClock.now < clipboardDeadline else { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        clipboardReadyTrace.end()

        // Plain-text numbering needs one verified replacement, not a second
        // blind edit after pasting. If the snapshot is stale, leave the text on
        // the clipboard rather than replacing someone else's changes.
        var listEdit: InsertionAccessibilityWorker.PreparedListEdit?
        if let context, context.processIdentifier == resolvedTargetProcessIdentifier,
           PlainTextListEdit.needsRenumbering(insertion: insertionText, context: context) {
            let listEditTrace = PerfTrace.begin("insertion.listEdit")
            defer { listEditTrace.end() }
            guard let pid = resolvedTargetProcessIdentifier, let targetApplication,
                  let prepared = await accessibilityWorker.prepareListEdit(
                    insertion: insertionText,
                    context: context,
                    processIdentifier: pid,
                    isTargetReady: targetIsReady
                  ), targetIsReady() else {
                logger.info("plainListEdit: live snapshot unavailable or changed")
                resetPendingSeparator()
                deliverOutcome = "copiedOnly"
                return .copiedOnly
            }
            guard await copyToClipboard(prepared.edit.replacement) else { return .failed }
            guard targetIsReady(), await accessibilityWorker.selectListEdit(prepared, targetApplication: targetApplication), targetIsReady() else {
                await accessibilityWorker.restoreListEditSelection(prepared, targetApplication: targetApplication)
                _ = await copyToClipboard(insertionText)
                deliverOutcome = "copiedOnly"
                return .copiedOnly
            }
            listEdit = prepared
        }

        // Revalidate after every suspension, including before the keyboard fallback.
        var usedKeyboardEvent = false
        let pasteResult = await Self.deliverToTarget(
            isTargetReady: targetIsReady,
            pasteScript: {
                guard let targetApplication, let pid = resolvedTargetProcessIdentifier else { return .targetUnavailable }
                let nativePasteTrace = PerfTrace.begin("insertion.pasteAX")
                let accessibilityOutcome = await self.accessibilityWorker.paste(
                    targetApplication: targetApplication,
                    requiredListEdit: listEdit
                )
                switch accessibilityOutcome {
                case .success:
                    nativePasteTrace.end()
                case .automationDenied:
                    nativePasteTrace.end(outcome: "automationDenied")
                case .possiblyDispatched:
                    nativePasteTrace.end(outcome: "possiblyDispatched")
                case .targetUnavailable:
                    nativePasteTrace.end(outcome: "targetUnavailable")
                case .preDispatchFailed:
                    nativePasteTrace.end(outcome: "preDispatchFailed")
                }
                return await Self.pasteWithScriptFallback(
                    accessibilityOutcome: accessibilityOutcome,
                    hasPendingListEdit: listEdit != nil
                ) {
                    await self.simulatePasteWithAppleScript(targetProcessIdentifier: pid)
                }
            },
            pasteEvent: {
                guard let pid = resolvedTargetProcessIdentifier else { return false }
                usedKeyboardEvent = true
                return self.simulatePasteWithCGEvent(targetProcessIdentifier: pid)
            }
        )
        if pasteResult == .success {
            if usedKeyboardEvent { try? await Task.sleep(for: .milliseconds(100)) }
            if let listEdit, let targetApplication,
               await accessibilityWorker.finishListEdit(listEdit, targetApplication: targetApplication) {
                _ = await copyToClipboard(insertionText)
            }
            prepareForNextInsertion(targetBundleIdentifier: targetBundleIdentifier)
            deliverOutcome = "success"
            return .success
        }

        if let listEdit {
            if let targetApplication {
                await accessibilityWorker.restoreListEditSelection(listEdit, targetApplication: targetApplication)
            }
            _ = await copyToClipboard(insertionText)
        }
        resetPendingSeparator()
        deliverOutcome = "copiedOnly"
        return .copiedOnly
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
        preserveModelFormatting: Bool = false,
        precedingTextForSeparator: String? = nil
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
        let separatorPrefix = separatorPrefixIfNeeded(
            for: targetBundleIdentifier,
            insertionText: normalized,
            precedingText: precedingTextForSeparator
        )
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

    private func separatorPrefixIfNeeded(
        for targetBundleIdentifier: String?,
        insertionText: String,
        precedingText: String?
    ) -> String {
        guard !pendingSeparator.isEmpty else { return "" }

        guard let targetBundleIdentifier,
              pendingSeparatorTargetBundleIdentifier == targetBundleIdentifier else {
            resetPendingSeparator()
            return ""
        }

        guard shouldInsertPendingSeparator(before: insertionText, precedingText: precedingText) else { return "" }

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

    private func shouldInsertPendingSeparator(before insertionText: String, precedingText: String?) -> Bool {
        guard Self.needsSeparator(before: insertionText),
              let precedingText,
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

    private func simulatePasteWithCGEvent(targetProcessIdentifier: pid_t) -> Bool {
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

        keyDown.postToPid(targetProcessIdentifier)
        keyUp.postToPid(targetProcessIdentifier)

        return true
    }

    private func simulatePasteWithAppleScript(targetProcessIdentifier: pid_t) async -> PasteScriptOutcome {
        let trace = PerfTrace.begin("insertion.pasteScript")
        defer { trace.end() }
        let outcome = await pasteScriptRunner.paste(targetProcessIdentifier: targetProcessIdentifier)
        switch outcome {
        case .success:
            permissions.recordAutomationPastePermission(denied: false)
        case .automationDenied:
            permissions.recordAutomationPastePermission(denied: true)
        case .targetUnavailable, .preDispatchFailed, .possiblyDispatched:
            break
        }
        return outcome
    }

    static func pasteWithScriptFallback(
        accessibilityOutcome: PasteScriptOutcome,
        hasPendingListEdit: Bool,
        pasteScript: () async -> PasteScriptOutcome
    ) async -> PasteScriptOutcome {
        // Success and uncertain dispatch are final: retrying can insert twice.
        guard accessibilityOutcome == .preDispatchFailed else { return accessibilityOutcome }
        guard !hasPendingListEdit else { return .targetUnavailable }
        return await pasteScript()
    }

    /// The production dispatch sequence, injectable without sending real keystrokes.
    static func deliverToTarget(
        isTargetReady: @MainActor () -> Bool,
        pasteScript: () async -> PasteScriptOutcome,
        pasteEvent: () -> Bool
    ) async -> TextInsertionResult {
        guard isTargetReady() else { return .copiedOnly }
        let result = await pasteScript()
        if result == .success { return .success }
        if result == .possiblyDispatched { return .copiedOnly }
        guard result != .targetUnavailable, isTargetReady() else { return .copiedOnly }
        return pasteEvent() ? .success : .copiedOnly
    }

    /// Compiles the paste script ahead of first use so no dictation pays
    /// compile cost. Called at startup regardless of the model prewarm setting.
    func prewarmPasteScript() async -> Bool {
        await pasteScriptRunner.precompile()
    }
}
