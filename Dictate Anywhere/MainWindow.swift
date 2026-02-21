//
//  MainWindow.swift
//  Dictate Anywhere
//
//  NavigationSplitView root with sidebar and detail.
//

import SwiftUI

enum SidebarPage: String, CaseIterable, Identifiable {
    case home
    case models
    case settings
    case shortcuts
    case textOverlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .models: return "Speech Model"
        case .settings: return "Settings"
        case .shortcuts: return "Shortcuts"
        case .textOverlay: return "Text & Overlay"
        }
    }

    var icon: String {
        switch self {
        case .home: return "mic.fill"
        case .models: return "cpu"
        case .settings: return "gear"
        case .shortcuts: return "command.square.fill"
        case .textOverlay: return "text.badge.checkmark"
        }
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPage: SidebarPage = .home

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedPage: $selectedPage)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPage {
        case .home:
            HomeView()
        case .models:
            ModelsView()
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsView()
        case .textOverlay:
            TextOverlayView()
        }
    }
}
