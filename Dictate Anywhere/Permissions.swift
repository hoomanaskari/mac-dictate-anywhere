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

    /// Opens System Settings to Accessibility pane
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
