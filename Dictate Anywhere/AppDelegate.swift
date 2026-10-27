//
//  AppDelegate.swift
//  Dictate Anywhere
//
//  Menu bar setup, window management, dock mode.
//

import AppKit
import SwiftUI
import FluidAudio

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
#if !DEBUG
    let softwareUpdater = SoftwareUpdater()
#endif
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var customVocabularyMenuItem: NSMenuItem?
    private var copyLastTranscriptMenuItem: NSMenuItem?
    private var cancelDictationMenuItem: NSMenuItem?
    private var stopDictationMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var isTerminating = false

    override init() {
        self.appState = AppState()
        super.init()
    }

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    // MARK: - Lifecycle

    /// True when the app is acting as a unit-test host. Skips single-instance
    /// enforcement and service startup so the test runner can attach.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureFluidAudioLogging()
        guard !Self.isRunningTests else { return }
        guard enforceSingleInstance() else { return }
        let trace = PerfTrace.begin("app.launch")
        defer { trace.end() }
        NSApp.disableRelaunchOnLogin()
        setupMenuBar()
        configureMainWindow()
        setupNotificationObservers()
        applyAppearanceMode()
        #if DEBUG
        let screenshotMode = ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
            || ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_SCREENSHOT_MODE"] == "1"
        if !screenshotMode {
            appState.start()
        }
        #else
        appState.start()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        // llama.cpp's Metal backend must release its model buffers before AppKit
        // begins process teardown, including Sparkle's update-and-relaunch path.
        Task { [weak self] in
            let trace = PerfTrace.begin("app.terminate")
            defer { trace.end() }
            await self?.appState.shutdown()
            await S1MiniPostProcessingService.unload()
            sender.reply(toApplicationShouldTerminate: true)
            self?.isTerminating = false
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        showMainWindow()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        if mainWindow?.isVisible == false {
            applyAppearanceMode()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Settings.shared.refreshLoginItemStatus()
        Task {
            await appState.refreshPermissionsAfterActivation()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
        }

        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(title: "Open Dictate Anywhere", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
        copyItem.target = self
        copyLastTranscriptMenuItem = copyItem
        menu.addItem(copyItem)

        let stopItem = NSMenuItem(title: "Stop Dictation", action: #selector(stopDictation), keyEquivalent: "")
        stopItem.target = self
        stopDictationMenuItem = stopItem
        menu.addItem(stopItem)

        let cancelItem = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
        cancelItem.target = self
        cancelDictationMenuItem = cancelItem
        menu.addItem(cancelItem)

        let vocabItem = NSMenuItem(title: "Add Custom Vocabulary", action: #selector(showVocabularyPanel), keyEquivalent: "")
        vocabItem.target = self
        customVocabularyMenuItem = vocabItem
        menu.addItem(vocabItem)

#if !DEBUG
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateMenuItem = updateItem
        menu.addItem(updateItem)
#endif

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
        refreshUpdateIndicator()
    }

    /// Ensures only one Dictate Anywhere process stays active.
    /// Prevents duplicate menu bar icons if the app is launched multiple times.
    private func enforceSingleInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let matchingApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }

        guard let keeperPID = matchingApps.map(\.processIdentifier).min(), currentPID != keeperPID else {
            return true
        }

        if let keeper = matchingApps.first(where: { $0.processIdentifier == keeperPID }) {
            keeper.activate()
        }
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Window

    @objc private func cancelDictation() {
        Task { await appState.cancelDictation() }
    }

    @objc private func stopDictation() {
        Task { await appState.stopDictation() }
    }

    private func configureMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupWindow()
        }
    }

    private func setupWindow() {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && !($0.contentView is NSVisualEffectView && $0.level == .floating) }) else { return }
        mainWindow = window
        window.styleMask.insert(.resizable)
        // Background dragging must stay off: it swallows drags aimed at
        // in-window controls (DSSlider, the textarea resize grip). The
        // sidebar hosts an explicit WindowDragArea instead.
        window.isMovableByWindowBackground = false
        window.contentMinSize = NSSize(width: MainWindowSizing.minimumWidth, height: MainWindowSizing.minimumHeight)
        window.contentMaxSize = NSSize(width: MainWindowSizing.maximumWidth, height: MainWindowSizing.maximumHeight)
        window.center()
        window.delegate = self
    }

    // MARK: - Appearance

    private func applyAppearanceMode(treatingMainWindowAsVisible: Bool = false) {
        let preferredPolicy = Settings.shared.appAppearanceMode.activationPolicy
        #if !DEBUG
        let updateIsVisible = softwareUpdater.presentation.isActive
        #else
        let updateIsVisible = false
        #endif
        let targetPolicy = Self.activationPolicy(preferred: preferredPolicy,
            mainWindowIsVisible: treatingMainWindowAsVisible || mainWindow?.isVisible == true,
            updateIsVisible: updateIsVisible)
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }
    }

    static func activationPolicy(preferred: NSApplication.ActivationPolicy,
                                 mainWindowIsVisible: Bool, updateIsVisible: Bool) -> NSApplication.ActivationPolicy {
        preferred == .regular || mainWindowIsVisible || updateIsVisible ? .regular : .accessory
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppearanceChanged), name: .appAppearanceModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppearanceChanged), name: .softwareUpdatePresentationChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissMenusForPaste), name: .dismissMenusForPaste, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleShowMainWindowRequest), name: .requestShowMainWindow, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppearanceChanged() {
        applyAppearanceMode()
        refreshUpdateIndicator()
    }

    private func refreshUpdateIndicator() {
        #if !DEBUG
        guard let button = statusItem?.button, let updateMenuItem else { return }
        UpdateAvailabilityIndicator.apply(version: softwareUpdater.presentation.availableVersion,
            to: button, updateItem: updateMenuItem)
        #endif
    }

    @objc private func dismissMenusForPaste() {
        statusItem?.menu?.cancelTracking()
    }

    @objc private func handleShowMainWindowRequest() {
        showMainWindow()
    }

    // MARK: - Menu Actions

    @objc func showMainWindow() {
        applyAppearanceMode(treatingMainWindowAsVisible: true)
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            mainWindow = window
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func copyLastTranscript() {
        let transcript = AppState.lastTranscriptForMenuBar
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

#if !DEBUG
    @objc private func checkForUpdates() {
        softwareUpdater.checkForUpdates()
    }
#endif

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        Settings.shared.selectedMicrophoneUID = sender.representedObject as? String
    }

    @objc private func showVocabularyPanel() {
        QuickVocabularyPanel.shared.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let statusMenu = statusItem?.menu, menu === statusMenu {
            copyLastTranscriptMenuItem?.isEnabled = !AppState.lastTranscriptForMenuBar.isEmpty
            stopDictationMenuItem?.isHidden = !appState.canStopDictation
            cancelDictationMenuItem?.isHidden = !appState.canCancelDictation
            customVocabularyMenuItem?.isHidden =
                Settings.shared.engineChoice != .assemblyAI
                && !Settings.shared
                    .transcriptPostProcessingMode
                    .supportedFeatures
                    .contains(.customVocabulary)
            return
        }

        guard menu.title == "Microphone" else { return }
        menu.removeAllItems()

        appState.audioDeviceManager.refreshDevices()
        let selectedUID = Settings.shared.selectedMicrophoneUID
        let devices = appState.audioDeviceManager.availableInputDevices
        let isFallingBack = selectedUID != nil && !devices.contains { $0.uid == selectedUID }

        let defaultItem = NSMenuItem(title: appState.automaticMicrophoneTitle, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = nil
        defaultItem.state = selectedUID == nil || isFallingBack ? .on : .off
        menu.addItem(defaultItem)

        menu.addItem(NSMenuItem.separator())

        for device in appState.audioDeviceManager.availableInputDevices {
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
    static let requestShowMainWindow = Notification.Name("requestShowMainWindow")
}

/// Use the SDK's supported routing rather than intercepting process stderr.
/// Speech debug output is opt-in and retained only in local Debug builds.
@MainActor
private func configureFluidAudioLogging() {
    #if DEBUG
    let keepDebugLogs = ProcessInfo.processInfo.environment["DICTATE_ANYWHERE_KEEP_FLUID_DEBUG_LOGS"] == "1"
    AppLogger.minimumLevel = keepDebugLogs ? .debug : .warning
    AppLogger.mirrorsToConsole = keepDebugLogs
    #else
    AppLogger.minimumLevel = .warning
    AppLogger.mirrorsToConsole = false
    #endif
}
