import Foundation
import CoreGraphics

/// A physical press, including its modifiers, must remain intact for the entire hold.
/// Key repeats never arm a new gesture after a release or a session change.
struct CancellationGesture {
    private(set) var startedAt: TimeInterval?
    private(set) var fired = false

    mutating func reset() {
        startedAt = nil
        fired = false
    }

    mutating func update(
        type: CGEventType, keyCode: UInt16, modifiers: HotkeyModifiers,
        isRepeat: Bool, binding: HotkeyBinding, now: TimeInterval
    ) {
        let modifiersMatch = Settings.modifierOnlyModifiersMatch(event: modifiers, target: binding.modifiers)
        if startedAt != nil {
            if !modifiersMatch || (type == .keyUp && keyCode == binding.keyCode) {
                reset()
            }
            return
        }
        guard binding.hasBinding, modifiersMatch, !isRepeat else { return }
        if let target = binding.keyCode {
            guard type == .keyDown, keyCode == target else { return }
        } else {
            guard type == .flagsChanged else { return }
        }
        startedAt = now
    }

    func progress(now: TimeInterval, requiresHold: Bool) -> Double? {
        guard let startedAt else { return nil }
        return requiresHold ? min(1, max(0, now - startedAt)) : 1
    }

    mutating func shouldCancel(now: TimeInterval, requiresHold: Bool) -> Bool {
        guard !fired, progress(now: now, requiresHold: requiresHold) == 1 else { return false }
        fired = true
        return true
    }
}
