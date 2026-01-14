//
//  Dictate_AnywhereApp.swift
//  Dictate Anywhere
//
//  Created by Hooman on 1/14/26.
//

import SwiftUI

@main
struct Dictate_AnywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel = DictationViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.initialize()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 500)
    }
}
