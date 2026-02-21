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
    case general
    case shortcuts
    case transcription

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .models: return "Speech Model"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .transcription: return "Transcription"
        }
    }

    var icon: String {
        switch self {
        case .home: return "mic.fill"
        case .models: return "cpu"
        case .general: return "gear"
        case .shortcuts: return "command"
        case .transcription: return "text.bubble"
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
        case .general:
            GeneralSettingsView()
        case .shortcuts:
            ShortcutSettingsView()
        case .transcription:
            TranscriptionSettingsView()
        }
    }
}
