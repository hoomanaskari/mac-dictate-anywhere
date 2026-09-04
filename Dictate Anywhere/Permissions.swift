//
//  Permissions.swift
//  Dictate Anywhere
//
//  Microphone and Accessibility permission checks.
//

import Foundation
import AVFoundation
import AppKit

@Observable
final class Permissions {
    // MARK: - State

    var micGranted: Bool = false
    var accessibilityGranted: Bool = false {
        didSet {
            guard oldValue != accessibilityGranted else { return }
            onAccessibilityPermissionChanged?(accessibilityGranted)
        }
    }

    var allGranted: Bool {
        micGranted && accessibilityGranted
    }

    var onAccessibilityPermissionChanged: ((Bool) -> Void)?

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.dictate-anywhere.permissions", qos: .userInitiated)
    private var pollingTimer: Timer?
    private let statusProvider: @Sendable () -> (mic: Bool, accessibility: Bool)

    // MARK: - Initialization

    init(statusProvider: (@Sendable () -> (mic: Bool, accessibility: Bool))? = nil) {
        self.statusProvider = statusProvider ?? Self.currentStatus
        queue.async { [weak self] in
            self?.checkSync()
        }
    }

    // MARK: - Public Methods

    /// Checks both permissions (async, off MainActor)
    func check() async {
        let provider = statusProvider
        let (mic, accessibility) = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard self != nil else {
                    continuation.resume(returning: (false, false))
                    return
                }
                continuation.resume(returning: provider())
            }
        }
        await MainActor.run {
            self.micGranted = mic
            self.accessibilityGranted = accessibility
        }
    }

    /// Requests microphone permission
    func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            await MainActor.run {
                self.micGranted = true
            }
            return true
        case .denied, .restricted:
            openMicrophoneSettings()
            return false
        case .notDetermined:
            break
        @unknown default:
            openMicrophoneSettings()
            return false
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            self.micGranted = granted
        }
        return granted
    }

    /// Prompts the user to grant Accessibility permission via the system dialog.
    /// This calls AXIsProcessTrustedWithOptions which adds the app to the Accessibility
    /// list and shows the macOS "wants to control your computer" prompt.
    @discardableResult
    func promptForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
        return granted
    }

    /// Opens System Settings to Accessibility pane (fallback for manual add).
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Microphone pane after a previous denial.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Refreshes permission state (call periodically or after returning from Settings)
    func refresh() async {
        await check()
    }

    /// Starts polling accessibility permission every ~2.5 seconds.
    /// Automatically stops once all permissions are granted.
    func startPolling() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
                guard self.allGranted else { return }
                self.stopPolling()
            }
        }
    }

    /// Stops accessibility permission polling.
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Private

    private func checkSync() {
        let (mic, ax) = statusProvider()
        DispatchQueue.main.async { [weak self] in
            self?.micGranted = mic
            self?.accessibilityGranted = ax
        }
    }

    /// Runs on the private background queue via `queue.async`, never on the main actor.
    private nonisolated static func currentStatus() -> (mic: Bool, accessibility: Bool) {
        (
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            AXIsProcessTrusted()
        )
    }
}
