//
//  GlassButtonStyles.swift
//  Dictate Anywhere
//
//  Created by Hooman on 1/15/26.
//

import SwiftUI

/// Helper extension to provide conditional button styles based on OS version
extension View {
    /// Applies the glass button style on macOS 26.0+, falls back to bordered style on older versions
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(self.buttonStyle(.glass))
        } else {
            return AnyView(self.buttonStyle(.bordered))
        }
    }
    
    /// Applies the glass prominent button style on macOS 26.0+, falls back to bordered prominent style on older versions
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            return AnyView(self.buttonStyle(.glassProminent))
        } else {
            return AnyView(self.buttonStyle(.borderedProminent))
        }
    }
}
