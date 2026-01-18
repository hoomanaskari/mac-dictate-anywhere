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
        setupNotificationObservers()

        // Apply initial appearance mode from settings
        applyAppearanceMode()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dismissMenusForPaste),
            name: .dismissMenusForPaste,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceModeChanged),
            name: .appAppearanceModeChanged,
            object: nil
        )
    }

    @objc private func handleAppearanceModeChanged() {
        applyAppearanceMode()
    }

    private func applyAppearanceMode() {
        let settings = SettingsManager.shared
        switch settings.appAppearanceMode {
        case .menuBarOnly:
            // Only show in menu bar (accessory mode hides from dock)
            // But keep regular mode while window is visible for better UX
            if mainWindow?.isVisible == false {
                NSApp.setActivationPolicy(.accessory)
            } else {
                NSApp.setActivationPolicy(.regular)
            }
        case .dockAndMenuBar:
            // Always show in both dock and menu bar
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func dismissMenusForPaste() {
        // Cancel menu tracking so paste goes to the correct app
        statusItem?.menu?.cancelTracking()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window is closed - keep running in menu bar
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        // When app loses focus and window is not visible, apply appearance mode
        if mainWindow?.isVisible == false {
            applyAppearanceMode()
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
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

        let copyTranscriptItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript),
            keyEquivalent: "c"
        )
        copyTranscriptItem.target = self
        menu.addItem(copyTranscriptItem)

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
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func copyLastTranscript() {
        let transcript = ClipboardManager.shared.lastTranscript
        if !transcript.isEmpty {
            ClipboardManager.shared.copyToClipboard(transcript)
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
        // Notify that the main window is closing (so viewModel can exit settings/modelManagement)
        NotificationCenter.default.post(name: .mainWindowWillClose, object: nil)

        // Apply appearance mode setting when window closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyAppearanceMode()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Window became key - no special handling needed
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMicrophoneMenu()
    }
}

// MARK: - NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyLastTranscript) {
            return !ClipboardManager.shared.lastTranscript.isEmpty
        }
        return true
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let mainWindowWillClose = Notification.Name("mainWindowWillClose")
    static let dismissMenusForPaste = Notification.Name("dismissMenusForPaste")
}
