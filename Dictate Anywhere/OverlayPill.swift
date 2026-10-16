import SwiftUI

/// Shared presentation used by both the floating panel and settings.
struct OverlayPill: View {
    let model: OverlayModel
    var settings: Settings = .shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Measured height of the live text block; animated so the pill grows a line at a time.
    @State private var listeningHeight: CGFloat?

    private var state: OverlayState { model.overlayState }

    private var showTextPreview: Bool {
        settings.showTextPreview
    }

    private var palette: OverlayPalette { OverlayPalette(scheme: colorScheme) }
    private var overlayTextColor: Color { palette.text }

    private var stateCategory: String {
        switch state {
        case .listening: "listening"
        case .processing: "processing"
        case .success: "success"
        case .copiedOnly: "copiedOnly"
        case .preparingModel: "preparingModel"
        }
    }

    private var statusCircleDiameter: CGFloat {
        OverlayMetrics.size(48)
    }

    private var isCircularStatusState: Bool {
        if model.cancellationProgress != nil { return false }
        switch state {
        case .processing, .success:
            return true
        default:
            return false
        }
    }

    private var isTextPreview: Bool {
        model.cancellationProgress == nil && state == .listening && showTextPreview
    }

    private var statusBottomInset: CGFloat {
        isCircularStatusState ? 1 : 0
    }

    private var pillWidth: CGFloat {
        if model.cancellationProgress != nil { return OverlayMetrics.size(260) }
        switch state {
        case .listening:
            return showTextPreview ? settings.overlaySize.width : settings.overlaySize.waveformOnlyWidth
        case .processing, .success:
            return statusCircleDiameter
        case .copiedOnly:
            return OverlayMetrics.size(130)
        case .preparingModel:
            return OverlayMetrics.size(240)
        }
    }

    private var pillHeight: CGFloat {
        if model.cancellationProgress != nil { return OverlayMetrics.size(64) }
        switch state {
        case .listening:
            return showTextPreview
                ? listeningHeight ?? settings.overlaySize.minHeight
                : settings.overlaySize.waveformOnlyHeight
        case .processing, .success:
            return statusCircleDiameter
        case .copiedOnly:
            return OverlayMetrics.size(44)
        case .preparingModel:
            return OverlayMetrics.size(44)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pillContent
                .id(stateCategory)
                .transition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stateCategory)
        }
        .frame(width: pillWidth, height: pillHeight, alignment: isTextPreview ? .bottom : .center)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: settings.overlaySize)
        .modifier(OverlaySurfaceModifier(
            isCircular: isCircularStatusState,
            cornerRadius: isTextPreview ? settings.overlaySize.cornerRadius : OverlayMetrics.size(22)
        ))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: isCircularStatusState)
        .padding(.bottom, statusBottomInset)
        .onChange(of: isTextPreview) { _, isTextPreview in
            if !isTextPreview { listeningHeight = nil }
        }
    }

    private func updateListeningHeight(_ height: CGFloat) {
        guard abs((listeningHeight ?? 0) - height) > 0.5 else { return }
        if listeningHeight == nil || reduceMotion {
            listeningHeight = height
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { listeningHeight = height }
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        if let progress = model.cancellationProgress {
            CancellationProgressView(progress: progress, tint: overlayTextColor)
        } else {
            switch state {
            case .listening:
                ListeningOverlayContent(
                    model: model,
                    showTextPreview: showTextPreview,
                    textColor: overlayTextColor,
                    size: settings.overlaySize
                )
                .fixedSize(horizontal: false, vertical: showTextPreview)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if showTextPreview { updateListeningHeight(height) }
                }

            case .processing:
                ProcessingStatusView(tint: overlayTextColor)

            case .success:
                SuccessStatusView(tint: palette.success)

            case .copiedOnly:
                HStack(spacing: OverlayMetrics.size(10)) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: OverlayMetrics.type(16)))
                        .foregroundStyle(palette.accent)
                    Text("Press ⌘V")
                        .font(.system(size: OverlayMetrics.type(12), weight: .medium))
                        .foregroundStyle(overlayTextColor.opacity(0.9))
                }

            case .preparingModel(let name):
                HStack(spacing: OverlayMetrics.size(10)) {
                    ProcessingStatusView(tint: overlayTextColor)
                    Text("Loading \(name)…")
                        .font(.system(size: OverlayMetrics.type(12), weight: .medium))
                        .foregroundStyle(overlayTextColor.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, OverlayMetrics.size(14))
            }
        }
    }
}
