//
//  TranscriptHistoryView.swift
//  Dictate Anywhere
//
//  "History" page: local transcript history.
//

import AppKit
import SwiftUI

struct TranscriptHistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var showClearAllConfirm = false

    /// Matches the design's "Jul 15, 2026 · 5:54 PM" stamp.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return formatter
    }()

    static func filteredEntries(
        _ entries: [TranscriptHistoryEntry],
        searchText: String
    ) -> [TranscriptHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        @Bindable var settings = appState.settings
        let entries = Self.filteredEntries(
            Array(settings.transcriptHistory.reversed()),
            searchText: searchText
        )

        DSPage(spacing: 20) {
            DSSectionHeader(
                title: "History",
                subtitle: "Everything you've dictated, stored privately on this Mac."
            )

            HStack(spacing: 10) {
                DSSearchField(placeholder: "Search your dictations", text: $searchText)
                Button("Clear All…") {
                    showClearAllConfirm = true
                }
                .buttonStyle(.dsDestructive)
                .disabled(settings.transcriptHistory.isEmpty)
            }

            if entries.isEmpty {
                DSCard {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 26))
                            .foregroundStyle(DS.Colors.textSecondary)
                        Text(searchText.isEmpty ? "No Transcripts" : "No Matches")
                            .font(DS.Fonts.ui(14, .semibold))
                            .foregroundStyle(DS.Colors.ink)
                        Text(searchText.isEmpty
                             ? "Completed dictations will appear here."
                             : "No dictations match “\(searchText)”.")
                            .font(DS.Fonts.ui(12.5))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                }
            } else {
                DSCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            DSDivider()
                        }
                        TranscriptHistoryRow(
                            entry: entry,
                            onCopy: { copyToPasteboard(entry.text) },
                            onDelete: { settings.removeTranscriptHistoryEntry(id: entry.id) }
                        )
                    }
                }
            }
        }
        .alert("Clear all transcripts?", isPresented: $showClearAllConfirm) {
            Button("Clear All", role: .destructive) {
                settings.clearTranscriptHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove every transcript stored on this Mac.")
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct TranscriptHistoryRow: View {
    let entry: TranscriptHistoryEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(TranscriptHistoryView.dateFormatter.string(from: entry.createdAt))
                    .font(DS.Fonts.ui(11.5, .semibold))
                    .tracking(0.2)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(entry.text)
                    .font(DS.Fonts.ui(13.5))
                    .lineSpacing(13.5 * 0.55 - 4)
                    .foregroundStyle(DS.Colors.ink)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                DSInsetButton(title: "Copy", systemImage: "doc.on.doc", action: onCopy)
                DSIconButton(systemImage: "trash", accessibilityLabel: "Delete transcript", action: onDelete)
                    .help("Delete transcript")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}
