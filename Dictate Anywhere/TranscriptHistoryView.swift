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
        let cancelledEntries = appState.recoveryStore.entries.filter {
            searchText.isEmpty || $0.preview.localizedCaseInsensitiveContains(searchText)
                || "Cancelled dictation".localizedCaseInsensitiveContains(searchText)
        }

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
                .disabled(settings.transcriptHistory.isEmpty && appState.recoveryStore.entries.isEmpty)
                .disabled(appState.recoveringEntryID != nil || appState.continuingEntryID != nil)
            }

            if !cancelledEntries.isEmpty {
                DSSection(overline: "Cancelled sessions") {
                    DSPanel(
                        text: "Continue restores your words and resumes recording. Stop finishes the combined dictation; if the original app is unavailable, the text is copied. Recover text saves it here without pasting. Sessions expire after 24 hours.",
                        icon: "arrow.counterclockwise"
                    )
                    ForEach(cancelledEntries) { entry in
                        DSDivider()
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Cancelled · \(Self.dateFormatter.string(from: entry.createdAt))")
                                    .font(DS.Fonts.ui(12, .semibold))
                                    .foregroundStyle(DS.Colors.ink)
                                Text(entry.preview.isEmpty ? "Audio saved for recovery" : entry.preview)
                                    .font(DS.Fonts.ui(13))
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .lineLimit(3)
                                Text("\(Int(entry.duration)) sec · Expires in \(entry.expiresAt, style: .relative)")
                                    .font(DS.Fonts.ui(11.5))
                                    .foregroundStyle(DS.Colors.textSecondary)
                                if entry.captureError != nil || (!entry.hasAudio && entry.completedTranscript == nil && entry.transcriptPrefix == nil) {
                                    Text("Partial recovery copy — some audio may be unavailable.")
                                        .font(DS.Fonts.ui(11.5))
                                        .foregroundStyle(DS.Colors.accentDeep)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(spacing: 8) {
                                Button(appState.continuingEntryID == entry.id
                                       ? (appState.recoveringEntryID == entry.id ? "Preparing…"
                                          : (appState.status == .recording ? "Stop" : "Finishing…"))
                                       : "Continue") {
                                    Task {
                                        if appState.continuingEntryID == entry.id { await appState.stopDictation() }
                                        else { await appState.continueCancelledDictation(entry) }
                                    }
                                }
                                .buttonStyle(.dsPrimary)
                                .disabled(appState.continuingEntryID == entry.id
                                          ? !appState.canStopDictation : appState.status != .idle)
                                Button(appState.recoveringEntryID == entry.id && appState.continuingEntryID == nil
                                       ? "Recovering…" : "Recover text") {
                                    Task { await appState.recoverCancelledDictation(entry) }
                                }
                                .buttonStyle(.plain)
                                .font(DS.Fonts.ui(11.5, .medium))
                                .foregroundStyle(DS.Colors.textSecondary)
                                .disabled(appState.status != .idle)
                            }
                            DSIconButton(systemImage: "trash", accessibilityLabel: "Delete cancelled session") {
                                do { try appState.recoveryStore.remove(id: entry.id) }
                                catch { appState.recoveryStore.errorMessage = error.localizedDescription }
                            }
                            .disabled(appState.recoveringEntryID == entry.id || appState.continuingEntryID == entry.id)
                        }
                        .padding(16)
                    }
                }
            }

            if entries.isEmpty && cancelledEntries.isEmpty {
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
            } else if !entries.isEmpty {
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
                do { try appState.recoveryStore.removeAll() }
                catch { appState.recoveryStore.errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove every transcript and cancelled recording stored on this Mac.")
        }
        .task {
            do { try appState.recoveryStore.reload() }
            catch { appState.recoveryStore.errorMessage = error.localizedDescription }
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
