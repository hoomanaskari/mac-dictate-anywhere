import SwiftUI
import AppKit

struct ShortcutRecorderView: View {
    @State private var isRecording = false
    @State private var keyDownMonitor: Any?
    @State private var flagsChangedMonitor: Any?
    @State private var currentModifiers: NSEvent.ModifierFlags = []
    @State private var lastValidModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        HStack(spacing: 12) {
            // Shortcut display / record button
            Button(action: {
                if isRecording {
                    stopRecording(save: false)
                } else {
                    startRecording()
                }
            }) {
                HStack(spacing: 8) {
                    if isRecording {
                        // Recording indicator
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)

                        if !currentModifiers.isEmpty {
                            // Show modifiers being held
                            Text(SettingsManager.displayNameForModifiers(currentModifiers))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text("+ key or release")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Press keys...")
                                .foregroundStyle(.primary)
                        }
                    } else if SettingsManager.shared.hasCustomShortcut {
                        // Show current shortcut
                        Text(SettingsManager.shared.customShortcutDisplayName)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                    } else {
                        // No shortcut set
                        Text("Click to record")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 140, minHeight: 28)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.red.opacity(0.1) : Color.white.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecording ? Color.red.opacity(0.5) : Color.white.opacity(0.2), lineWidth: 1)
                        }
                }
            }
            .buttonStyle(.plain)

            // Clear button (only shown when shortcut is set and not recording)
            if SettingsManager.shared.hasCustomShortcut && !isRecording {
                Button(action: {
                    SettingsManager.shared.clearCustomShortcut()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear {
            stopRecording(save: false)
        }
    }

    // MARK: - Recording Methods

    private func startRecording() {
        isRecording = true
        currentModifiers = []
        lastValidModifiers = []

        // Monitor key down events for regular keys
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            return nil // Consume the event
        }

        // Monitor flags changed for modifier keys
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    private func stopRecording(save: Bool) {
        if save && isValidModifierCombo(lastValidModifiers) {
            // Save modifier-only shortcut
            SettingsManager.shared.setModifierOnlyShortcut(modifiers: lastValidModifiers)
        }

        isRecording = false
        currentModifiers = []
        lastValidModifiers = []

        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Escape cancels recording without setting shortcut
        if event.keyCode == 53 { // Escape
            stopRecording(save: false)
            return
        }

        // Record key + modifiers shortcut
        SettingsManager.shared.setCustomShortcut(from: event)
        stopRecording(save: false)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let newModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let relevantModifiers = newModifiers.intersection([.control, .option, .shift, .command])

        // Update current display
        currentModifiers = relevantModifiers

        // Only update lastValidModifiers if we have MORE modifiers than before
        // This ensures we capture the peak combination, not intermediate release states
        let currentCount = modifierCount(relevantModifiers)
        let lastCount = modifierCount(lastValidModifiers)

        if currentCount > lastCount && isValidModifierCombo(relevantModifiers) {
            lastValidModifiers = relevantModifiers
        }

        // If user had a valid combo and released all modifiers, save it
        if relevantModifiers.isEmpty && isValidModifierCombo(lastValidModifiers) {
            stopRecording(save: true)
        }
    }

    /// Returns the number of modifiers in the flags
    private func modifierCount(_ modifiers: NSEvent.ModifierFlags) -> Int {
        var count = 0
        if modifiers.contains(.control) { count += 1 }
        if modifiers.contains(.option) { count += 1 }
        if modifiers.contains(.shift) { count += 1 }
        if modifiers.contains(.command) { count += 1 }
        return count
    }

    /// Returns true if the modifier combination is valid (1-3 modifiers)
    private func isValidModifierCombo(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        let count = modifierCount(modifiers)
        return count >= 1 && count <= 3
    }
}

#Preview {
    VStack(spacing: 20) {
        ShortcutRecorderView()

        Divider()

        VStack(alignment: .leading, spacing: 4) {
            Text("Tips:")
                .font(.caption.bold())
            Text("• Press modifier + key (e.g., ⌘⇧D)")
            Text("• Or hold 2+ modifiers and release (e.g., ⌃⌥⌘)")
            Text("• Press Escape to cancel")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 320)
    .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
}
