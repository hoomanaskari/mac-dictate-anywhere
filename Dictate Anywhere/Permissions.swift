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
    var accessibilityGranted: Bool = false

    var allGranted: Bool {
        micGranted && accessibilityGranted
    }

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.dictate-anywhere.permissions", qos: .userInitiated)
    private var pollingTimer: Timer?

    // MARK: - Initialization

    init() {
        queue.async { [weak self] in
            self?.checkSync()
        }
    }

    // MARK: - Public Methods

    /// Checks both permissions (async, off MainActor)
    func check() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.checkSync()
                continuation.resume()
            }
        }
    }

    /// Requests microphone permission
    func requestMic() async -> Bool {
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

    /// Refreshes permission state (call periodically or after returning from Settings)
    func refresh() {
        queue.async { [weak self] in
            self?.checkSync()
        }
    }

    /// Starts polling accessibility permission every ~2.5 seconds.
    /// Automatically stops once all permissions are granted.
    func startPolling() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.refresh()
            if self.allGranted {
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
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        DispatchQueue.main.async { [weak self] in
            self?.micGranted = mic
            self?.accessibilityGranted = ax
        }
    }
}
