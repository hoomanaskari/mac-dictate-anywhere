//
//  LanguagePickerView.swift
//  Dictate Anywhere
//
//  Language selection UI for choosing transcription language.
//

import SwiftUI

struct LanguagePickerView: View {
    @Binding var selectedLanguage: SupportedLanguage
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var filteredLanguages: [SupportedLanguage] {
        if searchText.isEmpty {
            return SupportedLanguage.allCases
        }
        return SupportedLanguage.allCases.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.nativeName.localizedCaseInsensitiveContains(searchText) ||
            $0.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .background(AppTheme.divider)

            // Search field
            searchField

            // Language list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredLanguages) { language in
                        LanguageRow(
                            language: language,
                            isSelected: language == selectedLanguage
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedLanguage = language
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 320, height: 450)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Select Language")
                .font(.headline)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search languages...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct LanguageRow: View {
    let language: SupportedLanguage
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(language.flag)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(language.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .primary)

                Text(language.nativeName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

#Preview {
    LanguagePickerView(selectedLanguage: .constant(.english))
}
