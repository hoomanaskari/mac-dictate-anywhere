//
//  SidebarView.swift
//  Dictate Anywhere
//
//  Navigation sidebar with sections.
//

import SwiftUI

struct SidebarView: View {
    @Binding var selectedPage: SidebarPage

    var body: some View {
        List(selection: $selectedPage) {
            Section("Dictate") {
                Label(SidebarPage.home.title, systemImage: SidebarPage.home.icon)
                    .tag(SidebarPage.home)
            }

            Section("Speech Model") {
                Label(SidebarPage.models.title, systemImage: SidebarPage.models.icon)
                    .tag(SidebarPage.models)
            }

            Section("Settings") {
                Label(SidebarPage.general.title, systemImage: SidebarPage.general.icon)
                    .tag(SidebarPage.general)

                Label(SidebarPage.shortcuts.title, systemImage: SidebarPage.shortcuts.icon)
                    .tag(SidebarPage.shortcuts)

                Label(SidebarPage.transcription.title, systemImage: SidebarPage.transcription.icon)
                    .tag(SidebarPage.transcription)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    }
}
