import SwiftUI

struct ModelDownloadView: View {
    @Bindable var viewModel: DictationViewModel

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            // Title
            VStack(spacing: 8) {
                Text("Downloading Speech Model")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("This is a one-time download (\(WhisperModel.defaultModel.size))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Progress
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)

                        // Progress fill
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * viewModel.downloadProgress, height: 6)
                    }
                }
                .frame(height: 6)

                Text("\(Int(viewModel.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 40)

            // Info
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                Text("The model runs entirely on your device for privacy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }
}

struct InitializingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Color.accentColor)

            VStack(spacing: 8) {
                Text("Initializing")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Preparing the transcription engine...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 500, height: 500)
        .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
    }
}

#Preview("Download") {
    let vm = DictationViewModel()
    vm.modelManager.downloadProgress = 0.45
    return ModelDownloadView(viewModel: vm)
}

#Preview("Initializing") {
    InitializingView()
}
