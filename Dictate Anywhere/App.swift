//
//  App.swift
//  Dictate Anywhere
//
//  Main entry point.
//

import SwiftUI

@main
struct DictateAnywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appState)
        }
        .defaultSize(width: MainWindowSizing.minimumWidth, height: MainWindowSizing.minimumHeight)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.softwareUpdater)
            }
        }
    }
}
