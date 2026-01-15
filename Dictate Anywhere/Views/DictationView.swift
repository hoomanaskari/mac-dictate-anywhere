import SwiftUI

struct DictationView: View {
    @Bindable var viewModel: DictationViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Status indicator
            statusView

            // Microphone selector
            microphoneSelector

            // Language indicator
            languageIndicator

            // Hint text
            hintText

            Spacer()

            Divider()
                .background(Color.white.opacity(0.1))

            // Bottom buttons
            VStack(spacing: 8) {
                modelsButton
                settingsButton
            }
        }
        .padding(24)
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        // Only show status indicator when not in ready state
        // Ready state doesn't need visual indication - everything is fine
        if case .ready = viewModel.state {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                statusIndicator

                Text(viewModel.state.statusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .shadow(color: statusColor.opacity(0.6), radius: 4)
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .ready:
            return .green
        case .listening:
            return .red
        case .processing:
            return .orange
        case .error:
            return .red
        default:
            return .secondary
        }
    }

    // MARK: - Microphone Selector

    private var microphoneSelector: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            Picker("Microphone", selection: Binding(
                get: { viewModel.microphoneManager.selectedMicrophone },
                set: { mic in
                    if let mic = mic {
                        viewModel.microphoneManager.selectMicrophone(mic)
                    }
                }
            )) {
                ForEach(viewModel.microphoneManager.availableMicrophones) { mic in
                    Text(microphoneDisplayName(for: mic))
                        .tag(Optional(mic))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .disabled(!isMicrophoneSelectionEnabled)
        .opacity(isMicrophoneSelectionEnabled ? 1 : 0.6)
    }

    private func microphoneDisplayName(for mic: MicrophoneManager.Microphone) -> String {
        if mic.isDefault {
            return "Default System Microphone"
        }
        return mic.name
    }

    private var isMicrophoneSelectionEnabled: Bool {
        switch viewModel.state {
        case .ready, .permissionsMissing:
            return true
        default:
            return false
        }
    }

    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        if case .listening = viewModel.state { return true }
        return false
    }

    // MARK: - Language Indicator

    private var languageIndicator: some View {
        let settings = SettingsManager.shared

        return HStack(spacing: 6) {
            Text(settings.selectedLanguage.flag)
                .font(.system(size: 14))

            Text(settings.selectedLanguage.displayName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
    }

    // MARK: - Hint Text

    private var hintText: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
                .font(.caption)
            Text("Press and hold")
            shortcutKeyView
            Text("anywhere to dictate")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var shortcutKeyView: some View {
        let settings = SettingsManager.shared

        if settings.isFnKeyEnabled && settings.isCustomShortcutEnabled && settings.hasCustomShortcut {
            // Both enabled - show both
            HStack(spacing: 4) {
                keyBadge("fn")
                Text("or")
                    .foregroundStyle(.secondary)
                keyBadge(settings.customShortcutDisplayName)
            }
        } else if settings.isFnKeyEnabled {
            // Only Fn enabled
            keyBadge("fn")
        } else if settings.isCustomShortcutEnabled && settings.hasCustomShortcut {
            // Only custom shortcut enabled
            keyBadge(settings.customShortcutDisplayName)
        } else {
            // Nothing enabled
            Text("(no shortcut)")
                .foregroundStyle(.red.opacity(0.8))
        }
    }

    private func keyBadge(_ text: String) -> some View {
        Text(text)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            }
    }

    // MARK: - Models Button

    private var modelsButton: some View {
        Button(action: {
            viewModel.showModelManagement()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "cube.box")
                    .font(.system(size: 14))

                Text("Speech Model")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.5)
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button(action: {
            viewModel.showSettings()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))

                Text("Settings")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.5)
    }
}

#Preview {
    DictationView(viewModel: DictationViewModel())
}
