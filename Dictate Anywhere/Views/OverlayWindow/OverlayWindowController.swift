import AppKit
import SwiftUI

/// Overlay state for the floating indicator
enum OverlayState: Equatable {
    case loading                                        // Spinner while initializing microphone
    case listening(level: Float, transcript: String)    // Waveform with audio level and live transcript
    case listeningLowVolume(level: Float)              // Warning when microphone volume is too low
    case processing                                     // Brief processing indicator
    case success                                        // Checkmark before hiding
    case copiedOnly                                     // Text copied but auto-paste failed
    case error(message: String)                        // Startup failure or mic routing error
}

/// Controls the floating, non-interactive overlay window
final class OverlayWindowController {
    // MARK: - Singleton

    static let shared = OverlayWindowController()

    // MARK: - Properties

    private var overlayWindow: NSWindow?
    private var hostingView: NSHostingView<OverlayContentView>?
    private var currentState: OverlayState = .loading
    private var hideTask: Task<Void, Never>?

    // Window configuration
    private let bottomMargin: CGFloat = 50

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Interface

    /// Shows the overlay with the specified state
    /// - Parameter state: The overlay state to display
    func show(state: OverlayState) {
        // Cancel any pending hide
        hideTask?.cancel()
        hideTask = nil

        currentState = state

        // Ensure we're on main thread
        if Thread.isMainThread {
            showOnMainThread(state: state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showOnMainThread(state: state)
            }
        }
    }

    /// Hides the overlay with an optional delay
    /// - Parameter delay: Seconds to wait before hiding (default 0.5)
    func hide(afterDelay delay: TimeInterval = 0.5) {
        hideTask?.cancel()

        if delay > 0 {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.hideOnMainThread()
            }
        } else {
            if Thread.isMainThread {
                hideOnMainThread()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.hideOnMainThread()
                }
            }
        }
    }

    /// Updates the audio level and transcript for waveform animation
    /// - Parameters:
    ///   - level: Audio level from 0.0 to 1.0
    ///   - transcript: Current transcript text
    func updateAudioLevel(_ level: Float, transcript: String) {
        show(state: .listening(level: level, transcript: transcript))
    }

    // MARK: - Private Methods

    private func showOnMainThread(state: OverlayState) {
        // Create window if needed
        if overlayWindow == nil {
            overlayWindow = createOverlayWindow()
        }

        // Create or update content view
        let contentView = OverlayContentView(state: state)

        if hostingView == nil {
            hostingView = NSHostingView(rootView: contentView)
            overlayWindow?.contentView = hostingView
        } else {
            hostingView?.rootView = contentView
        }

        // Resize and position window based on state
        repositionWindow(for: state)

        // Show window
        overlayWindow?.orderFrontRegardless()
    }

    private func hideOnMainThread() {
        overlayWindow?.orderOut(nil)
    }

    /// Creates and configures the overlay window
    private func createOverlayWindow() -> NSWindow {
        // Calculate initial position (will be repositioned)
        let initialFrame = NSRect(x: 0, y: bottomMargin, width: 180, height: 60)

        // Create borderless, transparent window
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Transparency
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Always on top behavior
        window.level = .floating

        // Collection behavior for proper display
        window.collectionBehavior = [
            .canJoinAllSpaces,          // Visible on all Spaces/Desktops
            .stationary,                // Stays in place when switching Spaces
            .ignoresCycle,              // Not included in Cmd+Tab
            .fullScreenAuxiliary        // Appears over fullscreen apps
        ]

        // Non-interactive - clicks pass through
        window.ignoresMouseEvents = true

        // Hide from window management
        window.isExcludedFromWindowsMenu = true

        // No title bar elements (even though borderless, ensure they're hidden)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        return window
    }

    /// Repositions and resizes the window at bottom center of main screen
    private func repositionWindow(for state: OverlayState) {
        guard let screen = NSScreen.main, let window = overlayWindow else { return }

        // Get actual content size based on state (must match OverlayContentView)
        let (windowWidth, windowHeight) = contentSize(for: state)

        let screenFrame = screen.visibleFrame
        let windowX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let windowY = screenFrame.origin.y + bottomMargin

        // Set both size and position
        let newFrame = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
        window.setFrame(newFrame, display: true, animate: false)
    }

    /// Returns the content size for a given state (must match OverlayContentView frame sizes)
    private func contentSize(for state: OverlayState) -> (width: CGFloat, height: CGFloat) {
        switch state {
        case .listening:
            // Check if text preview is enabled
            let showTextPreview = SettingsManager.shared.showTextPreview
            if showTextPreview {
                return (320, 140)
            } else {
                return (200, 60)
            }
        case .listeningLowVolume:
            // Same as compact listening size
            return (200, 60)
        case .copiedOnly:
            // Wider to show the "Press Cmd+V" message
            return (220, 60)
        case .error(let message):
            // Wider for actionable startup error text
            let width = min(max(CGFloat(message.count) * 6.5, 230), 300)
            return (width, 60)
        default:
            // Loading, processing, success all use compact size
            return (180, 60)
        }
    }
}
