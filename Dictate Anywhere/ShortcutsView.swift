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

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            // MARK: - Keyboard Shortcut

            Section {
                ShortcutRecorderView(
                    displayName: settings.hotkeyDisplayName,
                    onRecord: { keyCode, modifiers, displayName in
                        settings.setHotkey(keyCode: keyCode, modifiers: modifiers, displayName: displayName)
                        appState.hotkeyService.restartMonitoring()
                        shouldResumeMonitoringAfterRecording = false
                    },
                    onClear: {
                        settings.clearHotkey()
                        appState.hotkeyService.stopMonitoring()
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
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Press any key combo, or press only modifiers (like \u{2303}\u{2325}\u{2318}) and release.")
            }

            // MARK: - Dictation Mode

            Section {
                Picker("Mode", selection: $settings.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Dictation Mode")
            } footer: {
                switch settings.hotkeyMode {
                case .holdToRecord:
                    Text("Hold your shortcut key to record. Release to stop and paste.")
                case .handsFreeToggle:
                    Text("Press once to start recording. Press again to stop. Press Escape to cancel.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}
