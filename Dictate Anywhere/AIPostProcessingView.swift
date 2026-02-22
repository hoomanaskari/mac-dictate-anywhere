//
//  AIPostProcessingView.swift
//  Dictate Anywhere
//
//  AI post-processing settings page.
//

import SwiftUI
import FoundationModels

struct AIPostProcessingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            if #available(macOS 26, *) {
                availableContent(settings: settings)
            } else {
                Section {
                    Label {
                        Text("Requires macOS 26 or later")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("AI Post Processing uses Apple Intelligence, which requires macOS 26 or later.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Post Processing")
    }

    @available(macOS 26, *)
    @ViewBuilder
    private func availableContent(settings: Settings) -> some View {
        let availability = AIPostProcessingService.availability

        switch availability {
        case .available:
            @Bindable var settings = settings

            Section {
                Toggle("Enable AI post-processing", isOn: $settings.aiPostProcessingEnabled)
            } footer: {
                Text("When enabled, transcribed text is processed by Apple Intelligence before pasting.")
            }

            if settings.aiPostProcessingEnabled {
                Section {
                    TextField(
                        "",
                        text: $settings.aiPostProcessingPrompt,
                        prompt: Text("Enter your prompt, e.g. \"Break into sentences, fix grammar, and remove filler words.\""),
                        axis: .vertical
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .lineLimit(3...)
                    .frame(minHeight: 80, alignment: .topLeading)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("This prompt tells the AI how to transform your transcribed text. The transcribed text is appended after your prompt.")
                }
            }

        case .unavailable(.deviceNotEligible):
            Section {
                Label {
                    Text("Your Mac doesn't support Apple Intelligence")
                } icon: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("AI Post Processing requires a Mac that supports Apple Intelligence.")
            }

        case .unavailable(.appleIntelligenceNotEnabled):
            Section {
                Label {
                    Text("Apple Intelligence is not enabled")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Open Apple Intelligence Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Enable Apple Intelligence in System Settings to use AI Post Processing.")
            }

        case .unavailable(.modelNotReady):
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Intelligence model is downloading...")
                        ProgressView()
                            .controlSize(.small)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
            } footer: {
                Text("The on-device model is being prepared. This may take a few minutes.")
            }

        case .unavailable(_):
            Section {
                Label {
                    Text("Apple Intelligence is currently unavailable")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Try again later.")
            }
        }
    }
}
