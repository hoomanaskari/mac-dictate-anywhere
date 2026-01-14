//
//  ContentView.swift
//  Dictate Anywhere
//
//  Created by Hooman on 1/14/26.
//

import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: DictationViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView("Loading...")

            case .checkingPermissions:
                loadingView("Checking permissions...")

            case .permissionsMissing:
                PermissionsView(viewModel: viewModel)

            case .downloadingModel:
                ModelDownloadView(viewModel: viewModel)

            case .initializingModel:
                InitializingView()

            case .ready, .listening, .processing:
                DictationView(viewModel: viewModel)

            case .modelManagement:
                ModelsView(viewModel: viewModel)

            case .error(let message):
                errorView(message)
            }
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.blue)

            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.red)

            Text("Error")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: {
                viewModel.initialize()
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .foregroundStyle(.blue)
                .background {
                    Capsule()
                        .stroke(.blue, lineWidth: 1.5)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }
}

#Preview {
    ContentView(viewModel: DictationViewModel())
}
