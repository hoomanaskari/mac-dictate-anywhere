//
//  OverlayContent.swift
//  Dictate Anywhere
//
//  SwiftUI content for overlay states.
//

import SwiftUI

/// Overlay display states
enum OverlayState: Equatable {
    case listening(level: Float, transcript: String)
    case processing
    case success
    case copiedOnly
}

struct OverlayContent: View {
    let state: OverlayState

    private var showTextPreview: Bool {
        Settings.shared.showTextPreview
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            contentForState
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: frameWidth, height: frameHeight)
    }

    private var frameWidth: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? 320 : 200
        case .copiedOnly:
            return 220
        default:
            return 180
        }
    }

    private var frameHeight: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? 140 : 60
        default:
            return 60
        }
    }

    @ViewBuilder
    private var contentForState: some View {
        switch state {
        case .listening(let level, let transcript):
            listeningContent(level: level, transcript: transcript)

        case .processing:
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(Color.accentColor)
                Text("Processing...")
                    .font(.system(size: 13, weight: .medium))
            }

        case .success:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 13, weight: .medium))
            }

        case .copiedOnly:
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                Text("Press Cmd+V")
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }

    @ViewBuilder
    private func listeningContent(level: Float, transcript: String) -> some View {
        let previewText = trimmedPreviewText(for: transcript)
        if showTextPreview {
            VStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(previewText)
                            .font(.system(size: 19, weight: .light))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .id("transcript")
                    }
                    .frame(height: 66)
                    .onChange(of: previewText) { _, _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("transcript", anchor: .bottom)
                        }
                    }
                }

                WaveformView(audioLevel: level)
            }
        } else {
            WaveformView(audioLevel: level)
        }
    }

    private func trimmedPreviewText(for transcript: String) -> String {
        guard !transcript.isEmpty else { return "Listening..." }
        let maxCharacters = 320
        guard transcript.count > maxCharacters else { return transcript }
        return "..." + String(transcript.suffix(maxCharacters))
    }
}
