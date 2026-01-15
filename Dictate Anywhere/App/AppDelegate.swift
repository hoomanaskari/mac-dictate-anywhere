import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        configureMainWindow()

        // Start as regular app to show window initially
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window is closed - keep running in menu bar
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        // When app loses focus and window is not visible, go to accessory mode
        if mainWindow?.isVisible == false {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictate Anywhere")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: "Open Dictate Anywhere",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Window Configuration

    private func configureMainWindow() {
        // Configure window after a short delay to ensure it exists
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupWindowLevel()
        }
    }

    private func setupWindowLevel() {
        guard let window = NSApp.windows.first(where: { $0.className.contains("NSWindow") || $0.contentView != nil }) else { return }

        mainWindow = window

        // Keep window on top (floating)
        window.level = .floating

        // Window styling
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // Set window size
        window.setContentSize(NSSize(width: 440, height: 400))
        window.minSize = NSSize(width: 420, height: 380)

        // Center the window
        window.center()

        // Set up window delegate to handle close
        window.delegate = self
    }

    // MARK: - Menu Actions

    @objc private func showMainWindow() {
        // Show in dock
        NSApp.setActivationPolicy(.regular)

        // Activate the app
        NSApp.activate(ignoringOtherApps: true)

        // Show the window
        if let window = mainWindow {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            mainWindow = window
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Hide from dock when window closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure window stays floating
        if let window = notification.object as? NSWindow {
            window.level = .floating
        }
    }
}
