//
//  SidebarView.swift
//  Dictate Anywhere
//
//  Navigation sidebar.
//

import SwiftUI

struct SidebarView: View {
    @Binding var selectedPage: SidebarPage

    var body: some View {
        List(SidebarPage.allCases, selection: $selectedPage) { page in
            Label(page.title, systemImage: page.icon)
                .tag(page)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    }
}
