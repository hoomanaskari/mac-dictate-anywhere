import SwiftUI

/// Opaque warm-neutral surfaces keep live text readable over any application.
struct OverlayPalette {
    let scheme: ColorScheme

    var surface: Color { Color(hex: scheme == .dark ? 0x1F1C1A : 0xFFFDFA) }
    var text: Color { Color(hex: scheme == .dark ? 0xF4EEE6 : 0x29241F) }
    var secondaryText: Color { Color(hex: scheme == .dark ? 0xA99D91 : 0x75685D) }
    var accent: Color { Color(hex: scheme == .dark ? 0xF3A777 : 0xAB502B) }
    var success: Color { Color(hex: scheme == .dark ? 0x8CCB9C : 0x39764B) }
    var border: Color { scheme == .dark ? Color(hex: 0x3B3530) : Color.black.opacity(0.09) }
    var highlight: Color { scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.05) }
}
