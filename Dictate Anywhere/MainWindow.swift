//
//  MainWindow.swift
//  Dictate Anywhere
//
//  Root layout: custom design-system sidebar + detail page.
//

import SwiftUI

enum SidebarPage: String, CaseIterable, Identifiable {
    case models
    case settings
    case shortcuts
    case textOverlay
    case aiPostProcessing
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Speech Model"
        case .settings: return "General"
        case .shortcuts: return "Shortcuts"
        case .textOverlay: return "Text & Overlay"
        case .aiPostProcessing: return "Transcript Cleanup"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .models: return "cpu"
        case .settings: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .textOverlay: return "textformat"
        case .aiPostProcessing: return "wand.and.stars"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

struct WarningBanner: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.accentDeep)
            Text(message)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.panelText)
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.dsSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DS.Colors.accentSoft)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.border)
                .frame(height: 1)
        }
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 0) {
            SidebarView(selectedPage: $appState.selectedPage)

            VStack(spacing: 0) {
                if !appState.permissions.accessibilityGranted {
                    WarningBanner(
                        message: "Accessibility permission is required for keyboard shortcuts.",
                        buttonTitle: "Grant Permission"
                    ) {
                        appState.permissions.promptForAccessibility()
                    }
                }

                if !appState.activeEngine.isReady && !appState.isPreparingEngine {
                    WarningBanner(
                        message: appState.settings.engineChoice == .appleSpeech
                            ? "Apple Speech needs to finish its on-device setup before you can dictate."
                            : "A speech model is required to start dictating. Download one now.",
                        buttonTitle: "Set Up"
                    ) {
                        appState.selectedPage = .models
                    }
                }

                detailView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.bgWindow)
        .preferredColorScheme(.light)
        .frame(
            minWidth: MainWindowSizing.minimumWidth,
            maxWidth: .infinity,
            minHeight: MainWindowSizing.minimumHeight,
            maxHeight: .infinity
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedPage {
        case .models:
            ModelsView()
        case .settings:
            SettingsView()
        case .shortcuts:
            ShortcutsView()
        case .textOverlay:
            TextOverlayView()
        case .aiPostProcessing:
            AIPostProcessingView()
        case .history:
            TranscriptHistoryView()
        case .about:
            AboutView()
        }
    }
}
