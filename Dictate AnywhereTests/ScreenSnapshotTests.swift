import XCTest
import SwiftUI
@testable import Dictate_Anywhere_Dev

/// Renders every page inside the full window chrome at the design canvas size
/// (1120×780). Asserts the render succeeds and writes PNGs to the temporary
/// directory for visual inspection (path printed in the test log).
@MainActor
final class ScreenSnapshotTests: XCTestCase {

    private static let outputDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictateAnywhereScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func renderWindow(page: SidebarPage, file: StaticString = #filePath, line: UInt = #line) {
        let appState = AppState()
        appState.selectedPage = page

        let view = MainWindow()
            .environment(appState)
            .frame(width: MainWindowSizing.defaultWidth, height: MainWindowSizing.defaultHeight)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            XCTFail("\(page.title) failed to render", file: file, line: line)
            return
        }
        XCTAssertEqual(image.size.width, MainWindowSizing.defaultWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(image.size.height, MainWindowSizing.defaultHeight, accuracy: 1, file: file, line: line)

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let url = Self.outputDirectory.appendingPathComponent("\(page.rawValue).png")
            try? png.write(to: url)
            print("Screenshot written: \(url.path)")
        }
    }

    func testSpeechModelScreenRenders() { renderWindow(page: .models) }
    func testGeneralScreenRenders() { renderWindow(page: .settings) }
    func testShortcutsScreenRenders() { renderWindow(page: .shortcuts) }
    func testTextOverlayScreenRenders() { renderWindow(page: .textOverlay) }
    func testTranscriptCleanupScreenRenders() { renderWindow(page: .aiPostProcessing) }
    func testHistoryScreenRenders() { renderWindow(page: .history) }
    func testAboutScreenRenders() { renderWindow(page: .about) }
}
