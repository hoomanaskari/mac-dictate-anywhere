import SwiftUI

/// Main content view for the floating overlay window
struct OverlayContentView: View {
    /// Current state of the overlay
    let state: OverlayState

    var body: some View {
        ZStack {
            // Semi-transparent rounded rectangle background
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

            // Content based on state
            contentForState
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: frameWidth, height: frameHeight)
    }

    /// Dynamic width based on state
    private var frameWidth: CGFloat {
        switch state {
        case .listening:
            return 320
        default:
            return 180
        }
    }

    /// Dynamic height based on state
    private var frameHeight: CGFloat {
        switch state {
        case .listening:
            return 140
        default:
            return 60
        }
    }

    /// Returns the appropriate content view for the current state
    @ViewBuilder
    private var contentForState: some View {
        switch state {
        case .loading:
            LoadingIndicatorView()

        case .listening(let level, let transcript):
            ListeningView(audioLevel: level, transcript: transcript)

        case .processing:
            ProcessingIndicatorView()

        case .success:
            SuccessIndicatorView()
        }
    }
}

/// View shown while listening - includes transcript and waveform
struct ListeningView: View {
    let audioLevel: Float
    let transcript: String

    var body: some View {
        VStack(spacing: 8) {
            // Live transcript text - auto-scrolls to show most recent words
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(transcript.isEmpty ? "Listening..." : transcript)
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .id("transcript")
                }
                .frame(height: 66)
                .onChange(of: transcript) { _, _ in
                    // Auto-scroll to bottom when transcript changes
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("transcript", anchor: .bottom)
                }
            }

            // Audio waveform
            AudioWaveformView(audioLevel: audioLevel)
        }
    }
}

// MARK: - State-Specific Views

/// Loading spinner shown while initializing microphone
struct LoadingIndicatorView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(.white)

            Text("Preparing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Processing indicator shown during transcription
struct ProcessingIndicatorView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(Color.accentColor)

            Text("Processing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Success checkmark shown before hiding
struct SuccessIndicatorView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)

            Text("Done")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - Previews

#Preview("Loading") {
    OverlayContentView(state: .loading)
        .background(.black)
}

#Preview("Listening - Empty") {
    OverlayContentView(state: .listening(level: 0.2, transcript: ""))
        .background(.black)
}

#Preview("Listening - With Text") {
    OverlayContentView(state: .listening(level: 0.6, transcript: "Hello, this is a test of the live transcription feature"))
        .background(.black)
}

#Preview("Processing") {
    OverlayContentView(state: .processing)
        .background(.black)
}

#Preview("Success") {
    OverlayContentView(state: .success)
        .background(.black)
}
