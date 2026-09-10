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
    var onCancel: (() -> Void)?
    var onCancelProgress: ((Double?) -> Void)?
    var isCancellationEnabled = false {
        didSet { if !isCancellationEnabled { resetCancellationGesture() } }
    }
    private var cancelBinding = HotkeyBinding.defaultCancelBinding
    private var requiresCancelHold = true
    private var cancelGesture = CancellationGesture()
    private var cancelHoldTask: Task<Void, Never>?

    func resetCancellationGesture() {
        cancelHoldTask?.cancel()
        cancelHoldTask = nil
        cancelGesture.reset()
        onCancelProgress?(nil)
    }

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
        resetCancellationGesture()
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
        guard settings.hasHotkey || settings.cancelShortcut.hasBinding else {
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
        configureBindings(recording: settings.hotkeyBindings, cancellation: settings.cancelShortcut,
                          requiresHold: settings.holdToCancel)

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

    func configureBindings(recording: [HotkeyBinding], cancellation: HotkeyBinding, requiresHold: Bool) {
        resetCancellationGesture()
        cachedBindings = recording.map(canonicalBindingForMatching)
        cancelBinding = canonicalBindingForMatching(cancellation)
        requiresCancelHold = requiresHold
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        let consumedByCancellation = handleCancellationEvent(type: type, event: event)
        if consumedByCancellation { return true }

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

    private func handleCancellationEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard isCancellationEnabled, cancelBinding.hasBinding else { return false }
        let wasPressed = cancelGesture.startedAt != nil
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        cancelGesture.update(
            type: type, keyCode: keyCode,
            modifiers: cancellationModifiers(from: Settings.hotkeyModifiers(from: event.flags)),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            binding: cancelBinding, now: ProcessInfo.processInfo.systemUptime
        )
        let isPressed = cancelGesture.startedAt != nil
        if wasPressed && !isPressed {
            resetCancellationGesture()
        } else if !wasPressed && isPressed {
            advanceCancellationGesture()
            if requiresCancelHold {
                cancelHoldTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                        guard let self, self.isCancellationEnabled,
                              self.cancelGesture.startedAt != nil else { return }
                        self.advanceCancellationGesture()
                        if self.cancelGesture.fired { return }
                    }
                }
            }
        }
        // Plain Escape remains available to the foreground application during a hold.
        // Other bound key combinations are reserved only during an active dictation.
        let isPlainEscape = cancelBinding.keyCode == 53 && cancelBinding.modifiers.isEmpty
        return !isPlainEscape && cancelBinding.keyCode == keyCode
            && (type == .keyDown || type == .keyUp) && (wasPressed || isPressed)
    }

    private func advanceCancellationGesture() {
        let now = ProcessInfo.processInfo.systemUptime
        onCancelProgress?(requiresCancelHold ? cancelGesture.progress(now: now, requiresHold: true) : nil)
        if cancelGesture.shouldCancel(now: now, requiresHold: requiresCancelHold) {
            onCancelProgress?(nil)
            onCancel?()
        }
    }

    private func cancellationModifiers(from eventModifiers: HotkeyModifiers) -> HotkeyModifiers {
        var modifiers = eventModifiers
        let cancellationGroups = Settings.deviceIndependentModifiers(from: cancelBinding.modifiers)
        let groups: [(HotkeyModifiers, HotkeyModifiers)] = [
            (.command, [.command, .leftCommand, .rightCommand]),
            (.control, [.control, .leftControl, .rightControl]),
            (.option, [.option, .leftOption, .rightOption]),
            (.shift, [.shift, .leftShift, .rightShift]),
            (.function, [.function]),
        ]
        // A user holding their push-to-talk shortcut must still be able to
        // cancel. Ignore only those held recording modifiers that are not
        // themselves part of the cancellation shortcut.
        for binding in cachedBindings where binding.mode == .holdToRecord && activeBindingIDs.contains(binding.id) {
            let heldGroups = Settings.deviceIndependentModifiers(from: binding.modifiers)
            for (generic, allSides) in groups where heldGroups.contains(generic) && !cancellationGroups.contains(generic) {
                modifiers.subtract(allSides)
            }
        }
        return modifiers
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
        service.resetCancellationGesture()
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    if service.handleEvent(type: type, event: event) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
