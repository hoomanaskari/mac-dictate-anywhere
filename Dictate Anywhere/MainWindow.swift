//
//  MainWindow.swift
//  Dictate Anywhere
//
//  NavigationSplitView root with sidebar and detail.
//

import SwiftUI

enum SidebarPage: String, CaseIterable, Identifiable {
    case models
    case settings
    case shortcuts
    case textOverlay
    case aiPostProcessing
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return "Speech Model"
        case .settings: return "Settings"
        case .shortcuts: return "Shortcuts"
        case .textOverlay: return "Text & Overlay"
        case .aiPostProcessing: return "AI Post Processing"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .models: return "cpu"
        case .settings: return "gear"
        case .shortcuts: return "command.square.fill"
        case .textOverlay: return "text.badge.checkmark"
        case .aiPostProcessing: return "wand.and.stars"
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
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.1))
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

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
                    message: "Parakeet model is required to start dictating. Download it now.",
                    buttonTitle: "Set Up"
                ) {
                    appState.selectedPage = .models
                }
            }

            NavigationSplitView {
                SidebarView(selectedPage: $appState.selectedPage)
            } detail: {
                detailView
            }
        }
        .frame(width: 680, height: 560)
        .task {
            await appState.permissions.check()
            await appState.prepareActiveEngine()
            if appState.permissions.accessibilityGranted {
                if appState.settings.hasHotkey {
                    appState.hotkeyService.startMonitoring()
                }
            } else {
                // Trigger the system prompt to add the app to the Accessibility list
                appState.permissions.promptForAccessibility()
                appState.permissions.startPolling()
            }
        }
        .onChange(of: appState.permissions.accessibilityGranted) { _, granted in
            if granted {
                appState.permissions.stopPolling()
                if appState.settings.hasHotkey && !appState.hotkeyService.isMonitoring {
                    appState.hotkeyService.startMonitoring()
                }
            } else {
                appState.hotkeyService.stopMonitoring()
                appState.permissions.startPolling()
            }
        }
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
        case .about:
            AboutView()
        }
    }
}
