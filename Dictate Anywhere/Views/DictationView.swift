import SwiftUI

struct DictationView: View {
    @Bindable var viewModel: DictationViewModel
    @State private var isButtonPressed = false

    var body: some View {
        VStack(spacing: 20) {
            // Status indicator
            statusView

            // Microphone selector
            microphoneSelector

            // Transcript area
            transcriptArea

            // Hold to dictate button
            dictateButton

            // Hint text
            hintText
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 360)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    // MARK: - Status View

    private var statusView: some View {
        HStack(spacing: 10) {
            statusIndicator

            Text(viewModel.state.statusText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
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
                .font(.system(size: 14))
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
                    HStack {
                        Text(mic.name)
                        if mic.isDefault {
                            Text("(Default)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .tag(Optional(mic))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .disabled(!isMicrophoneSelectionEnabled)
        .opacity(isMicrophoneSelectionEnabled ? 1 : 0.6)
    }

    private var isMicrophoneSelectionEnabled: Bool {
        switch viewModel.state {
        case .ready, .permissionsMissing:
            return true
        default:
            return false
        }
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        ScrollView {
            Text(viewModel.currentTranscript.isEmpty ? "Your transcription will appear here..." : viewModel.currentTranscript)
                .font(.body)
                .foregroundStyle(viewModel.currentTranscript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
    }

    // MARK: - Dictate Button

    private var dictateButton: some View {
        Button(action: {}) {
            HStack(spacing: 8) {
                Image(systemName: isButtonPressed ? "mic.fill" : "mic")
                    .font(.title3)
                    .symbolEffect(.bounce, value: isButtonPressed)
                Text(isButtonPressed ? "Release to Copy" : "Hold to Dictate")
                    .fontWeight(.medium)
            }
            .foregroundStyle(isButtonPressed ? .red : .blue)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background {
                Capsule()
                    .stroke(isButtonPressed ? Color.red : Color.blue, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isButtonPressed {
                        isButtonPressed = true
                        Task {
                            await viewModel.startDictation()
                        }
                    }
                }
                .onEnded { _ in
                    isButtonPressed = false
                    Task {
                        await viewModel.stopDictation()
                    }
                }
        )
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.5)
    }

    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        if case .listening = viewModel.state { return true }
        return false
    }

    // MARK: - Hint Text

    private var hintText: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
                .font(.caption)
            Text("Or press and hold")
            Text("fn")
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
            Text("key anywhere")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    DictationView(viewModel: DictationViewModel())
}
