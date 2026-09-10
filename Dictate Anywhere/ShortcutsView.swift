//
//  ShortcutsView.swift
//  Dictate Anywhere
//
//  "Shortcuts" page: keyboard shortcut and dictation mode settings.
//

import SwiftUI

struct ShortcutsView: View {
    @Environment(AppState.self) private var appState

    @State private var shouldResumeMonitoringAfterRecording = false
    @State private var shortcutError: String?

    private let maxBindings = 5

    var body: some View {
        @Bindable var settings = appState.settings

        DSPage {
            DSSectionHeader(
                title: "Shortcuts",
                subtitle: "Start and stop dictation from anywhere with a quick key press."
            )

            DSSection(overline: "Keyboard Shortcuts") {
                ForEach(Array(settings.hotkeyBindings.enumerated()), id: \.element.id) { index, binding in
                    if index > 0 {
                        DSDivider()
                    }
                    HotkeyBindingRow(
                        binding: binding,
                        allBindings: settings.hotkeyBindings,
                        canDelete: settings.hotkeyBindings.count > 1,
                        onRecord: { keyCode, modifiers, displayName in
                            var candidate = binding
                            candidate.keyCode = keyCode
                            candidate.modifiers = modifiers
                            if ConflictDetector.cancellationConflict(candidate, settings.cancelShortcut) {
                                shortcutError = "Choose a different combination from the cancel shortcut."
                                return
                            }
                            settings.updateBindingHotkey(
                                id: binding.id, keyCode: keyCode,
                                modifiers: modifiers, displayName: displayName
                            )
                            appState.hotkeyService.restartMonitoring()
                            shouldResumeMonitoringAfterRecording = false
                        },
                        onClear: {
                            settings.clearBindingHotkey(id: binding.id)
                            if !settings.hasHotkey {
                                appState.hotkeyService.stopMonitoring()
                            } else {
                                appState.hotkeyService.restartMonitoring()
                            }
                        },
                        onModeChanged: { newMode in
                            var updated = binding
                            updated.mode = newMode
                            settings.updateBinding(updated)
                            appState.hotkeyService.restartMonitoring()
                        },
                        onDelete: {
                            settings.removeBinding(id: binding.id)
                            if !settings.hasHotkey {
                                appState.hotkeyService.stopMonitoring()
                            } else {
                                appState.hotkeyService.restartMonitoring()
                            }
                        },
                        onRecordingStarted: {
                            shouldResumeMonitoringAfterRecording = appState.hotkeyService.isMonitoring
                            appState.hotkeyService.stopMonitoring()
                        },
                        onRecordingStopped: {
                            guard shouldResumeMonitoringAfterRecording else { return }
                            if settings.hasHotkey {
                                appState.hotkeyService.restartMonitoring()
                            }
                            shouldResumeMonitoringAfterRecording = false
                        }
                    )
                }
            }

            if settings.hotkeyBindings.count < maxBindings {
                DSAddButton(title: "Add another shortcut") {
                    _ = settings.addBinding()
                }
            }

            DSSection(overline: "Cancellation") {
                DSDetailRow(
                    label: "Cancel shortcut",
                    caption: "Choose a shortcut you won't use in other apps. Clear it to cancel only from the menu bar."
                ) {
                    ShortcutRecorderView(
                        displayName: settings.cancelShortcut.displayName,
                        onRecord: { keyCode, modifiers, displayName in
                            var candidate = settings.cancelShortcut
                            candidate.keyCode = keyCode
                            candidate.modifiers = modifiers
                            candidate.displayName = displayName
                            if settings.hotkeyBindings.contains(where: { ConflictDetector.cancellationConflict($0, candidate) }) {
                                shortcutError = "The cancel shortcut overlaps a start/stop shortcut. Choose another combination."
                                return
                            }
                            if let warning = ConflictDetector.systemConflict(for: candidate) {
                                shortcutError = warning
                                return
                            }
                            settings.cancelShortcut = candidate
                        },
                        onClear: {
                            settings.cancelShortcut.keyCode = nil
                            settings.cancelShortcut.modifiers = []
                            settings.cancelShortcut.displayName = ""
                            appState.hotkeyService.restartMonitoring()
                        },
                        onRecordingStarted: {
                            shouldResumeMonitoringAfterRecording = appState.hotkeyService.isMonitoring
                            appState.hotkeyService.stopMonitoring()
                        },
                        onRecordingStopped: {
                            if shouldResumeMonitoringAfterRecording || appState.permissions.accessibilityGranted {
                                appState.hotkeyService.restartMonitoring()
                            }
                            shouldResumeMonitoringAfterRecording = false
                        },
                        allowsEscape: true
                    )
                }
                DSDivider()
                DSStackedRow(
                    label: "Hold to cancel",
                    caption: "Hold the full cancel shortcut for one second. Releasing early keeps dictation running.",
                    isOn: $settings.holdToCancel
                )
                .onChange(of: settings.holdToCancel) { _, _ in
                    appState.hotkeyService.restartMonitoring()
                }
                DSDivider()
                DSStackedRow(
                    label: "Preserve cancelled sessions",
                    caption: "Keep cancelled sessions locally for 24 hours. Continue, recover text, or delete them in History. Changes apply to new dictations.",
                    isOn: $settings.preserveCancelledSessions
                )
            }

            DSPanel(
                text: "Press any key combo, or press only modifiers (like \u{2303}\u{2325}\u{2318}) and release. Left and right modifiers are supported — for example, R\u{2318} uses only the right Command key.",
                icon: "keyboard"
            )
        }
        .alert("Shortcut unavailable", isPresented: Binding(
            get: { shortcutError != nil }, set: { if !$0 { shortcutError = nil } }
        )) {
            Button("OK") { shortcutError = nil }
        } message: { Text(shortcutError ?? "") }
    }
}

