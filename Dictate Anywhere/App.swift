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
        .defaultSize(width: 680, height: 500)
    }
}
