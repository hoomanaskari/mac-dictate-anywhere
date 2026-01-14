import SwiftUI

struct PermissionsView: View {
    @Bindable var viewModel: DictationViewModel

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("Permissions Required")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Dictate Anywhere needs the following permissions to work")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                // Microphone permission
                permissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Required to capture your voice for transcription",
                    isGranted: viewModel.permissionChecker.hasMicrophonePermission,
                    action: {
                        Task {
                            await viewModel.requestMicrophonePermission()
                        }
                    }
                )

                Divider()
                    .background(.white.opacity(0.1))

                // Accessibility permission
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required to detect fn key press globally",
                    isGranted: viewModel.permissionChecker.hasAccessibilityPermission,
                    action: {
                        viewModel.openAccessibilitySettings()
                    }
                )
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }

            // Recheck button
            Button(action: {
                viewModel.recheckPermissions()
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Recheck Permissions")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .foregroundStyle(.blue)
                .background {
                    Capsule()
                        .stroke(.blue, lineWidth: 1.5)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isGranted ? .green : .secondary)
                .frame(width: 24)

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.medium)

                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action button
            if !isGranted {
                Button(action: action) {
                    Text(title == "Accessibility" ? "Open Settings" : "Grant")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(.blue)
                        .background {
                            Capsule()
                                .stroke(.blue, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    PermissionsView(viewModel: DictationViewModel())
}
