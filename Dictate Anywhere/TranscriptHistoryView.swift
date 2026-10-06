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

    /// Uses the Mac's date order and preferred 12- or 24-hour clock.
    static let timestampFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func filteredEntries(
        _ entries: [TranscriptHistoryEntry],
        searchText: String
    ) -> [TranscriptHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.rawText?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        @Bindable var settings = appState.settings
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = Self.filteredEntries(
            Array(settings.transcriptHistory.reversed()),
            searchText: query
        )
        let cancelledEntries = appState.recoveryStore.entries.filter {
            query.isEmpty || $0.preview.localizedCaseInsensitiveContains(query)
                || "Cancelled dictation".localizedCaseInsensitiveContains(query)
        }

        DSPage(spacing: 20) {
            DSSectionHeader(
                title: "History",
                subtitle: "Everything you've dictated, stored privately on this Mac."
            )

            HStack(spacing: 10) {
                DSSearchField(
                    placeholder: "Search your dictations", text: $searchText,
                    accessibilityName: "Search transcript history"
                )
                Button("Clear All…") {
                    showClearAllConfirm = true
                }
                .buttonStyle(.dsDestructive)
                .disabled(settings.transcriptHistory.isEmpty && appState.recoveryStore.entries.isEmpty)
                .disabled(appState.recoveringEntryID != nil || appState.continuingEntryID != nil)
            }

            if !cancelledEntries.isEmpty {
                DSSection(overline: "Cancelled sessions") {
                    DSHint(
                        text: "Continue restores your words and resumes recording. Stop finishes the combined dictation; if the original app is unavailable, the text is copied. Recover text saves it here without pasting. Sessions expire after 24 hours.",
                        icon: "arrow.counterclockwise"
                    )
                    .padding(.vertical, 12)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    ForEach(cancelledEntries) { entry in
                        DSDivider()
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Cancelled · \(entry.createdAt.formatted(Self.timestampFormat))")
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
                                    DSFieldMessage(
                                        text: "Partial recovery copy — some audio may be unavailable.",
                                        tone: .warning
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(spacing: 8) {
                                let continueTitle = appState.continuingEntryID == entry.id
                                    ? (appState.recoveringEntryID == entry.id ? "Preparing…"
                                       : (appState.status == .recording ? "Stop" : "Finishing…"))
                                    : "Continue"
                                let recoverTitle = appState.recoveringEntryID == entry.id && appState.continuingEntryID == nil
                                    ? "Recovering…" : "Recover text"
                                Button(continueTitle) {
                                    Task {
                                        if appState.continuingEntryID == entry.id { await appState.stopDictation() }
                                        else { await appState.continueCancelledDictation(entry) }
                                    }
                                }
                                .buttonStyle(.dsPrimary)
                                .accessibilityLabel("\(continueTitle) cancelled session from \(entry.createdAt.formatted(Self.timestampFormat))")
                                .disabled(appState.continuingEntryID == entry.id
                                          ? !appState.canStopDictation : appState.status != .idle)
                                Button(recoverTitle) {
                                    Task { await appState.recoverCancelledDictation(entry) }
                                }
                                .buttonStyle(.dsSecondary)
                                .accessibilityLabel("\(recoverTitle) from cancelled session on \(entry.createdAt.formatted(Self.timestampFormat))")
                                .disabled(appState.status != .idle)
                            }
                            DSIconButton(
                                systemImage: "trash",
                                accessibilityLabel: "Delete cancelled session from \(entry.createdAt.formatted(Self.timestampFormat))"
                            ) {
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
                    DSEmptyState(
                        systemImage: "clock.arrow.circlepath",
                        title: query.isEmpty ? "No transcripts" : "No matches",
                        message: query.isEmpty
                            ? "Completed dictations will appear here."
                            : "No dictations match “\(query)”."
                    )
                    .padding(.vertical, 20)
                }
            } else if !entries.isEmpty {
                DSCard {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                DSDivider()
                            }
                            TranscriptHistoryRow(
                                entry: entry,
                                onCopy: copyToPasteboard,
                                onDelete: { settings.removeTranscriptHistoryEntry(id: entry.id) }
                            )
                        }
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

    private func copyToPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct TranscriptHistoryRow: View {
    private enum CopiedKind { case transcript, raw }

    let entry: TranscriptHistoryEntry
    let onCopy: (String) -> Bool
    let onDelete: () -> Void
    @State private var copiedKind: CopiedKind?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.createdAt.formatted(TranscriptHistoryView.timestampFormat))
                    .font(DS.Fonts.ui(11.5, .semibold))
                    .tracking(0.2)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(entry.text)
                    .font(DS.Fonts.ui(13.5))
                    .lineSpacing(13.5 * 0.55 - 4)
                    .foregroundStyle(DS.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let rawText = entry.rawText {
                    DisclosureGroup("Raw transcript") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(rawText)
                                .font(DS.Fonts.ui(13))
                                .foregroundStyle(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DSInsetButton(
                                title: copiedKind == .raw ? "Copied raw" : "Copy raw",
                                systemImage: "doc.on.doc"
                            ) {
                                copy(rawText, kind: .raw)
                            }
                            .accessibilityLabel(copiedKind == .raw
                                ? "Copied raw transcript"
                                : "Copy raw transcript from \(entry.createdAt.formatted(TranscriptHistoryView.timestampFormat))")
                        }
                        .padding(.top, 6)
                    }
                    .font(DS.Fonts.ui(12, .medium))
                }
            }

            HStack(spacing: 6) {
                DSInsetButton(
                    title: copiedKind == .transcript ? "Copied" : "Copy",
                    systemImage: "doc.on.doc"
                ) {
                    copy(entry.text, kind: .transcript)
                }
                .accessibilityLabel(copiedKind == .transcript
                    ? "Copied transcript"
                    : "Copy transcript from \(entry.createdAt.formatted(TranscriptHistoryView.timestampFormat))")
                DSIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete transcript from \(entry.createdAt.formatted(TranscriptHistoryView.timestampFormat))",
                    action: onDelete
                )
                .help("Delete transcript")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
        .onDisappear { copyResetTask?.cancel() }
    }

    private func copy(_ text: String, kind: CopiedKind) {
        guard onCopy(text) else { return }
        copiedKind = kind
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedKind = nil
        }
    }
}
