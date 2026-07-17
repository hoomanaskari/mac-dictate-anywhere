import AppKit
import SwiftUI

/// Atom: invisible view that lets the user drag the window by the area it
/// covers. Placed *behind* interactive content (e.g. as the sidebar's
/// background), so controls in front still receive their own drags.
///
/// Needed because the main window disables `isMovableByWindowBackground` —
/// otherwise window-dragging swallows drags aimed at custom controls like
/// `DSSlider` and the multiline text area's resize grip.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Makes the covered area a window-drag handle. Uses the native
/// `WindowDragGesture` on macOS 15+, falling back to `WindowDragArea` on 14.
/// Buttons and other controls inside keep priority over the drag gesture.
struct SidebarWindowDragModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content.background(WindowDragArea())
        }
    }
}
