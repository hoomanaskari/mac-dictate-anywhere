import Foundation
import AppKit
import Combine

@Observable
final class KeyboardMonitorService {
    // MARK: - Fn Key Monitors

    private var fnGlobalMonitor: Any?
    private var fnLocalMonitor: Any?

    // MARK: - Custom Shortcut Monitors (key-based)

    private var keyDownGlobalMonitor: Any?
    private var keyDownLocalMonitor: Any?
    private var keyUpGlobalMonitor: Any?
    private var keyUpLocalMonitor: Any?

    // MARK: - Custom Shortcut Monitors (modifier-only)

    private var modifierGlobalMonitor: Any?
    private var modifierLocalMonitor: Any?

    // MARK: - State

    private let lock = NSLock()
    private var lastEventTimestamp: TimeInterval = 0
    private var isFnKeyDown = false
    private var isCustomShortcutDown = false
    private var isModifierShortcutDown = false

    var isHoldingKey: Bool = false

    // Callbacks for key events (used by both Fn and custom shortcut)
    var onFnKeyDown: (() -> Void)?
    var onFnKeyUp: (() -> Void)?

    init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// Starts monitoring for keyboard events based on current settings
    func startMonitoring() {
        let settings = SettingsManager.shared

        // Set up Fn key monitoring if enabled
        if settings.isFnKeyEnabled {
            setupFnKeyMonitors()
        }

        // Set up custom shortcut monitoring if enabled and configured
        if settings.isCustomShortcutEnabled && settings.hasCustomShortcut {
            setupCustomShortcutMonitors()
        }
    }

    /// Stops all keyboard monitoring
    func stopMonitoring() {
        // Remove Fn key monitors
        if let monitor = fnGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            fnGlobalMonitor = nil
        }
        if let monitor = fnLocalMonitor {
            NSEvent.removeMonitor(monitor)
            fnLocalMonitor = nil
        }

