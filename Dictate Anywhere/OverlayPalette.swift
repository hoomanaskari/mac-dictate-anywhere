import SwiftUI

/// Opaque warm-neutral surfaces keep live text readable over any application.
struct OverlayPalette {
    let scheme: ColorScheme

    var surface: Color { Color(hex: scheme == .dark ? 0x24211F : 0xFFFCF7) }
    var text: Color { Color(hex: scheme == .dark ? 0xF5EFE7 : 0x302A25) }
    var secondaryText: Color { Color(hex: scheme == .dark ? 0xC0B4A7 : 0x6F6257) }
    var accent: Color { Color(hex: scheme == .dark ? 0xF3A777 : 0xAB502B) }
    var success: Color { Color(hex: scheme == .dark ? 0x8CCB9C : 0x39764B) }
    var border: Color { Color(hex: scheme == .dark ? 0x554B42 : 0xD9CABC) }
}
