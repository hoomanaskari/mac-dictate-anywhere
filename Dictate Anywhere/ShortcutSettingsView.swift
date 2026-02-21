//
//  ShortcutSettingsView.swift
//  Dictate Anywhere
//
//  Hotkey configuration: recorder widget + mode picker.
//

import SwiftUI

struct ShortcutSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var shouldResumeMonitoringAfterRecording = false

    var body: some View {
        @Bindable var settings = appState.settings

        ScrollView {
            VStack(spacing: 24) {
                // Shortcut Recorder
                GroupBox("Keyboard Shortcut") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Press any key combo, or press only modifiers (like ⌃⌥⌘) and release.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

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
                    }
                    .padding(8)
                }

                // Mode Picker
                GroupBox("Dictation Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $settings.hotkeyMode) {
                            ForEach(HotkeyMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch settings.hotkeyMode {
                        case .holdToRecord:
                            Text("Hold your shortcut key to record. Release to stop and paste.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        case .handsFreeToggle:
                            Text("Press once to start recording. Press again or stop speaking to stop. Press Escape to cancel.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
        .navigationTitle("Shortcuts")
    }
}
