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
    private var hasStarted = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        if !hasStarted {
            try? updaterController.updater.start()
            hasStarted = true
        }
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
