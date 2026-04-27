//
//  TranscriptHistoryView.swift
//  Dictate Anywhere
//
//  Local transcript history.
//

import AppKit
import SwiftUI

struct TranscriptHistoryView: View {
    @Environment(AppState.self) private var appState

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        @Bindable var settings = appState.settings
        let entries = Array(settings.transcriptHistory.reversed())

        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Transcripts",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed dictations will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            TranscriptHistoryRow(
                                entry: entry,
                                onCopy: { copyToPasteboard(entry.text) },
                                onDelete: { settings.removeTranscriptHistoryEntry(id: entry.id) }
                            )

                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button(role: .destructive) {
                settings.clearTranscriptHistory()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(settings.transcriptHistory.isEmpty)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(TranscriptHistoryView.dateFormatter.string(from: entry.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .help("Delete transcript")
            }

            Text(entry.text)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}
