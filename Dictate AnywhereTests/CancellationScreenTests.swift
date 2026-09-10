import XCTest
import SwiftUI
@testable import Dictate_Anywhere

@MainActor
final class CancellationScreenTests: XCTestCase {
    /// ImageRenderer omits native scroll-view content, so use a real hosting
    /// window for these screenshots and inspect the resulting settings/history.
    private func render<V: View>(_ view: V, name: String, size: NSSize) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-\(name).png")
        try png.write(to: url)
        print("CANCELLATION_SCREENSHOT \(url.path)")
    }

    func testCancellationSettingsRender() async throws {
        let settings = Settings.shared
        let oldBindings = settings.hotkeyBindings
        let oldCancel = settings.cancelShortcut
        defer {
            settings.hotkeyBindings = oldBindings
            settings.cancelShortcut = oldCancel
        }
        settings.hotkeyBindings = [.defaultBinding]
        settings.cancelShortcut = .defaultCancelBinding
        try await render(ShortcutsView().environment(AppState()), name: "cancellation-settings",
                         size: NSSize(width: 850, height: 820))
    }

    func testCancelledHistoryAndHoldProgressRender() async throws {
        let oldHistory = Settings.shared.transcriptHistory
        Settings.shared.transcriptHistory = []
        defer { Settings.shared.transcriptHistory = oldHistory }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-screen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let capture = try store.beginCapture()
        capture.append(Array(repeating: 0.1, count: 16_000))
        _ = try await store.preserve(capture, preview: "I was describing a change while working in another app.", completedTranscript: nil)
        try await render(TranscriptHistoryView().environment(AppState(recoveryStore: store)),
                         name: "cancelled-history", size: NSSize(width: 850, height: 620))
        // Native glass is composited outside cacheDisplay; inspect its actual
        // progress content separately against a solid background.
        try await render(CancellationProgressView(progress: 0.55, tint: .white).background(Color.gray),
                         name: "cancel-hold", size: NSSize(width: 200, height: 50))
    }
}
