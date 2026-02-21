//
//  OverlayContent.swift
//  Dictate Anywhere
//
//  Pill-shaped overlay content for dictation states.
//

import SwiftUI

/// Overlay display states
enum OverlayState: Equatable {
    case listening(level: Float, transcript: String)
    case processing
    case success
    case copiedOnly
}

/// Observable model bridging OverlayWindow → SwiftUI
@Observable
final class OverlayModel {
    var overlayState: OverlayState = .listening(level: 0, transcript: "")
    var isVisible: Bool = false
}

struct OverlayContent: View {
    let model: OverlayModel

    private var state: OverlayState { model.overlayState }
    private var isVisible: Bool { model.isVisible }

    private var showTextPreview: Bool {
        Settings.shared.showTextPreview
    }

    private var overlayTextColor: Color {
        if #available(macOS 26, *) { return .primary }
        return .white
    }

    private var overlaySecondaryTextColor: Color {
        if #available(macOS 26, *) { return .secondary }
        return .white.opacity(0.85)
    }

    private var stateCategory: String {
        switch state {
        case .listening: "listening"
        case .processing: "processing"
        case .success: "success"
        case .copiedOnly: "copiedOnly"
        }
    }

    private var pillWidth: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? 260 : 130
        case .processing, .success, .copiedOnly:
            return 130
        }
    }

    private var pillHeight: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? 124 : 44
        default:
            return 44
        }
    }

    private var hasTranscript: Bool {
        if case .listening(_, let transcript) = state {
            return !transcript.isEmpty
        }
        return false
    }

    var body: some View {
        VStack {
            Spacer()

            pill
                .scaleEffect(isVisible ? 1.0 : 0.95)
                .opacity(isVisible ? 1.0 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isVisible)
        }
        .frame(width: 320, height: 200)
    }

    private var pill: some View {
        VStack(spacing: 0) {
            pillContent
                .id(stateCategory)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: stateCategory)
        }
        .frame(width: pillWidth, height: pillHeight)
        .modifier(GlassPillModifier())
    }

    @ViewBuilder
    private var pillContent: some View {
        switch state {
        case .listening(let level, let transcript):
            listeningContent(level: level, transcript: transcript)

        case .processing:
            HStack(spacing: 5) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(overlayTextColor)
                Text("Processing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(overlayTextColor.opacity(0.9))
            }

        case .success:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(overlayTextColor.opacity(0.9))
            }

        case .copiedOnly:
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                Text("Press ⌘V")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(overlayTextColor.opacity(0.9))
            }
        }
    }

    @ViewBuilder
    private func listeningContent(level: Float, transcript: String) -> some View {
        let previewText = trimmedPreviewText(for: transcript)
        if showTextPreview && !transcript.isEmpty {
            VStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(previewText)
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(overlaySecondaryTextColor)
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
                .padding(.horizontal, 16)
                .padding(.top, 10)

                WaveformView(audioLevel: level)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        } else if showTextPreview {
            VStack {
                Spacer()
                WaveformView(audioLevel: level)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        } else {
            WaveformView(audioLevel: level)
                .padding(.horizontal, 20)
        }
    }

    private func trimmedPreviewText(for transcript: String) -> String {
        guard !transcript.isEmpty else { return "" }
        let maxCharacters = 320
        guard transcript.count > maxCharacters else { return transcript }
        return "..." + String(transcript.suffix(maxCharacters))
    }
}

// MARK: - Glass pill background

private struct GlassPillModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(.black.opacity(0.3)), in: shape)
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.black.opacity(0.85)))
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
        }
    }
}
