//
//  QuickVocabularyPanel.swift
//  Dictate Anywhere
//
//  Floating panel for quickly adding custom vocabulary words.
//

import AppKit
import SwiftUI

final class QuickVocabularyPanel {
    static let shared = QuickVocabularyPanel()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        show()
    }

    func show() {
        if panel == nil {
            panel = createPanel()
        }
        guard let panel else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 408, height: 336),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Custom Vocabulary"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: QuickVocabularyView())
        return panel
    }
}

private struct QuickVocabularyView: View {
    @State private var newTerm = ""
    @State private var justAdded: String?
    private var settings: Settings { Settings.shared }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            // Input area
            VStack(alignment: .leading, spacing: 8) {
                Text("Teach the transcription engine new words, names, or phrases.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("", text: $newTerm, prompt: Text("e.g. Kubernetes, ChatGPT..."))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTerm() }

                    Button(action: addTerm) {
                        Text("Add")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)

            Divider()

            // Word list
            if settings.customVocabulary.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 24))
                        .foregroundStyle(.quaternary)
                    Text("No words added yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.customVocabulary, id: \.self) { term in
                            VocabularyChip(
                                term: term,
                                font: .callout,
                                horizontalPadding: 10,
                                verticalPadding: 5,
                                backgroundColor: justAdded == term
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(nsColor: .quaternaryLabelColor)
                            ) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    settings.customVocabulary.removeAll { $0 == term }
                                }
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(16)
                }

                Divider()

                HStack {
                    Text("\(settings.customVocabulary.count) word\(settings.customVocabulary.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(minHeight: 240, idealHeight: 336)
    }

    private func addTerm() {
        let terms = VocabularyInputParser.terms(
            from: newTerm,
            existingTerms: Settings.shared.customVocabulary
        )
        guard !terms.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            Settings.shared.customVocabulary.append(contentsOf: terms)
            justAdded = terms.last
        }
        newTerm = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if justAdded == terms.last {
                withAnimation(.easeOut(duration: 0.3)) {
                    justAdded = nil
                }
            }
        }
    }
}
