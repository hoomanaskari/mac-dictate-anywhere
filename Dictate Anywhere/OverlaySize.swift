import AppKit
import SwiftUI

/// A few useful reading sizes, shared by the panel and the settings sample.
enum OverlaySize: String, CaseIterable {
    case compact, comfortable, large

    /// Room below the pill so its shadow is not clipped by the panel edge.
    static let shadowInset: CGFloat = 10

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .large: "Large"
        }
    }

    /// Compact keeps the original overlay's footprint: 169 wide, 81 tall when full, ~10pt type.
    var width: CGFloat {
        switch self {
        case .compact: 169
        case .comfortable: 340
        case .large: 460
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .compact: 10.1
        case .comfortable: 13.5
        case .large: 15.3
        }
    }

    /// The pill grows one line at a time up to this many, then older lines scroll away.
    var maxLines: Int {
        switch self {
        case .compact: 2
        case .comfortable: 3
        case .large: 4
        }
    }

    var lineSpacing: CGFloat { (fontSize * 0.28).rounded() }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 10
        case .comfortable: 16
        case .large: 18
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 10
        case .comfortable: 12
        case .large: 13.5
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .compact: 14
        case .comfortable: 16
        case .large: 18
        }
    }

    var waveformHeight: CGFloat {
        switch self {
        case .compact: 16
        case .comfortable: 16
        case .large: 20
        }
    }

    var textWaveformSpacing: CGFloat { (fontSize * 0.9).rounded() }

    var font: Font { DS.Fonts.ui(fontSize) }

    var lineHeight: CGFloat {
        let font = NSFont(name: DS.Fonts.uiFamily, size: fontSize) ?? .systemFont(ofSize: fontSize)
        return NSLayoutManager().defaultLineHeight(for: font)
    }

    /// Exactly `maxLines` lines; more text than this counts as overflowing.
    var maxTextHeight: CGFloat {
        CGFloat(maxLines) * lineHeight + CGFloat(maxLines - 1) * lineSpacing
    }

    /// Once text overflows, half of the previous line peeks in above the full lines and fades out.
    var overflowPeekHeight: CGFloat { lineSpacing + lineHeight * 0.5 }
    var viewportMaxHeight: CGFloat { maxTextHeight + overflowPeekHeight }

    var minHeight: CGFloat { lineHeight + chromeHeight }
    var height: CGFloat { viewportMaxHeight + chromeHeight }
    private var chromeHeight: CGFloat { waveformHeight + textWaveformSpacing + verticalPadding * 2 }

    var waveformOnlyWidth: CGFloat { self == .compact ? 85 : width * 0.48 }
    var waveformOnlyHeight: CGFloat { self == .compact ? 29 : waveformHeight + 22 }
    var canvasSize: CGSize { CGSize(width: width + 40, height: max(130, height + 24 + Self.shadowInset)) }
    var characterLimit: Int {
        switch self {
        case .compact: 208
        case .comfortable: 400
        case .large: 640
        }
    }

    var sliderValue: Double {
        switch self {
        case .compact: 0
        case .comfortable: 1
        case .large: 2
        }
    }

    init(sliderValue: Double) {
        self = sliderValue < 0.5 ? .compact : sliderValue < 1.5 ? .comfortable : .large
    }
}
