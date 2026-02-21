//
//  OverlayWindow.swift
//  Dictate Anywhere
//
//  Floating NSWindow controller for dictation overlay.
//

import AppKit
import SwiftUI

@Observable
final class OverlayWindow {
    // MARK: - Properties

    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayContent>?
    private var hideTask: Task<Void, Never>?
    private let bottomMargin: CGFloat = 50

    // MARK: - Public

    func show(state: OverlayState) {
        hideTask?.cancel()
        hideTask = nil

        if Thread.isMainThread {
            showImpl(state: state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showImpl(state: state)
            }
        }
    }

    func hide(afterDelay delay: TimeInterval = 0.5) {
        hideTask?.cancel()

        if delay > 0 {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.hideImpl()
            }
        } else {
            if Thread.isMainThread {
                hideImpl()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.hideImpl()
                }
            }
        }
    }

    // MARK: - Private

    private func showImpl(state: OverlayState) {
        if window == nil {
            window = createWindow()
        }

        let content = OverlayContent(state: state)
        if hostingView == nil {
            hostingView = NSHostingView(rootView: content)
            window?.contentView = hostingView
        } else {
            hostingView?.rootView = content
        }

        repositionWindow(for: state)
        window?.orderFrontRegardless()
    }

    private func hideImpl() {
        window?.orderOut(nil)
    }

    private func createWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: bottomMargin, width: 180, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true
        win.isExcludedFromWindowsMenu = true
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        return win
    }

    private func repositionWindow(for state: OverlayState) {
        guard let screen = NSScreen.main, let win = window else { return }

        let (w, h) = contentSize(for: state)
        let frame = screen.visibleFrame
        let x = frame.origin.x + (frame.width - w) / 2
        let y = frame.origin.y + bottomMargin

        win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
    }

    private func contentSize(for state: OverlayState) -> (CGFloat, CGFloat) {
        let showPreview = Settings.shared.showTextPreview
        switch state {
        case .listening:
            return showPreview ? (320, 140) : (200, 60)
        case .copiedOnly:
            return (220, 60)
        default:
            return (180, 60)
        }
    }
}
