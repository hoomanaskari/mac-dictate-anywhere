//
//  TextOverlayView.swift
//  Dictate Anywhere
//
//  Filler word removal and overlay settings.
//

import SwiftUI

struct TextOverlayView: View {
    @Environment(AppState.self) private var appState

    @State private var newFillerWord = ""

    var body: some View {
        @Bindable var settings = appState.settings

        Form {
            // MARK: - Filler Words

            Section {
                Toggle("Remove filler words", isOn: $settings.isFillerWordRemovalEnabled)

                if settings.isFillerWordRemovalEnabled {
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
                    .controlSize(.small)
                }
            } header: {
                Text("Filler Words")
            }

            // MARK: - Overlay

            Section {
                Toggle("Show text preview in overlay", isOn: $settings.showTextPreview)
            } header: {
                Text("Overlay")
            } footer: {
                Text("When enabled, the floating overlay shows live transcription text. When disabled, only the waveform is shown.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Text & Overlay")
    }

    private func addFillerWord() {
        let word = newFillerWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !appState.settings.fillerWordsToRemove.contains(word) else { return }
        appState.settings.fillerWordsToRemove.append(word)
        newFillerWord = ""
    }
}

// MARK: - FlowLayout

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
