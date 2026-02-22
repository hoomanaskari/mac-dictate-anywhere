//
//  AboutView.swift
//  Dictate Anywhere
//
//  About page with app info and open-source acknowledgements.
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
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)

                    Text("Dictate Anywhere")
                        .font(.title.bold())

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 0) {
                        Text("Created by ")
                            .foregroundStyle(.secondary)
                        Link("Pixel Forty Inc.", destination: URL(string: "https://pixelforty.com")!)
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                LibraryRow(
                    name: "FluidAudio",
                    url: "https://github.com/FluidInference/FluidAudio",
                    license: "MIT License",
                    description: "On-device speech recognition powered by Parakeet models."
                )
                LibraryRow(
                    name: "Sparkle",
                    url: "https://github.com/sparkle-project/Sparkle",
                    license: "MIT License",
                    description: "Software update framework for macOS applications."
                )
            } header: {
                Text("Open Source Acknowledgements")
            } footer: {
                Text("This app is built with the help of the open-source community. Thank you to all contributors.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}

private struct LibraryRow: View {
    let name: String
    let url: String
    let license: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.headline)
                Spacer()
                Text(license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(url, destination: URL(string: url)!)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
