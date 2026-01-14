import SwiftUI

/// Card view for displaying a single model with its status and actions
struct ModelCardView: View {
    let model: WhisperModel
    let isCurrent: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row: Icon, Name, Size, Category Badge
            HStack(spacing: 12) {
                // Category icon
                Image(systemName: model.category.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.category.color)
                    .frame(width: 32, height: 32)

                // Name and language
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)

                        if model.isEnglishOnly {
                            Text("EN")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(model.size)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Category badge
                CategoryBadge(category: model.category)
            }

            // Description
            Text(model.description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Action area
            if isDownloading {
                // Download progress
                VStack(spacing: 6) {
                    ProgressView(value: downloadProgress)
                        .tint(.orange)

                    Text("Downloading... \(Int(downloadProgress * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }
            } else if isCurrent {
                // Current model - show checkmark and delete option
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Current Model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    if let onDelete = onDelete {
                        Button(action: onDelete) {
                            Text("Delete")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.red.opacity(0.9))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background {
                                    Capsule()
                                        .stroke(.red.opacity(0.5), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Available model - show select button
                HStack {
                    Spacer()

                    Button(action: onSelect) {
                        Text("Select")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background {
                                Capsule()
                                    .stroke(.blue, lineWidth: 1.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isCurrent ? Color.green.opacity(0.4) : Color.white.opacity(0.1),
                            lineWidth: isCurrent ? 1.5 : 1
                        )
                }
        }
    }
}

/// Badge showing the model category
struct CategoryBadge: View {
    let category: ModelCategory

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.icon)
                .font(.system(size: 10, weight: .bold))

            Text(category.displayName)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(category.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(category.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Current Model Card (Simplified)

/// Special card for the currently active model
struct CurrentModelCard: View {
    let model: WhisperModel
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 12) {
                // Checkmark icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Text(model.size)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        if model.isEnglishOnly {
                            Text("English Only")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Multilingual")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                CategoryBadge(category: model.category)
            }

            // Description
            Text(model.description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Delete button
            HStack {
                Spacer()

                Button(action: onDelete) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("Delete Model")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background {
                        Capsule()
                            .stroke(.red.opacity(0.4), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.green.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.green.opacity(0.3), lineWidth: 1.5)
                }
        }
    }
}

// MARK: - Previews

#Preview("Available Model") {
    ModelCardView(
        model: WhisperModel.allModels[0],
        isCurrent: false,
        isDownloading: false,
        downloadProgress: 0,
        onSelect: {},
        onDelete: nil
    )
    .padding()
    .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
}

#Preview("Current Model") {
    ModelCardView(
        model: WhisperModel.allModels[2],
        isCurrent: true,
        isDownloading: false,
        downloadProgress: 0,
        onSelect: {},
        onDelete: {}
    )
    .padding()
    .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
}

#Preview("Downloading") {
    ModelCardView(
        model: WhisperModel.allModels[4],
        isCurrent: false,
        isDownloading: true,
        downloadProgress: 0.45,
        onSelect: {},
        onDelete: nil
    )
    .padding()
    .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
}

#Preview("Current Model Card") {
    CurrentModelCard(
        model: WhisperModel.allModels[2],
        onDelete: {}
    )
    .padding()
    .background(Color(red: 0x21/255, green: 0x21/255, blue: 0x26/255))
}
