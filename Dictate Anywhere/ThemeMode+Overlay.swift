import SwiftUI

extension ThemeMode {
    var overlayColorScheme: ColorScheme {
        switch self {
        case .system: OverlaySystemAppearance.shared.colorScheme
        case .light: .light
        case .dark: .dark
        }
    }
}
