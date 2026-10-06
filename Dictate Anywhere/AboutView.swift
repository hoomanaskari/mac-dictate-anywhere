//
//  AboutView.swift
//  Dictate Anywhere
//
//  "About" page with app info and open-source acknowledgements.
//

import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    var body: some View {
        DSPage {
            // Hero
            VStack(spacing: 14) {
                DSBrandMark(size: 76)
                VStack(spacing: 5) {
                    Text("Dictate Anywhere")
                        .font(DS.Fonts.display(30))
                        .foregroundStyle(DS.Colors.ink)
                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(DS.Fonts.ui(13))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                HStack(spacing: 5) {
                    Text("Made with care by")
                        .font(DS.Fonts.ui(13))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Link("Pixel Forty Inc.", destination: URL(string: "https://pixelforty.com")!)
                        .font(DS.Fonts.ui(13, .semibold))
                        .foregroundStyle(DS.Colors.accentDeep)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)

            DSSection(overline: "Open Source Acknowledgements") {
                LibraryRow(
                    name: "FluidAudio",
                    url: "https://github.com/FluidInference/FluidAudio",
                    license: "MIT License",
                    description: "On-device speech recognition powered by FluidAudio models."
                )
                DSDivider()
                LibraryRow(
                    name: "S1-mini by Superwhisper",
                    url: "https://huggingface.co/superwhisper/s1-mini",
                    license: "Apache 2.0 + naming term",
                    description: "Optional on-device model for English transcript normalization. Model files and license are downloaded separately at the user's request."
                )
                DSDivider()
                LibraryRow(
                    name: "llama.cpp / llama.swift",
                    url: "https://github.com/mattt/llama.swift",
                    license: "MIT License",
                    description: "Local inference runtime used by S1-mini by Superwhisper."
                )
                DSDivider()
                LibraryRow(
                    name: "Ollama",
                    url: "https://github.com/ollama/ollama",
                    license: "MIT License",
                    description: "Local LLM runtime used for optional transcript post-processing."
                )
                DSDivider()
                LibraryRow(
                    name: "Sparkle",
                    url: "https://github.com/sparkle-project/Sparkle",
                    license: "MIT License",
                    description: "Software update framework for macOS applications."
                )
            }

            HStack(spacing: 7) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.accentDeep)
                    .accessibilityHidden(true)
                Text("Built with the help of the open-source community. Thank you to all contributors.")
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LibraryRow: View {
    let name: String
    let url: String
    let license: String
    let description: String

    private var displayURL: String {
        url.replacingOccurrences(of: "https://", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(DS.Fonts.ui(13.5, .semibold))
                    .foregroundStyle(DS.Colors.ink)
                Text(description)
                    .font(DS.Fonts.ui(12.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: URL(string: url)!) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .medium))
                            .accessibilityHidden(true)
                        Text(displayURL)
                            .font(DS.Fonts.ui(12.5, .medium))
                    }
                    .foregroundStyle(DS.Colors.accentDeep)
                }
                .accessibilityLabel("\(name) project website")

            }
            Spacer(minLength: 0)
            DSChip(text: license)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}
