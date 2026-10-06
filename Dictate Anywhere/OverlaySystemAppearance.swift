import AppKit
import SwiftUI

/// Tracks macOS independently of the application's own appearance override.
@Observable
final class OverlaySystemAppearance: NSObject {
    static let shared = OverlaySystemAppearance()
    private(set) var colorScheme: ColorScheme

    override init() {
        colorScheme = Self.readColorScheme()
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(refresh),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func refresh() {
        colorScheme = Self.readColorScheme()
        NotificationCenter.default.post(name: .overlayPreferencesChanged, object: nil)
    }

    private static func readColorScheme() -> ColorScheme {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        return style == "Dark" ? .dark : .light
    }
}
