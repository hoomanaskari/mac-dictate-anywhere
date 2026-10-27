//
//  SoftwareUpdater.swift
//  Dictate Anywhere
//
//  Sparkle auto-update wrapper and foreground presentation lifecycle.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let softwareUpdatePresentationChanged = Notification.Name("softwareUpdatePresentationChanged")
}

/// Shared with tests without starting Sparkle or contacting an update server.
@MainActor
@Observable
final class UpdatePresentationSession {
    private(set) var isActive = false
    private(set) var availableVersion: String?
    private var generation = 0
    private var queuedFocusGeneration: Int?
    private let activateApplication: () -> Void
    private let presentationChanged: () -> Void

    init(
        activateApplication: @escaping () -> Void = {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        },
        presentationChanged: @escaping () -> Void = {
            NotificationCenter.default.post(name: .softwareUpdatePresentationChanged, object: nil)
        }
    ) {
        self.activateApplication = activateApplication
        self.presentationChanged = presentationChanged
    }

    func prepareToPresent() {
        if !isActive {
            generation += 1
            isActive = true
            presentationChanged()
        }
        activateApplication()
    }

    func showUpdate(driverHandlesPresentation: Bool, availableVersion: String? = nil, showInFocus: @escaping () -> Void) {
        if let availableVersion, self.availableVersion != availableVersion {
            self.availableVersion = availableVersion
            if isActive { presentationChanged() }
        }
        prepareToPresent()
        guard !driverHandlesPresentation, queuedFocusGeneration != generation else { return }
        let currentGeneration = generation
        queuedFocusGeneration = currentGeneration
        // Sparkle has created its update alert by this point. Re-enter through
        // its public foreground path after the scheduled callback unwinds.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.generation == currentGeneration else { return }
            showInFocus()
        }
    }

    func finish() {
        guard isActive else { return }
        isActive = false
        availableVersion = nil
        generation += 1
        queuedFocusGeneration = nil
        presentationChanged()
    }
}

/// Overlay the dot rather than rasterizing the menu icon: AppKit continues to
/// tint the original template correctly for light/dark menu bars and selection.
@MainActor
final class UpdateAvailabilityIndicator: NSView {
    static func apply(version: String?, to button: NSButton, updateItem: NSMenuItem) {
        let dot: UpdateAvailabilityIndicator
        if let existing = button.subviews.first(where: { $0 is UpdateAvailabilityIndicator }) as? UpdateAvailabilityIndicator {
            dot = existing
        } else {
            dot = UpdateAvailabilityIndicator(frame: NSRect(x: button.bounds.maxX - 8,
                y: button.isFlipped ? button.bounds.minY + 1 : button.bounds.maxY - 8, width: 7, height: 7))
            dot.autoresizingMask = button.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
            dot.setAccessibilityElement(false)
            button.addSubview(dot)
        }
        dot.isHidden = version == nil
        updateItem.title = version == nil ? "Check for Updates…" : "Update available…"
        let label = version.map { "Dictate Anywhere — Update available (\($0))" } ?? "Dictate Anywhere"
        button.toolTip = label
        button.setAccessibilityLabel(label)
        updateItem.toolTip = version.map { "Version \($0) is available. Open the update window." }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

#if !DEBUG
import Sparkle

@Observable
final class SoftwareUpdater {
    let updaterController: SPUStandardUpdaterController
    let presentation: UpdatePresentationSession
    private let userDriverDelegate: SparkleUserDriverDelegate

    init() {
        let presentation = UpdatePresentationSession()
        self.presentation = presentation
        let delegate = SparkleUserDriverDelegate(presentation: presentation)
        userDriverDelegate = delegate
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        updaterController = controller
        delegate.showUpdateInFocus = { [weak controller] in
            controller?.checkForUpdates(nil)
        }
    }

    func checkForUpdates() {
        presentation.prepareToPresent()
        updaterController.checkForUpdates(nil)
    }
}

@MainActor
private final class SparkleUserDriverDelegate: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    let presentation: UpdatePresentationSession
    var showUpdateInFocus: (() -> Void)?

    init(presentation: UpdatePresentationSession) {
        self.presentation = presentation
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Decline Sparkle's background ordering and use its foreground API.
        false
    }

    func standardUserDriverWillShowModalAlert() {
        presentation.prepareToPresent()
    }

    func standardUserDriverDidShowModalAlert() {
        presentation.prepareToPresent()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        presentation.showUpdate(driverHandlesPresentation: handleShowingUpdate, availableVersion: update.displayVersionString) { [weak self] in
            self?.showUpdateInFocus?()
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        presentation.finish()
    }
}

struct CheckForUpdatesView: View {
    let updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
    }
}
#endif
