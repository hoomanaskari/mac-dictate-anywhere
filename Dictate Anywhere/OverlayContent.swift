//
//  OverlayContent.swift
//  Dictate Anywhere
//
//  Pill-shaped overlay content for dictation states.
//

import SwiftUI

enum OverlayMetrics {
    static let footprintScale: CGFloat = 0.65
    static let typeScale: CGFloat = 0.78

    static func size(_ value: CGFloat) -> CGFloat {
        (value * footprintScale).rounded()
    }

    static func type(_ value: CGFloat) -> CGFloat {
        (value * typeScale * 10).rounded() / 10
    }
}

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
    @Environment(\.colorScheme) private var colorScheme

    private var state: OverlayState { model.overlayState }
    private var isVisible: Bool { model.isVisible }

    private var showTextPreview: Bool {
        Settings.shared.showTextPreview
    }

    private var overlayTextColor: Color {
        if #available(macOS 26, *) { return .white.opacity(0.95) }
        return .white
    }

    private var overlaySecondaryTextColor: Color {
        if #available(macOS 26, *) { return .white.opacity(0.82) }
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

    private var statusCircleDiameter: CGFloat {
        OverlayMetrics.size(48)
    }

    private var isCircularStatusState: Bool {
        switch state {
        case .processing, .success:
            return true
        default:
            return false
        }
    }

    private var statusBottomInset: CGFloat {
        isCircularStatusState ? 1 : 0
    }

    private var pillWidth: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? OverlayMetrics.size(260) : OverlayMetrics.size(130)
        case .processing, .success:
            return statusCircleDiameter
        case .copiedOnly:
            return OverlayMetrics.size(130)
        }
    }

    private var pillHeight: CGFloat {
        switch state {
        case .listening:
            return showTextPreview ? OverlayMetrics.size(124) : OverlayMetrics.size(44)
        case .processing, .success:
            return statusCircleDiameter
        case .copiedOnly:
            return OverlayMetrics.size(44)
        default:
            return OverlayMetrics.size(44)
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
                .padding(.bottom, statusBottomInset)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isVisible)
        }
        .frame(width: OverlayMetrics.size(320), height: OverlayMetrics.size(200))
    }

    private var pill: some View {
        VStack(spacing: 0) {
            pillContent
                .id(stateCategory)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: stateCategory)
        }
        .frame(width: pillWidth, height: pillHeight)
        .modifier(GlassPillModifier(isCircular: isCircularStatusState))
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isCircularStatusState)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch state {
        case .listening(let level, let transcript):
            listeningContent(level: level, transcript: transcript)

        case .processing:
            ProcessingStatusView(tint: overlayTextColor)

        case .success:
            SuccessStatusView()

        case .copiedOnly:
            HStack(spacing: OverlayMetrics.size(10)) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: OverlayMetrics.type(16)))
                    .foregroundStyle(.orange)
                Text("Press ⌘V")
                    .font(.system(size: OverlayMetrics.type(12), weight: .medium))
                    .foregroundStyle(overlayTextColor.opacity(0.9))
            }
        }
    }

    @ViewBuilder
    private func listeningContent(level: Float, transcript: String) -> some View {
        let previewText = trimmedPreviewText(for: transcript)
        if showTextPreview && !transcript.isEmpty {
            VStack(spacing: OverlayMetrics.size(6)) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(previewText)
                            .font(.system(size: OverlayMetrics.type(13), weight: .light))
                            .foregroundStyle(overlaySecondaryTextColor)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .id("transcript")
                    }
                    .frame(height: OverlayMetrics.size(66))
                    .onChange(of: previewText) { _, _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("transcript", anchor: .bottom)
                        }
                    }
                }
                .padding(.horizontal, OverlayMetrics.size(16))
                .padding(.top, OverlayMetrics.size(10))

                WaveformView(audioLevel: level)
                    .padding(.horizontal, OverlayMetrics.size(16))
                    .padding(.bottom, OverlayMetrics.size(8))
            }
        } else if showTextPreview {
            VStack {
                Spacer()
                WaveformView(audioLevel: level)
                    .padding(.horizontal, OverlayMetrics.size(16))
                    .padding(.bottom, OverlayMetrics.size(8))
            }
        } else {
            WaveformView(audioLevel: level)
                .padding(.horizontal, OverlayMetrics.size(20))
        }
    }

    private func trimmedPreviewText(for transcript: String) -> String {
        guard !transcript.isEmpty else { return "" }
        let maxCharacters = Int(320 * OverlayMetrics.footprintScale)
        guard transcript.count > maxCharacters else { return transcript }
        return "..." + String(transcript.suffix(maxCharacters))
    }
}

// MARK: - Glass pill background

private struct GlassPillModifier: ViewModifier {
    let isCircular: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isCircular {
            decorated(content: content, shape: Circle())
        } else {
            decorated(
                content: content,
                shape: RoundedRectangle(cornerRadius: OverlayMetrics.size(22), style: .continuous)
            )
        }
    }

    @ViewBuilder
    private func decorated<S: Shape>(content: Content, shape: S) -> some View {
        if #available(macOS 26, *) {
            // Keep a dark glass base in both themes so overlay text remains readable.
            let tint = colorScheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.24)
            let stroke = colorScheme == .dark ? Color.white.opacity(0.25) : Color.white.opacity(0.18)
            content
                .glassEffect(.regular.tint(tint), in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.black.opacity(0.85)))
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: OverlayMetrics.size(12), x: 0, y: OverlayMetrics.size(4))
        }
    }
}

private struct ProcessingStatusView: View {
    let tint: Color
    @State private var isAnimating = false

    private var ringSize: CGFloat {
        OverlayMetrics.size(24)
    }

    private var centerDotSize: CGFloat {
        OverlayMetrics.size(5)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.12), lineWidth: 1)

            Circle()
                .trim(from: 0.16, to: 0.82)
                .stroke(
                    tint.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round)
                )
                .rotationEffect(.degrees(isAnimating ? 360 : 0))

            Circle()
                .fill(tint.opacity(0.9))
                .frame(width: centerDotSize, height: centerDotSize)
        }
        .frame(width: ringSize, height: ringSize)
        .onAppear {
            guard !isAnimating else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

private struct SuccessStatusView: View {
    @State private var isRevealed = false

    private var ringSize: CGFloat {
        OverlayMetrics.size(24)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

            Circle()
                .stroke(Color.green.opacity(0.42), lineWidth: 1)
                .scaleEffect(isRevealed ? 1.28 : 0.72)
                .opacity(isRevealed ? 0 : 0.8)

            Circle()
                .trim(from: 0, to: isRevealed ? 1 : 0.12)
                .stroke(
                    Color.green.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: OverlayMetrics.type(18)))
                .foregroundStyle(.green)
                .scaleEffect(isRevealed ? 1 : 0.72)
                .opacity(isRevealed ? 1 : 0)
        }
        .frame(width: ringSize, height: ringSize)
        .onAppear {
            isRevealed = false
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                isRevealed = true
            }
        }
    }
}
