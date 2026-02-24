//
//  ShortcutsView.swift
//  Dictate Anywhere
//
//  Keyboard shortcut and dictation mode settings.
//

import SwiftUI

struct ShortcutsView: View {
    @Environment(AppState.self) private var appState

    @State private var shouldResumeMonitoringAfterRecording = false

    private let maxBindings = 5

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            Section {
                ForEach(settings.hotkeyBindings) { binding in
                    HotkeyBindingRow(
                        binding: binding,
                        allBindings: settings.hotkeyBindings,
                        canDelete: settings.hotkeyBindings.count > 1,
                        onRecord: { keyCode, modifiers, displayName in
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
            } header: {
                HStack {
                    Text("Keyboard Shortcuts")
                    Spacer()
                    if settings.hotkeyBindings.count < maxBindings {
                        Button {
                            _ = settings.addBinding()
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("Press any key combo, or press only modifiers (like \u{2303}\u{2325}\u{2318}) and release.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

// MARK: - Hotkey Binding Row

private struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    let allBindings: [HotkeyBinding]
    let canDelete: Bool
    let onRecord: (UInt16?, CGEventFlags, String) -> Void
    let onClear: () -> Void
    let onModeChanged: (HotkeyMode) -> Void
    let onDelete: () -> Void
    let onRecordingStarted: () -> Void
    let onRecordingStopped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(
                    get: { binding.mode },
                    set: { onModeChanged($0) }
                )) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                ShortcutRecorderView(
                    displayName: binding.displayName,
                    onRecord: onRecord,
                    onClear: onClear,
                    onRecordingStarted: onRecordingStarted,
                    onRecordingStopped: onRecordingStopped
                )

                if canDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
                }
            }

            // Conflict warnings
            if let internalWarning = ConflictDetector.internalConflict(for: binding, in: allBindings) {
                conflictLabel(internalWarning)
            }
            if let systemWarning = ConflictDetector.systemConflict(for: binding) {
                conflictLabel(systemWarning)
            }
        }
        .padding(.vertical, 4)
    }

    private func conflictLabel(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(.orange)
    }
}
