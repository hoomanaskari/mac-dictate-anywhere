//
//  MainWindowSizing.swift
//  Dictate Anywhere
//
//  Shared sizing constants for the main app window.
//

import CoreGraphics

enum MainWindowSizing {
    /// Default window size, matching the design canvas (1120×780).
    static let defaultWidth: CGFloat = 1120
    static let defaultHeight: CGFloat = 780
    static let minimumWidth: CGFloat = 940
    static let minimumHeight: CGFloat = 640
    static let maximumWidth: CGFloat = defaultWidth * 2
    static let maximumHeight: CGFloat = defaultHeight * 2
}
