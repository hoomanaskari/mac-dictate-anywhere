import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: DictationViewModel
    private let settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .background(Color.white.opacity(0.1))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Keyboard Shortcuts Section
                    keyboardShortcutsSection

                    // Overlay Section
                    overlaySection

                    Spacer()
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: {
                viewModel.hideSettings()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            // Invisible spacer for centering
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Back")
                    .font(.system(size: 13, weight: .medium))
            }
            .opacity(0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Keyboard Shortcuts Section

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Fn Key Toggle
            settingsRow(
                icon: "globe",
                title: "Fn Key",
                description: "Use the Fn/Globe key to activate dictation"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isFnKeyEnabled },
                    set: { settings.isFnKeyEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Custom Shortcut Toggle
            settingsRow(
                icon: "command",
                title: "Custom Shortcut",
                description: "Set a custom keyboard shortcut for dictation"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isCustomShortcutEnabled },
                    set: { settings.isCustomShortcutEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // Shortcut Recorder (shown when custom shortcut is enabled)
            if settings.isCustomShortcutEnabled {
                HStack {
                    Spacer()
                        .frame(width: 32) // Align with content above

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shortcut")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        ShortcutRecorderView()
                    }
                }
                .padding(.leading, 8)
            }

            // Warning if both are disabled
            if !settings.isFnKeyEnabled && !settings.isCustomShortcutEnabled {
                warningBanner
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Overlay Section

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            Text("Overlay")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            // Show Text Preview Toggle
            settingsRow(
                icon: "text.bubble",
                title: "Show Text Preview",
                description: "Display live transcription text in the overlay"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.showTextPreview },
                    set: { settings.showTextPreview = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    // MARK: - Settings Row

    private func settingsRow<Content: View>(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing()
        }
    }

    // MARK: - Warning Banner

    private var warningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)

            Text("No keyboard trigger is enabled. You won't be able to start dictation.")
                .font(.system(size: 12))
                .foregroundStyle(.orange.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                }
        }
    }
}

#Preview {
    SettingsView(viewModel: DictationViewModel())
}
