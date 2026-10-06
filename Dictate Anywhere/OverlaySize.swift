import SwiftUI

/// A few useful reading sizes, shared by the panel and the settings sample.
enum OverlaySize: String, CaseIterable {
    case compact, comfortable, large

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .large: "Large"
        }
    }

    var width: CGFloat {
        switch self {
        case .compact: 190
        case .comfortable: 300
        case .large: 420
        }
    }

    var textHeight: CGFloat {
        switch self {
        case .compact: 48
        case .comfortable: 82
        case .large: 116
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .compact: 12
        case .comfortable: 14
        case .large: 16
        }
    }

    var waveformHeight: CGFloat {
        switch self {
        case .compact: 16
        case .comfortable: 22
        case .large: 28
        }
    }

    var waveformOnlyWidth: CGFloat { width * 0.48 }
    var height: CGFloat { textHeight + waveformHeight + 36 }
    var canvasSize: CGSize { CGSize(width: width + 40, height: max(130, height + 24)) }
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