// MARK: - Hotkey Binding Row

private struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    let allBindings: [HotkeyBinding]
    let canDelete: Bool
    let onRecord: (UInt16?, HotkeyModifiers, String) -> Void
    let onClear: () -> Void
    let onModeChanged: (HotkeyMode) -> Void
    let onDelete: () -> Void
    let onRecordingStarted: () -> Void
    let onRecordingStopped: () -> Void

    private var shortcutName: String {
        switch binding.mode {
        case .handsFreeToggle: return "Toggle dictation"
        case .holdToRecord: return "Hold to record"
        }
    }

    private var shortcutCaption: String {
        switch binding.mode {
        case .handsFreeToggle: return "Tap once to start, tap again to stop"
        case .holdToRecord: return "Hold the keys down while you speak"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcutName)
                        .font(DS.Fonts.ui(13.5, .medium))
                        .foregroundStyle(DS.Colors.ink)
                    Text(shortcutCaption)
                        .font(DS.Fonts.ui(12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                ShortcutRecorderView(
                    displayName: binding.displayName,
                    onRecord: onRecord,
                    onClear: onClear,
                    onRecordingStarted: onRecordingStarted,
                    onRecordingStopped: onRecordingStopped
                )

                if canDelete {
                    DSIconButton(systemImage: "trash", accessibilityLabel: "Remove shortcut", action: onDelete)
                        .help("Remove shortcut")
                }
            }
            .padding(16)

            ForEach(conflictMessages, id: \.self) { message in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.accentDeep)
                    Text(message)
                        .font(DS.Fonts.ui(12))
                        .foregroundStyle(DS.Colors.panelText)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            DSDivider()

            DSInfoRow(label: "Activation mode") {
                DSDropdown(
                    selection: Binding(
                        get: { binding.mode },
                        set: { onModeChanged($0) }
                    ),
                    options: HotkeyMode.allCases,
                    title: \.displayName
                )
            }
        }
    }

    private var conflictMessages: [String] {
        var messages: [String] = []
        if let internalWarning = ConflictDetector.internalConflict(for: binding, in: allBindings) {
            messages.append(internalWarning)
        }
        if let systemWarning = ConflictDetector.systemConflict(for: binding) {
            messages.append(systemWarning)
        }
        return messages
    }
}
