import Foundation
import AVFoundation
import AppKit

@Observable
final class PermissionChecker {
    var hasMicrophonePermission: Bool = false
    var hasAccessibilityPermission: Bool = false

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    // MARK: - Microphone Permission

    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined, .denied, .restricted:
            hasMicrophonePermission = false
        @unknown default:
            hasMicrophonePermission = false
        }
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            hasMicrophonePermission = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                hasMicrophonePermission = granted
            }
            return granted
        case .denied, .restricted:
            hasMicrophonePermission = false
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Accessibility Permission

    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
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
