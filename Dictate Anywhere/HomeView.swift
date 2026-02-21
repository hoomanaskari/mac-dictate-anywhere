//
//  HomeView.swift
//  Dictate Anywhere
//
//  Main dictation page showing status, mic, hotkey, and engine info.
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            // Status
            Section("Status") {
                HStack(spacing: 16) {
                    statusIcon
                        .font(.system(size: 32))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(statusSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if appState.status == .idle && appState.activeEngine.isReady && appState.permissions.allGranted {
                        Button("Start Dictation") {
                            Task { await appState.startDictation() }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if appState.status == .recording {
                        Button("Stop") {
                            Task { await appState.stopDictation() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            }

            // Permissions
            if !appState.permissions.allGranted {
                Section("Permissions Required") {
                    if !appState.permissions.micGranted {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading) {
                                Text("Microphone").font(.subheadline.weight(.medium))
                                Text("Required for audio capture").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Grant") {
                                Task { await appState.permissions.requestMic() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if !appState.permissions.accessibilityGranted {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading) {
                                Text("Accessibility").font(.subheadline.weight(.medium))
                                Text("Required for global hotkeys and text insertion").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Grant") {
                                appState.permissions.openAccessibilitySettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            // Hotkey
            Section("Keyboard Shortcut") {
                HStack {
                    if appState.settings.hasHotkey {
                        Text(appState.settings.hotkeyDisplayName)
                            .font(.system(.title3, design: .rounded, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text(appState.settings.hotkeyMode.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No shortcut configured")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("Configure in Settings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Engine
            Section("Speech Engine") {
                HStack {
                    Image(systemName: appState.activeEngine.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(appState.activeEngine.isReady ? .green : .orange)

                    VStack(alignment: .leading) {
                        Text(appState.settings.engineChoice.displayName)
                            .font(.subheadline.weight(.medium))

                        if appState.activeEngine.isReady {
                            Text("Ready")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Model download required")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictate Anywhere")
        .task {
            await appState.permissions.check()
            if !appState.activeEngine.isReady {
                try? await appState.activeEngine.prepare()
            }
            if appState.permissions.accessibilityGranted && appState.settings.hasHotkey {
                appState.hotkeyService.startMonitoring()
            }
        }
    }

    // MARK: - Status Helpers

    @ViewBuilder
    private var statusIcon: some View {
        switch appState.status {
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundStyle(appState.activeEngine.isReady ? .green : .secondary)
        case .recording:
            Image(systemName: "waveform")
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative)
        case .processing:
            ProgressView()
                .scaleEffect(0.8)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var statusTitle: String {
        switch appState.status {
        case .idle:
            return appState.activeEngine.isReady ? "Ready" : "Not Ready"
        case .recording:
            return "Recording..."
        case .processing:
            return "Processing..."
        case .error(let msg):
            return msg
        }
    }

    private var statusSubtitle: String {
        switch appState.status {
        case .idle:
            if !appState.permissions.allGranted { return "Grant permissions to get started" }
            if !appState.activeEngine.isReady { return "Download or configure the speech model" }
            if !appState.settings.hasHotkey { return "Set up a keyboard shortcut" }
            return "Press your hotkey to start dictating"
        case .recording:
            return appState.currentTranscript.isEmpty ? "Listening..." : shortLivePreview(appState.currentTranscript)
        case .processing:
            return "Finishing transcription..."
        case .error:
            return "Try again or check settings"
        }
    }

    private func shortLivePreview(_ transcript: String) -> String {
        let maxCharacters = 180
        guard transcript.count > maxCharacters else { return transcript }
        return "..." + String(transcript.suffix(maxCharacters))
    }
}
