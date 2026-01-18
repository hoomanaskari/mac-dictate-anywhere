import SwiftUI

/// Main content view for the floating overlay window
struct OverlayContentView: View {
    /// Current state of the overlay
    let state: OverlayState

    /// Whether to show text preview (from settings)
    private var showTextPreview: Bool {
        SettingsManager.shared.showTextPreview
    }

    var body: some View {
        ZStack {
            // Semi-transparent rounded rectangle background
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AppTheme.borderProminent, lineWidth: 1)
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
            return showTextPreview ? 320 : 200
        case .listeningLowVolume:
            return 200
        case .copiedOnly:
            return 220
        default:
            return 180
        }
    }

    /// Dynamic height based on state
    private var frameHeight: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? 140 : 60
        case .listeningLowVolume:
            return 60
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
            ListeningView(audioLevel: level, transcript: transcript, showTextPreview: showTextPreview)

        case .listeningLowVolume(let level):
            LowVolumeWarningView(audioLevel: level)

        case .processing:
            ProcessingIndicatorView()

        case .success:
            SuccessIndicatorView()

        case .copiedOnly:
            CopiedOnlyIndicatorView()
        }
    }
}

/// View shown while listening - includes transcript and waveform
struct ListeningView: View {
    let audioLevel: Float
    let transcript: String
    let showTextPreview: Bool

    var body: some View {
        if showTextPreview {
            // Full view with transcript and waveform
            VStack(spacing: 8) {
                // Live transcript text - auto-scrolls to show most recent words
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(transcript.isEmpty ? "Listening..." : transcript)
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(AppTheme.textHighEmphasis)
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
        } else {
            // Compact view with waveform only
            AudioWaveformView(audioLevel: audioLevel)
        }
    }
}

/// Warning view shown when microphone volume is too low for reliable transcription
struct LowVolumeWarningView: View {
    let audioLevel: Float

    var body: some View {
        HStack(spacing: 12) {
            // Warning icon
            Image(systemName: "speaker.wave.1")
                .font(.system(size: 18))
                .foregroundStyle(.orange)

            // Warning text
            Text("Volume too low")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textHighEmphasis)

            Spacer()

            // Small waveform showing actual level
            AudioWaveformView(audioLevel: audioLevel)
                .frame(width: 40)
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
                .tint(.primary)

            Text("Preparing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textHighEmphasis)
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
                .foregroundStyle(AppTheme.textHighEmphasis)
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
                .foregroundStyle(AppTheme.textHighEmphasis)
        }
    }
}

/// Shown when text was copied but auto-paste failed
struct CopiedOnlyIndicatorView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 18))
                .foregroundStyle(.orange)

            Text("Press Cmd+V")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textHighEmphasis)
        }
    }
}

// MARK: - Previews

#Preview("Loading") {
    OverlayContentView(state: .loading)
        .appBackground()
}

#Preview("Listening - Empty") {
    OverlayContentView(state: .listening(level: 0.2, transcript: ""))
        .appBackground()
}

#Preview("Listening - With Text") {
    OverlayContentView(state: .listening(level: 0.6, transcript: "Hello, this is a test of the live transcription feature"))
        .appBackground()
}

#Preview("Listening - Compact (No Text)") {
    // Note: Toggle showTextPreview in SettingsManager to see this preview
    OverlayContentView(state: .listening(level: 0.5, transcript: ""))
        .appBackground()
}

#Preview("Low Volume Warning") {
    OverlayContentView(state: .listeningLowVolume(level: 0.05))
        .appBackground()
}

#Preview("Processing") {
    OverlayContentView(state: .processing)
        .appBackground()
}

#Preview("Success") {
    OverlayContentView(state: .success)
        .appBackground()
}

#Preview("Copied Only") {
    OverlayContentView(state: .copiedOnly)
        .appBackground()
}