        // Remove custom shortcut monitors (key-based)
        if let monitor = keyDownGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownGlobalMonitor = nil
        }
        if let monitor = keyDownLocalMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownLocalMonitor = nil
        }
        if let monitor = keyUpGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpGlobalMonitor = nil
        }
        if let monitor = keyUpLocalMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpLocalMonitor = nil
        }

        // Remove custom shortcut monitors (modifier-only)
        if let monitor = modifierGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierGlobalMonitor = nil
        }
        if let monitor = modifierLocalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierLocalMonitor = nil
        }

        // Reset state
        lock.lock()
        isFnKeyDown = false
        isCustomShortcutDown = false
        isModifierShortcutDown = false
        lastEventTimestamp = 0
        lock.unlock()
        isHoldingKey = false
    }

    // MARK: - Fn Key Monitoring

    private func setupFnKeyMonitors() {
        // Global monitor for when app is NOT focused (requires Accessibility permission)
        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor for when app IS focused
        fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    /// Handles flag change events to detect fn key
    private func handleFlagsChanged(_ event: NSEvent) {
        // Only process if Fn key is enabled in settings
        guard SettingsManager.shared.isFnKeyEnabled else { return }

        lock.lock()
        defer { lock.unlock() }

        // Check if fn key is currently pressed
        let fnPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.function)

        // Only trigger on state TRANSITIONS, not repeated events while held
        if fnPressed && !isFnKeyDown {
            // fn key just pressed down (transition from up to down)
            isFnKeyDown = true

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingKey = true
                self?.onFnKeyDown?()
            }
        } else if !fnPressed && isFnKeyDown {
            // fn key just released (transition from down to up)
            isFnKeyDown = false

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingKey = false
                self?.onFnKeyUp?()
            }
        }
    }

    // MARK: - Custom Shortcut Monitoring

    private func setupCustomShortcutMonitors() {
        let settings = SettingsManager.shared

        if settings.isModifierOnlyShortcut {
            // Modifier-only shortcut (e.g., Ctrl+Opt+Cmd)
            setupModifierOnlyMonitors()
        } else {
            // Key-based shortcut (e.g., Cmd+Shift+D)
            setupKeyBasedMonitors()
        }
    }

    // MARK: - Key-Based Shortcut Monitoring

    private func setupKeyBasedMonitors() {
        // Global monitors for when app is NOT focused
        keyDownGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        keyUpGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }

        // Local monitors for when app IS focused
        keyDownLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        keyUpLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
            return event
        }
    }

    /// Handles key down events for custom shortcut detection
    private func handleKeyDown(_ event: NSEvent) {
        let settings = SettingsManager.shared

        // Only process if custom shortcut is enabled and configured (key-based)
        guard settings.isCustomShortcutEnabled,
              !settings.isModifierOnlyShortcut,
              let targetKeyCode = settings.customShortcutKeyCode else { return }

        lock.lock()
        defer { lock.unlock() }

        // Check if this key matches our shortcut
        let keyMatches = event.keyCode == targetKeyCode

        // Check modifiers - if no modifiers required, any modifier state is fine
        // If modifiers required, they must match exactly
        let requiredModifiers = settings.customShortcutModifiers.intersection(.deviceIndependentFlagsMask)
        let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        let modifiersMatch: Bool
        if requiredModifiers.isEmpty {
            // No modifiers required - just check the key (but ignore if command/ctrl/option held)
            // Allow shift as it might be part of the character
            let hasBlockingModifiers = eventModifiers.contains(.command) ||
                                       eventModifiers.contains(.control) ||
                                       eventModifiers.contains(.option)
            modifiersMatch = !hasBlockingModifiers
        } else {
            // Modifiers required - must contain all required modifiers
            modifiersMatch = eventModifiers.contains(requiredModifiers)
        }

        if keyMatches && modifiersMatch && !isCustomShortcutDown {
            isCustomShortcutDown = true

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingKey = true
                self?.onFnKeyDown?()
            }
        }
    }

    /// Handles key up events for custom shortcut detection
    private func handleKeyUp(_ event: NSEvent) {
        let settings = SettingsManager.shared

        // Only process if custom shortcut is enabled and configured (key-based)
        guard settings.isCustomShortcutEnabled,
              !settings.isModifierOnlyShortcut,
              let targetKeyCode = settings.customShortcutKeyCode else { return }

        lock.lock()
        defer { lock.unlock() }

        // Check if this is the key we're tracking
        if event.keyCode == targetKeyCode && isCustomShortcutDown {
            isCustomShortcutDown = false

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingKey = false
                self?.onFnKeyUp?()
            }
        }
    }

    // MARK: - Modifier-Only Shortcut Monitoring

    private func setupModifierOnlyMonitors() {
        // Global monitor for when app is NOT focused
        modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierShortcut(event)
        }

        // Local monitor for when app IS focused
        modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierShortcut(event)
            return event
        }
    }

    /// Handles modifier-only shortcut detection (e.g., Ctrl+Opt+Cmd)
    private func handleModifierShortcut(_ event: NSEvent) {
        let settings = SettingsManager.shared

        // Only process if custom shortcut is enabled and is modifier-only
        guard settings.isCustomShortcutEnabled,
              settings.isModifierOnlyShortcut else { return }

        lock.lock()
        defer { lock.unlock() }

        let requiredModifiers = settings.customShortcutModifiers.intersection([.control, .option, .shift, .command])
        let currentModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])

        // Check if all required modifiers are currently pressed
        let allModifiersPressed = currentModifiers.contains(requiredModifiers)

        if allModifiersPressed && !isModifierShortcutDown {
            // All required modifiers just pressed - start dictation
            isModifierShortcutDown = true

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingKey = true
                self?.onFnKeyDown?()
            }
        } else if !allModifiersPressed && isModifierShortcutDown {
            // One or more required modifiers released - stop dictation
            isModifierShortcutDown = false

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingKey = false
                self?.onFnKeyUp?()
            }
        }
    }
}
