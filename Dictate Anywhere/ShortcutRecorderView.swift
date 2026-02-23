//
//  ShortcutRecorderView.swift
//  Dictate Anywhere
//
//  Key combo capture widget using CGEvent tap.
//

import SwiftUI
import CoreGraphics

struct ShortcutRecorderView: View {
    let displayName: String
    let onRecord: (UInt16?, CGEventFlags, String) -> Void
    let onClear: () -> Void
    let onRecordingStarted: () -> Void
    let onRecordingStopped: () -> Void

    @State private var isRecording = false
    @State private var recorder = ShortcutRecorder()

    init(
        displayName: String,
        onRecord: @escaping (UInt16?, CGEventFlags, String) -> Void,
        onClear: @escaping () -> Void,
        onRecordingStarted: @escaping () -> Void = {},
        onRecordingStopped: @escaping () -> Void = {}
    ) {
        self.displayName = displayName
        self.onRecord = onRecord
        self.onClear = onClear
        self.onRecordingStarted = onRecordingStarted
        self.onRecordingStopped = onRecordingStopped
    }

    var body: some View {
        HStack(spacing: 12) {
            if isRecording {
                Text("Press any key combo...")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else if displayName.isEmpty {
                Text("Not Set")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(displayName)
                    .font(.system(.body, design: .rounded, weight: .medium))
            }

            Spacer()

            if isRecording {
                Button("Cancel") {
                    stopRecording()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(displayName.isEmpty ? "Record Shortcut" : "Change") {
                    startRecording()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if !displayName.isEmpty {
                    Button("Clear", role: .destructive) {
                        onClear()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingStarted()
        recorder.start { keyCode, modifiers, name in
            onRecord(keyCode, modifiers, name)
            isRecording = false
            onRecordingStopped()
        } onCancel: {
            isRecording = false
            onRecordingStopped()
        }
    }

    private func stopRecording() {
        recorder.stop()
        isRecording = false
        onRecordingStopped()
    }
}

// MARK: - ShortcutRecorder (CGEvent-based)

@Observable
final class ShortcutRecorder {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onCapture: ((UInt16?, CGEventFlags, String) -> Void)?
    private var onCancel: (() -> Void)?
    private var pendingModifierFlags = CGEventFlags(rawValue: 0)
    private let functionKeyCodes: Set<UInt16> = [63, 179]

    func start(onCapture: @escaping (UInt16?, CGEventFlags, String) -> Void, onCancel: @escaping () -> Void) {
        stop()
        self.onCapture = onCapture
        self.onCancel = onCancel

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: recorderCallback,
            userInfo: selfPtr
        ) else {
            startLocalMonitor()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pendingModifierFlags = CGEventFlags(rawValue: 0)
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        onCapture = nil
        onCancel = nil
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            handleKeyDown(event)
        case .flagsChanged:
            handleFlagsChanged(event.flags)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == 53 {
            DispatchQueue.main.async { [weak self] in
                self?.onCancel?()
                self?.stop()
            }
            return
        }

        // Normalize fn/globe into a modifier-only shortcut so it can be matched reliably.
        if functionKeyCodes.contains(keyCode) {
            var fnModifiers = Settings.normalizedModifierFlags(event.flags)
            fnModifiers.insert(.maskSecondaryFn)
            capture(keyCode: nil, modifiers: fnModifiers)
            return
        }

        capture(keyCode: keyCode, modifiers: event.flags)
    }

    private func handleFlagsChanged(_ flags: CGEventFlags) {
        let modifiers = Settings.normalizedModifierFlags(flags)
        if !modifiers.isEmpty {
            if pendingModifierFlags.isEmpty || modifiers.isSuperset(of: pendingModifierFlags) {
                pendingModifierFlags = modifiers
            }
            return
        }

        guard !pendingModifierFlags.isEmpty else { return }
        let capturedModifiers = pendingModifierFlags
        pendingModifierFlags = CGEventFlags(rawValue: 0)
        capture(keyCode: nil, modifiers: capturedModifiers)
    }

    private func capture(keyCode: UInt16?, modifiers: CGEventFlags) {
        let normalizedModifiers = Settings.normalizedModifierFlags(modifiers)
        let displayName = Settings.displayName(keyCode: keyCode, modifiers: normalizedModifiers)
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(keyCode, normalizedModifiers, displayName)
            self?.stop()
        }
    }

    // MARK: - Local Monitor Fallback

    private var localMonitor: Any?

    private func startLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .flagsChanged {
                let modifiers = Self.cgFlags(from: event.modifierFlags)
                if !modifiers.isEmpty {
                    if self.pendingModifierFlags.isEmpty || modifiers.isSuperset(of: self.pendingModifierFlags) {
                        self.pendingModifierFlags = modifiers
                    }
                    return event
                }

                guard !self.pendingModifierFlags.isEmpty else { return event }
                let capturedModifiers = self.pendingModifierFlags
                self.pendingModifierFlags = CGEventFlags(rawValue: 0)
                let displayName = Settings.displayName(keyCode: nil, modifiers: capturedModifiers)
                self.onCapture?(nil, capturedModifiers, displayName)
                self.stop()
                return nil
            }

            let keyCode = event.keyCode

            if keyCode == 53 {
                self.onCancel?()
                self.stop()
                return nil
            }

            if self.functionKeyCodes.contains(keyCode) {
                var fnModifiers = Self.cgFlags(from: event.modifierFlags)
                fnModifiers.insert(.maskSecondaryFn)
                let displayName = Settings.displayName(keyCode: nil, modifiers: fnModifiers)
                self.onCapture?(nil, fnModifiers, displayName)
                self.stop()
                return nil
            }

            let cgFlags = Self.cgFlags(from: event.modifierFlags)

            let displayName = Settings.displayName(keyCode: keyCode, modifiers: cgFlags)
            self.onCapture?(keyCode, cgFlags, displayName)
            self.stop()
            return nil
        }
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        let relevant = flags.intersection(.deviceIndependentFlagsMask)
        var cgFlags = CGEventFlags(rawValue: 0)
        if relevant.contains(.command) { cgFlags.insert(.maskCommand) }
        if relevant.contains(.control) { cgFlags.insert(.maskControl) }
        if relevant.contains(.option) { cgFlags.insert(.maskAlternate) }
        if relevant.contains(.shift) { cgFlags.insert(.maskShift) }
        if relevant.contains(.function) { cgFlags.insert(.maskSecondaryFn) }
        return cgFlags
    }
}

// MARK: - C Callback

private func recorderCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = recorder.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown || type == .flagsChanged {
        let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        recorder.handleEvent(type: type, event: event)
    }

    return Unmanaged.passUnretained(event)
}
