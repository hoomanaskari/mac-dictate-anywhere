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

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appDelegate.appState)
        }
        .defaultSize(width: MainWindowSizing.defaultWidth, height: MainWindowSizing.defaultHeight)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Dictate Anywhere", action: appDelegate.showMainWindow)
            }
#if !DEBUG
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appDelegate.softwareUpdater)
            }
#endif
        }
    }
}
