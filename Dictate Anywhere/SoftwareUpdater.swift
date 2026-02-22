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

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
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
