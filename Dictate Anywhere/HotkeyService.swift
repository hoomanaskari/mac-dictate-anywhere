//
//  HotkeyService.swift
//  Dictate Anywhere
//
//  Global shortcut via CGEvent tap. Captures ANY key combination.
//

import Foundation
import CoreGraphics
import os

@Observable
final class HotkeyService {
    // MARK: - Callbacks

    var onKeyDown: ((HotkeyBinding) -> Void)?
    var onKeyUp: ((HotkeyBinding) -> Void)?
    var onEscape: (() -> Void)?

    // MARK: - State

    private(set) var isMonitoring = false
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeBindingIDs: Set<UUID> = []
    private let functionKeyCodes: Set<UInt16> = [63, 179]
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt = 0

    /// Cached bindings snapshot — read from the CGEvent callback thread.
    /// Only updated at startMonitoring() / restartMonitoring() to avoid data races.
    fileprivate var cachedBindings: [HotkeyBinding] = []

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere",
        category: "HotkeyService"
    )

    // MARK: - Initialization

    init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Public

    func startMonitoring() {
        attemptMonitoringStart(resetRetryState: true)
    }

    func stopMonitoring() {
        cancelRetry(resetAttempts: true)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        cachedBindings = []
        isMonitoring = false
        activeBindingIDs.removeAll()
    }

    func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    // MARK: - Startup

    private func attemptMonitoringStart(resetRetryState: Bool) {
        guard !isMonitoring else { return }

        let settings = Settings.shared
        guard settings.hasHotkey else {
            cachedBindings = []
            cancelRetry(resetAttempts: true)
            return
        }

        if resetRetryState {
            cancelRetry(resetAttempts: true)
        } else {
            retryWorkItem = nil
        }

        // Snapshot + normalize bindings so the callback thread never touches Settings
        cachedBindings = settings.hotkeyBindings.map(canonicalBindingForMatching)

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Use Unmanaged to pass self as user info
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: selfPtr
        ) else {
            cachedBindings = []
            scheduleRetry()
            logger.error("Failed to create CGEvent tap. Will retry until the login session is ready.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isMonitoring = true
        cancelRetry(resetAttempts: true)
        logger.info("Hotkey monitoring started")
    }

    private func scheduleRetry() {
        guard !isMonitoring, retryWorkItem == nil else { return }

        retryAttempt += 1
        let delay = min(pow(2.0, Double(max(0, retryAttempt - 1))) * 0.5, 5.0)
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptMonitoringStart(resetRetryState: false)
        }
        retryWorkItem = workItem
        let attemptNumber = retryAttempt
        logger.info(
            "Scheduling hotkey monitoring retry in \(String(format: "%.1f", delay), privacy: .public)s (attempt \(attemptNumber, privacy: .public))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelRetry(resetAttempts: Bool) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if resetAttempts {
            retryAttempt = 0
        }
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
        // Handle escape key for cancelling hands-free mode
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 53 { // Escape
                DispatchQueue.main.async { [weak self] in
                    self?.onEscape?()
                }
                return false
            }
        }

        let bindings = cachedBindings
        var shouldConsumeEvent = false
        for binding in bindings where binding.hasBinding {
            if binding.keyCode == nil {
                handleModifierOnlyEvent(type: type, event: event, binding: binding)
            } else {
                if handleKeyedEvent(type: type, event: event, binding: binding) {
                    shouldConsumeEvent = true
                }
            }
        }
        return shouldConsumeEvent
    }

    private func canonicalBindingForMatching(_ binding: HotkeyBinding) -> HotkeyBinding {
        guard let keyCode = binding.keyCode, functionKeyCodes.contains(keyCode) else { return binding }
        var normalized = binding
        var modifiers = normalized.modifiers
        modifiers.insert(.function)
        normalized.keyCode = nil
        normalized.modifiers = modifiers
        return normalized
    }

    private func handleKeyedEvent(type: CGEventType, event: CGEvent, binding: HotkeyBinding) -> Bool {
        guard let targetKeyCode = binding.keyCode else { return false }
        guard type == .keyDown || type == .keyUp else { return false }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return false }

        let bindingID = binding.id
        let targetModifiers = binding.modifiers
        let eventFlags = Settings.hotkeyModifiers(from: event.flags)
        let isActive = activeBindingIDs.contains(bindingID)
        let modifiersMatch = targetModifiers.isEmpty || Settings.keyedModifiersMatch(
            event: eventFlags,
            target: targetModifiers
        )
        guard modifiersMatch || (type == .keyUp && isActive) else { return false }

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
            guard isRepeat == 0, !isActive else { return true }
            activeBindingIDs.insert(bindingID)
            let capturedBinding = binding
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?(capturedBinding)
            }
            return true

        case .keyUp:
            guard isActive else { return modifiersMatch }
            activeBindingIDs.remove(bindingID)
            let capturedBinding = binding
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?(capturedBinding)
            }
            return true

        default:
            return false
        }
    }

    private func handleModifierOnlyEvent(type: CGEventType, event: CGEvent, binding: HotkeyBinding) {
        let targetModifiers = binding.modifiers
        guard !targetModifiers.isEmpty, type == .flagsChanged else { return }

        let eventModifiers = Settings.hotkeyModifiers(from: event.flags)
        let isHotkeyActive = Settings.modifierOnlyModifiersMatch(event: eventModifiers, target: targetModifiers)
        let bindingID = binding.id
        let isActive = activeBindingIDs.contains(bindingID)

        switch binding.mode {
        case .holdToRecord:
            if isHotkeyActive, !isActive {
                activeBindingIDs.insert(bindingID)
                let capturedBinding = binding
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?(capturedBinding)
                }
            } else if !isHotkeyActive, isActive {
                activeBindingIDs.remove(bindingID)
                let capturedBinding = binding
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?(capturedBinding)
                }
            }
        case .handsFreeToggle:
            if isHotkeyActive, !isActive {
                activeBindingIDs.insert(bindingID)
                let capturedBinding = binding
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?(capturedBinding)
                }
            } else if !isHotkeyActive, isActive {
                activeBindingIDs.remove(bindingID)
            }
        }
    }

}

// MARK: - C Callback

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // Handle tap disabled events
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Re-enable the tap
        let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    if service.handleEvent(proxy, type: type, event: event) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
