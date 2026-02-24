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
        guard !isMonitoring else { return }

        let settings = Settings.shared
        guard settings.hasHotkey else { return }

        // Snapshot + normalize bindings so the callback thread never touches Settings
        cachedBindings = settings.hotkeyBindings.map(canonicalBindingForMatching)

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Use Unmanaged to pass self as user info
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: selfPtr
        ) else {
            logger.error("Failed to create CGEvent tap. Accessibility permission required.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isMonitoring = true
        logger.info("Hotkey monitoring started")
    }

    func stopMonitoring() {
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

    // MARK: - Event Handling

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        // Handle escape key for cancelling hands-free mode
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 53 { // Escape
                DispatchQueue.main.async { [weak self] in
                    self?.onEscape?()
                }
                return
            }
        }

        let bindings = cachedBindings
        for binding in bindings where binding.hasBinding {
            if binding.keyCode == nil {
                handleModifierOnlyEvent(type: type, event: event, binding: binding)
            } else {
                handleKeyedEvent(type: type, event: event, binding: binding)
            }
        }
    }

    private func canonicalBindingForMatching(_ binding: HotkeyBinding) -> HotkeyBinding {
        guard let keyCode = binding.keyCode, functionKeyCodes.contains(keyCode) else { return binding }
        var normalized = binding
        var modifiers = normalized.cgModifiers
        modifiers.insert(.maskSecondaryFn)
        normalized.keyCode = nil
        normalized.cgModifiers = modifiers
        return normalized
    }

    private func handleKeyedEvent(type: CGEventType, event: CGEvent, binding: HotkeyBinding) {
        guard let targetKeyCode = binding.keyCode else { return }
        guard type == .keyDown || type == .keyUp else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return }

        let targetModifiers = binding.cgModifiers
        let eventFlags = Settings.normalizedModifierFlags(event.flags)
        if !targetModifiers.isEmpty {
            guard eventFlags.contains(targetModifiers) else { return }
        }

        let bindingID = binding.id

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
            guard isRepeat == 0, !activeBindingIDs.contains(bindingID) else { return }
            activeBindingIDs.insert(bindingID)
            let capturedBinding = binding
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?(capturedBinding)
            }

        case .keyUp:
            guard activeBindingIDs.contains(bindingID) else { return }
            activeBindingIDs.remove(bindingID)
            let capturedBinding = binding
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?(capturedBinding)
            }

        default:
            break
        }
    }

    private func handleModifierOnlyEvent(type: CGEventType, event: CGEvent, binding: HotkeyBinding) {
        let targetModifiers = binding.cgModifiers
        guard !targetModifiers.isEmpty, type == .flagsChanged else { return }

        let eventModifiers = Settings.normalizedModifierFlags(event.flags)
        let isHotkeyActive = eventModifiers == targetModifiers
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
    service.handleEvent(proxy, type: type, event: event)

    return Unmanaged.passUnretained(event)
}
