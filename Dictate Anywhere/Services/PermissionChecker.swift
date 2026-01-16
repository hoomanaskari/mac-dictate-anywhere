import Foundation
import AVFoundation
import AppKit

@Observable
final class PermissionChecker {
    var hasMicrophonePermission: Bool = false
    var hasAccessibilityPermission: Bool = false

    /// Background queue for permission checks to avoid blocking MainActor
    private let permissionQueue = DispatchQueue(label: "com.dictate-anywhere.permissions", qos: .userInitiated)

    init() {
        // Check permissions in background to avoid blocking MainActor on startup
        permissionQueue.async { [weak self] in
            self?.checkPermissionsSync()
        }
    }

    /// Checks permissions asynchronously (runs off MainActor)
    func checkPermissions() {
        permissionQueue.async { [weak self] in
            self?.checkPermissionsSync()
        }
    }

    /// Checks permissions and waits for completion (async version)
    func checkPermissionsAsync() async {
        await withCheckedContinuation { continuation in
            permissionQueue.async { [weak self] in
                self?.checkPermissionsSync()
                continuation.resume()
            }
        }
    }

    /// Synchronous version for background queue use only
    private func checkPermissionsSync() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let hasMic = micStatus == .authorized
        let hasAx = AXIsProcessTrusted()

        DispatchQueue.main.async { [weak self] in
            self?.hasMicrophonePermission = hasMic
            self?.hasAccessibilityPermission = hasAx
        }
    }

    // MARK: - Microphone Permission

    func checkMicrophonePermission() {
        permissionQueue.async { [weak self] in
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let hasMic = status == .authorized

            DispatchQueue.main.async {
                self?.hasMicrophonePermission = hasMic
            }
        }
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            await MainActor.run {
                hasMicrophonePermission = true
            }
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                hasMicrophonePermission = granted
            }
            return granted
        case .denied, .restricted:
            await MainActor.run {
                hasMicrophonePermission = false
            }
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Accessibility Permission

    func checkAccessibilityPermission() {
        permissionQueue.async { [weak self] in
            let hasAx = AXIsProcessTrusted()

            DispatchQueue.main.async {
                self?.hasAccessibilityPermission = hasAx
            }
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
    }

    // MARK: - Open System Settings

    func openMicrophoneSettings() {
        // macOS 13+ URL scheme
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        // Use the direct path to Accessibility pane in System Settings
        // This works on macOS 13+
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ?? URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")

        if let url = url {
            NSWorkspace.shared.open(url)
        } else {
            // Fallback: open System Settings directly via shell
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
            try? task.run()
        }
    }

    var allPermissionsGranted: Bool {
        hasMicrophonePermission && hasAccessibilityPermission
    }
}
