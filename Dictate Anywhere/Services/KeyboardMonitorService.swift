import Foundation
import AppKit
import Combine

@Observable
final class KeyboardMonitorService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let lock = NSLock()
    private var lastEventTimestamp: TimeInterval = 0
    private var isFnKeyDown = false

    var isHoldingFnKey: Bool = false

    // Callbacks for fn key events
    var onFnKeyDown: (() -> Void)?
    var onFnKeyUp: (() -> Void)?

    init() {}

    deinit {
        stopMonitoring()
    }

    /// Starts monitoring for fn key press/release events
    func startMonitoring() {
        // Global monitor for when app is NOT focused (requires Accessibility permission)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor for when app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    /// Stops monitoring for keyboard events
    func stopMonitoring() {
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        if let local = localMonitor {
            NSEvent.removeMonitor(local)
            localMonitor = nil
        }

        // Reset state
        lock.lock()
        isFnKeyDown = false
        lastEventTimestamp = 0
        lock.unlock()
        isHoldingFnKey = false
    }

    /// Handles flag change events to detect fn key
    private func handleFlagsChanged(_ event: NSEvent) {
        lock.lock()
        defer { lock.unlock() }

        // Check if fn key is currently pressed
        let fnPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.function)

        // Only trigger on state TRANSITIONS, not repeated events while held
        if fnPressed && !isFnKeyDown {
            // fn key just pressed down (transition from up to down)
            isFnKeyDown = true

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingFnKey = true
                self?.onFnKeyDown?()
            }
        } else if !fnPressed && isFnKeyDown {
            // fn key just released (transition from down to up)
            isFnKeyDown = false

            DispatchQueue.main.async { [weak self] in
                self?.isHoldingFnKey = false
                self?.onFnKeyUp?()
            }
        }
        // Ignore all other events (fn still held, or fn still released)
    }
}
