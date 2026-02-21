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

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?

    // MARK: - State

    private(set) var isMonitoring = false
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isMonitoring = false
        isKeyDown = false
    }

    func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        let settings = Settings.shared
        let targetKeyCode = settings.hotkeyKeyCode
        let targetModifiers = Settings.normalizedModifierFlags(settings.hotkeyModifiers)

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

        // Modifier-only hotkey (e.g. ⌃⌥⌘ with no non-modifier key)
        if targetKeyCode == nil {
            handleModifierOnlyEvent(type: type, event: event, targetModifiers: targetModifiers, mode: settings.hotkeyMode)
            return
        }

        guard let targetKeyCode else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Check if this matches our hotkey
        guard keyCode == targetKeyCode else { return }

        // Check modifiers
        let eventFlags = Settings.normalizedModifierFlags(event.flags)
        if !targetModifiers.isEmpty {
            guard eventFlags.contains(targetModifiers) else { return }
        }

        switch type {
        case .keyDown:
            // Ignore key repeats
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
            guard isRepeat == 0, !isKeyDown else { return }
            isKeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?()
            }

        case .keyUp:
            guard isKeyDown else { return }
            isKeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }

        default:
            break
        }
    }

    private func handleModifierOnlyEvent(
        type: CGEventType,
        event: CGEvent,
        targetModifiers: CGEventFlags,
        mode: HotkeyMode
    ) {
        guard !targetModifiers.isEmpty, type == .flagsChanged else { return }

        let eventModifiers = Settings.normalizedModifierFlags(event.flags)
        let isHotkeyActive = eventModifiers == targetModifiers

        switch mode {
        case .holdToRecord:
            if isHotkeyActive, !isKeyDown {
                isKeyDown = true
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            } else if !isHotkeyActive, isKeyDown {
                isKeyDown = false
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
        case .handsFreeToggle:
            if isHotkeyActive, !isKeyDown {
                isKeyDown = true
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            } else if !isHotkeyActive, isKeyDown {
                isKeyDown = false
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
