//
//  TranscriptionSettingsView.swift
//  Dictate Anywhere
//
//  Transcription settings: auto-stop, auto volume, filler removal, overlay.
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var newFillerWord = ""

    var body: some View {
        @Bindable var settings = appState.settings

        ScrollView {
            VStack(spacing: 24) {
                // Auto-Stop
                GroupBox("Auto-Stop") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Stop when speech ends", isOn: $settings.isAutoStopEnabled)

                        if settings.isAutoStopEnabled {
                            HStack {
                                Text("Silence threshold")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.1fs", settings.autoStopSilenceThreshold))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $settings.autoStopSilenceThreshold, in: 0.5...3.0, step: 0.1)

                            Text("How long to wait after speech stops before ending dictation.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                }

                // Auto Volume
                GroupBox("Auto Volume Adjustment") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Adjust volumes during recording", isOn: $settings.autoVolumeEnabled)

                        Text("Raises mic volume if too low and lowers system audio during dictation. Restores after recording.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                }

                // Filler Word Removal
                GroupBox("Filler Word Removal") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Remove filler words", isOn: $settings.isFillerWordRemovalEnabled)

                        if settings.isFillerWordRemovalEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Words to remove:")
                                    .font(.subheadline)

                                FlowLayout(spacing: 6) {
                                    ForEach(settings.fillerWordsToRemove, id: \.self) { word in
                                        HStack(spacing: 4) {
                                            Text(word)
                                                .font(.caption)
                                            Button {
                                                settings.fillerWordsToRemove.removeAll { $0 == word }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 8, weight: .bold))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                    }
                                }

                                HStack {
                                    TextField("Add word...", text: $newFillerWord)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { addFillerWord() }

                                    Button("Add") { addFillerWord() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(newFillerWord.trimmingCharacters(in: .whitespaces).isEmpty)
                                }

                                Button("Reset to Defaults") {
                                    settings.fillerWordsToRemove = Settings.defaultFillerWords
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                }

                // Overlay
                GroupBox("Overlay") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show text preview in overlay", isOn: $settings.showTextPreview)

                        Text("When enabled, the floating overlay shows live transcription text. When disabled, only the waveform is shown.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
        .navigationTitle("Transcription")
    }

    private func addFillerWord() {
        let word = newFillerWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !appState.settings.fillerWordsToRemove.contains(word) else { return }
        appState.settings.fillerWordsToRemove.append(word)
        newFillerWord = ""
    }
}

// MARK: - FlowLayout

/// Simple flow layout for displaying tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
