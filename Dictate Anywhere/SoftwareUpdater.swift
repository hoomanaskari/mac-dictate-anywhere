//
//  SoftwareUpdater.swift
//  Dictate Anywhere
//
//  Sparkle auto-update wrapper.
//

import Sparkle
import SwiftUI

@Observable
final class SoftwareUpdater {
    let updaterController: SPUStandardUpdaterController
    private let userDriverDelegate = SparkleUserDriverDelegate()

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

private final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    func standardUserDriverWillShowModalAlert() {
        bringSparkleWindowToFront()
    }

    func standardUserDriverDidShowModalAlert() {
        bringSparkleWindowToFront()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, for update: SUAppcastItem, state: SPUUserUpdateState) {
        bringSparkleWindowToFront()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restoreActivationPolicy()
    }

    private func bringSparkleWindowToFront() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func restoreActivationPolicy() {
        DispatchQueue.main.async {
            switch Settings.shared.appAppearanceMode {
            case .dockAndMenuBar:
                NSApp.setActivationPolicy(.regular)
            case .menuBarOnly:
                let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.level == .normal }
                NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
            }
        }
    }
}

struct CheckForUpdatesView: View {
    let updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
    }
}
