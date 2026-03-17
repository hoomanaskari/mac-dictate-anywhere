//
//  SettingsMultilineTextArea.swift
//  Dictate Anywhere
//
//  Native macOS multiline text area for settings forms.
//

import SwiftUI
import AppKit

struct SettingsMultilineTextArea: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let showsResizeHandle: Bool

    @State private var isFocused = false
    @State private var height: CGFloat
    @State private var dragStartHeight: CGFloat?

    init(
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat = 80,
        maxHeight: CGFloat = 240,
        showsResizeHandle: Bool = true
    ) {
        _text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.showsResizeHandle = showsResizeHandle
        _height = State(initialValue: minHeight)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        ZStack(alignment: .topLeading) {
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .textBackgroundColor),
                            Color(nsColor: .controlBackgroundColor),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            AppKitMultilineTextView(text: $text, isFocused: $isFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .padding(.trailing, showsResizeHandle ? 10 : 0)
                .padding(.bottom, showsResizeHandle ? 10 : 0)

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height, alignment: .topLeading)
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.12),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .overlay {
            shape
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.42),
                    lineWidth: 0.5
                )
        }
        .overlay(alignment: .bottomTrailing) {
            if showsResizeHandle {
                ResizeGrip(color: isFocused ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.7))
                    .padding(.trailing, 7)
                    .padding(.bottom, 7)
                    .gesture(resizeGesture)
            }
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06),
            radius: isFocused ? 8 : 4,
            y: isFocused ? 2 : 1
        )
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .animation(.easeOut(duration: 0.16), value: height)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startHeight = dragStartHeight ?? height
                if dragStartHeight == nil {
                    dragStartHeight = height
                }

                height = min(max(startHeight + value.translation.height, minHeight), maxHeight)
            }
            .onEnded { _ in
                dragStartHeight = nil
            }
    }
}

private struct AppKitMultilineTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = FocusAwareTextView()
        textView.delegate = context.coordinator
        textView.onFocusChange = { isFocused in
            context.coordinator.isFocused = isFocused
        }
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.focusRingType = .none
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 7)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.string = text

        guard let textContainer = textView.textContainer else {
            scrollView.documentView = textView
            return scrollView
        }

        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textContainer.lineFragmentPadding = 0

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusAwareTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding var isFocused: Bool

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class FocusAwareTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocusChange?(true)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFocusChange?(false)
        }
        return didResignFirstResponder
    }
}

private struct ResizeGrip: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            for offset in stride(from: 0.0, through: 6.0, by: 3.0) {
                var path = Path()
                path.move(to: CGPoint(x: size.width - 1 - offset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 1 - offset))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
                )
            }
        }
        .frame(width: 12, height: 12)
        .padding(4)
        .contentShape(Rectangle())
        .accessibilityLabel("Resize text area")
    }
}
