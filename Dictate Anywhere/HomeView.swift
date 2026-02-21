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
        ScrollView {
            VStack(spacing: 24) {
                // Status card
                statusCard

                // Permission prompts
                if !appState.permissions.allGranted {
                    permissionsCard
                }

                // Hotkey info
                hotkeyCard

                // Engine status
                engineCard
            }
            .padding(24)
        }
        .navigationTitle("Dictate Anywhere")
        .task {
            await appState.permissions.check()
            // Auto-prepare engine if model is on disk
            if !appState.activeEngine.isReady {
                try? await appState.activeEngine.prepare()
            }
            // Start hotkey monitoring
            if appState.permissions.accessibilityGranted && appState.settings.hasHotkey {
                appState.hotkeyService.startMonitoring()
            }
        }
    }

    // MARK: - Status Card

    @ViewBuilder
    private var statusCard: some View {
        GroupBox {
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
            .padding(8)
        }
    }

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

    // MARK: - Permissions Card

    private var permissionsCard: some View {
        GroupBox("Permissions Required") {
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    title: "Microphone",
                    subtitle: "Required for audio capture",
                    granted: appState.permissions.micGranted,
                    action: {
                        if !appState.permissions.micGranted {
                            Task { await appState.permissions.requestMic() }
                        }
                    }
                )

                permissionRow(
                    title: "Accessibility",
                    subtitle: "Required for global hotkeys and text insertion",
                    granted: appState.permissions.accessibilityGranted,
                    action: { appState.permissions.openAccessibilitySettings() }
                )
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)

            VStack(alignment: .leading) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Hotkey Card

    private var hotkeyCard: some View {
        GroupBox("Keyboard Shortcut") {
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

                Text("Configure in Shortcuts settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
    }

    // MARK: - Engine Card

    private var engineCard: some View {
        GroupBox("Speech Engine") {
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
            .padding(8)
        }
    }
}
