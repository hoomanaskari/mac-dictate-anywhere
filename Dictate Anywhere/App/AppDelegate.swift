import AppKit
import SwiftUI
import CoreAudio
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var microphoneMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FluidAudioDebugLogFilter.installIfNeeded()
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMicrophoneSelectionModeChanged),
            name: .microphoneSelectionModeChanged,
            object: nil
        )
    }

    @objc private func handleAppearanceModeChanged() {
        applyAppearanceMode()
    }

    @objc private func handleMicrophoneSelectionModeChanged() {
        updateMicrophoneMenu()
    }

    private func applyAppearanceMode() {
        let settings = SettingsManager.shared
        switch settings.appAppearanceMode {
        case .menuBarOnly:
            // Only show in menu bar (accessory mode hides from dock)
            // But keep regular mode while window is visible for better UX
            let isAnyWindowVisible = mainWindow?.isVisible
                ?? NSApp.windows.contains(where: { $0.isVisible })
            if isAnyWindowVisible {
                NSApp.setActivationPolicy(.regular)
            } else {
                NSApp.setActivationPolicy(.accessory)
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
        microphoneSubmenu.autoenablesItems = false
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

        // Re-apply mode once we have a concrete window reference.
        applyAppearanceMode()
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
        let useSystemDefault = SettingsManager.shared.useSystemDefaultMicrophone

        let useDefaultItem = NSMenuItem(
            title: "Use System Default",
            action: #selector(toggleUseSystemDefaultMicrophone(_:)),
            keyEquivalent: ""
        )
        useDefaultItem.target = self
        useDefaultItem.state = useSystemDefault ? .on : .off
        submenu.addItem(useDefaultItem)
        submenu.addItem(NSMenuItem.separator())

        if manager.availableMicrophones.isEmpty {
            let emptyItem = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        }

        for mic in manager.availableMicrophones {
            let title = mic.isDefault ? "Default System Microphone" : mic.name

            let item = NSMenuItem(
                title: title,
                action: useSystemDefault ? nil : #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mic.id
            item.state = (mic.id == manager.selectedMicrophone?.id) ? .on : .off
            item.isEnabled = !useSystemDefault
            submenu.addItem(item)
        }

        // Update parent menu title to show current selection
        if let selected = manager.selectedMicrophone {
            let resolvedSelection = manager.availableMicrophones.first(where: { $0.id == selected.id }) ?? selected
            let displayName = resolvedSelection.isDefault ? "Default System Microphone" : resolvedSelection.name
            microphoneMenuItem?.title = displayName
        } else {
            microphoneMenuItem?.title = "Microphone"
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard !SettingsManager.shared.useSystemDefaultMicrophone else { return }
        guard let deviceID = sender.representedObject as? AudioDeviceID else { return }
        let manager = MicrophoneManager.shared
        if let mic = manager.availableMicrophones.first(where: { $0.id == deviceID }) {
            manager.selectMicrophone(mic)
            updateMicrophoneMenu()
        }
    }

    @objc private func toggleUseSystemDefaultMicrophone(_ sender: NSMenuItem) {
        let settings = SettingsManager.shared
        settings.useSystemDefaultMicrophone.toggle()

        let manager = MicrophoneManager.shared
        if settings.useSystemDefaultMicrophone {
            manager.selectedMicrophone = manager.availableMicrophones.first(where: { $0.isDefault })
                ?? manager.availableMicrophones.first
        }

        manager.refreshMicrophones()
        updateMicrophoneMenu()
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

/// Filters extremely verbose FluidAudio DEBUG logs from stderr in debug builds.
/// Keeps INFO/WARN/ERROR/FAULT and non-FluidAudio logs unchanged.
private enum FluidAudioDebugLogFilter {
    static func installIfNeeded() {
        #if DEBUG
        Shared.instance.installIfNeeded()
        #endif
    }

    #if DEBUG
    private final class Shared {
        static let instance = Shared()

        private let queue = DispatchQueue(label: "com.pixelforty.dictate-anywhere.stderr-filter", qos: .utility)
        private let lock = NSLock()
        private var isInstalled = false
        private var source: DispatchSourceRead?
        private var readFD: Int32 = -1
        private var originalStderrFD: Int32 = -1
        private var pendingData = Data()

        func installIfNeeded() {
            lock.lock()
            defer { lock.unlock() }

            guard !isInstalled else { return }
            guard ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_KEEP_FLUID_DEBUG_LOGS"] != "1" else { return }

            let savedStderr = dup(STDERR_FILENO)
            guard savedStderr >= 0 else { return }

            var pipeFDs: [Int32] = [0, 0]
            guard pipe(&pipeFDs) == 0 else {
                close(savedStderr)
                return
            }

            guard dup2(pipeFDs[1], STDERR_FILENO) >= 0 else {
                close(pipeFDs[0])
                close(pipeFDs[1])
                close(savedStderr)
                return
            }

            close(pipeFDs[1])

            originalStderrFD = savedStderr
            readFD = pipeFDs[0]
            isInstalled = true

            let readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
            readSource.setEventHandler { [weak self] in
                self?.readAvailableData()
            }
            readSource.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.readFD >= 0 {
                    close(self.readFD)
                    self.readFD = -1
                }
                if self.originalStderrFD >= 0 {
                    close(self.originalStderrFD)
                    self.originalStderrFD = -1
                }
            }
            source = readSource
            readSource.resume()
        }

        private func readAvailableData() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(readFD, &buffer, buffer.count)

            guard bytesRead > 0 else {
                source?.cancel()
                source = nil
                return
            }

            pendingData.append(contentsOf: buffer.prefix(Int(bytesRead)))
            flushCompleteLines()
        }

        private func flushCompleteLines() {
            while let newlineRange = pendingData.firstRange(of: Data([0x0A])) {
                let lineData = pendingData.subdata(in: pendingData.startIndex..<newlineRange.lowerBound)
                pendingData.removeSubrange(pendingData.startIndex...newlineRange.lowerBound)
                forwardLineIfNeeded(lineData, appendNewline: true)
            }
        }

        private func forwardLineIfNeeded(_ lineData: Data, appendNewline: Bool) {
            let lineText = String(data: lineData, encoding: .utf8)
            let shouldDrop = lineText?.contains("[DEBUG] [FluidAudio.") == true
            guard !shouldDrop else { return }

            var output = lineData
            if appendNewline {
                output.append(0x0A)
            }
            writeAll(output)
        }

        private func writeAll(_ data: Data) {
            guard originalStderrFD >= 0 else { return }
            data.withUnsafeBytes { rawBuffer in
                guard var base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = write(originalStderrFD, base, remaining)
                    if written <= 0 {
                        break
                    }
                    base = base.advanced(by: written)
                    remaining -= written
                }
            }
        }
    }
    #endif
}

// MARK: - Notification Names

extension Notification.Name {
    static let mainWindowWillClose = Notification.Name("mainWindowWillClose")
    static let dismissMenusForPaste = Notification.Name("dismissMenusForPaste")
    static let microphoneSelectionModeChanged = Notification.Name("microphoneSelectionModeChanged")
}
