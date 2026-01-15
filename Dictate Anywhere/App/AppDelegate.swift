import AppKit
import SwiftUI
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var microphoneMenuItem: NSMenuItem?

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
            button.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Dictate Anywhere")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(
            title: "Open Dictate Anywhere",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        // Microphone submenu
        microphoneMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneSubmenu = NSMenu()
        microphoneMenuItem?.submenu = microphoneSubmenu
        menu.addItem(microphoneMenuItem!)

        updateMicrophoneMenu()

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

    // MARK: - Microphone Menu

    private func updateMicrophoneMenu() {
        guard let submenu = microphoneMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let manager = MicrophoneManager.shared
        for mic in manager.availableMicrophones {
            let title = mic.isDefault ? "Default System Microphone" : mic.name

            let item = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mic.id
            item.state = (mic.id == manager.selectedMicrophone?.id) ? .on : .off
            submenu.addItem(item)
        }

        // Update parent menu title to show current selection
        if let selected = manager.selectedMicrophone {
            let displayName = selected.isDefault ? "Default System Microphone" : selected.name
            microphoneMenuItem?.title = "Microphone: \(displayName)"
        } else {
            microphoneMenuItem?.title = "Microphone"
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? AudioDeviceID else { return }
        let manager = MicrophoneManager.shared
        if let mic = manager.availableMicrophones.first(where: { $0.id == deviceID }) {
            manager.selectMicrophone(mic)
            updateMicrophoneMenu()
        }
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

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMicrophoneMenu()
    }
}
