//
//  AppDelegate.swift
//  Dictate Anywhere
//
//  Menu bar setup, window management, dock mode.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let softwareUpdater = SoftwareUpdater()
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        FluidAudioDebugLogFilter.installIfNeeded()
        setupMenuBar()
        configureMainWindow()
        setupNotificationObservers()
        applyAppearanceMode()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        if mainWindow?.isVisible == false {
            applyAppearanceMode()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Open Dictate Anywhere", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu(title: "Microphone")
        micSubmenu.delegate = self
        micItem.submenu = micSubmenu
        menu.addItem(micItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Window

    private func configureMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupWindow()
        }
    }

    private func setupWindow() {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && !($0.contentView is NSVisualEffectView && $0.level == .floating) }) else { return }
        mainWindow = window
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 500, height: 400)
        window.center()
        window.delegate = self
        applyAppearanceMode()
    }

    // MARK: - Appearance

    private func applyAppearanceMode() {
        switch Settings.shared.appAppearanceMode {
        case .menuBarOnly:
            let isVisible = mainWindow?.isVisible ?? false
            NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
        case .dockAndMenuBar:
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppearanceChanged), name: .appAppearanceModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissMenusForPaste), name: .dismissMenusForPaste, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppearanceChanged() {
        applyAppearanceMode()
    }

    @objc private func dismissMenusForPaste() {
        statusItem?.menu?.cancelTracking()
    }

    // MARK: - Menu Actions

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func copyLastTranscript() {
        let transcript = AppState.lastTranscriptForMenuBar
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    @objc private func checkForUpdates() {
        softwareUpdater.checkForUpdates()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        Settings.shared.selectedMicrophoneUID = sender.representedObject as? String
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Microphone" else { return }
        menu.removeAllItems()

        let selectedUID = Settings.shared.selectedMicrophoneUID

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = nil
        defaultItem.state = selectedUID == nil ? .on : .off
        menu.addItem(defaultItem)

        menu.addItem(NSMenuItem.separator())

        for device in AudioDeviceManager.enumerateInputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = selectedUID == device.uid ? .on : .off
            menu.addItem(item)
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.applyAppearanceMode()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let dismissMenusForPaste = Notification.Name("dismissMenusForPaste")
}

// MARK: - FluidAudio Debug Log Filter

private enum FluidAudioDebugLogFilter {
    static func installIfNeeded() {
        #if DEBUG
        Shared.instance.installIfNeeded()
        #endif
    }

    #if DEBUG
    private final class Shared {
        static let instance = Shared()
        private let queue = DispatchQueue(label: "com.dictate-anywhere.stderr-filter", qos: .utility)
        private let lock = NSLock()
        private var isInstalled = false
        private var source: DispatchSourceRead?
        private var readFD: Int32 = -1
        private var originalStderrFD: Int32 = -1
        private var pendingData = Data()

        deinit {
            source?.cancel()
        }

        func installIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard !isInstalled else { return }
            guard ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_KEEP_FLUID_DEBUG_LOGS"] != "1" else { return }

            let savedStderr = dup(STDERR_FILENO)
            guard savedStderr >= 0 else { return }

            var pipeFDs: [Int32] = [0, 0]
            guard pipe(&pipeFDs) == 0 else { close(savedStderr); return }
            guard dup2(pipeFDs[1], STDERR_FILENO) >= 0 else {
                close(pipeFDs[0]); close(pipeFDs[1]); close(savedStderr); return
            }
            close(pipeFDs[1])

            originalStderrFD = savedStderr
            readFD = pipeFDs[0]
            isInstalled = true

            let readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
            readSource.setEventHandler { [weak self] in self?.readAvailableData() }
            readSource.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.readFD >= 0 { close(self.readFD); self.readFD = -1 }
                if self.originalStderrFD >= 0 { close(self.originalStderrFD); self.originalStderrFD = -1 }
            }
            source = readSource
            readSource.resume()
        }

        private func readAvailableData() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(readFD, &buffer, buffer.count)
            guard bytesRead > 0 else { source?.cancel(); source = nil; return }
            pendingData.append(contentsOf: buffer.prefix(Int(bytesRead)))
            flushCompleteLines()
        }

        private func flushCompleteLines() {
            while let range = pendingData.firstRange(of: Data([0x0A])) {
                let lineData = pendingData.subdata(in: pendingData.startIndex..<range.lowerBound)
                pendingData.removeSubrange(pendingData.startIndex...range.lowerBound)
                if let text = String(data: lineData, encoding: .utf8), text.contains("[DEBUG] [FluidAudio.") {
                    continue
                }
                var output = lineData
                output.append(0x0A)
                writeAll(output)
            }
        }

        private func writeAll(_ data: Data) {
            guard originalStderrFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard var base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = write(originalStderrFD, base, remaining)
                    if written <= 0 { break }
                    base = base.advanced(by: written)
                    remaining -= written
                }
            }
        }
    }
    #endif
}
