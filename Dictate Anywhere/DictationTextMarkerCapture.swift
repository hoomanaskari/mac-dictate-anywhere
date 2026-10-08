import AppKit
import Darwin

/// Rich web editors can expose numeric selection offsets in a different text
/// representation from AXValue. Keep selection, bounds and strings in the
/// same text-marker coordinate system rather than mixing those offsets.
enum DictationTextMarkerCapture {
    nonisolated static func capture(
        in editor: AXUIElement,
        messagingTimeout: Float? = nil
    ) -> (before: String, selected: String, after: String)? {
        if let messagingTimeout { AXUIElementSetMessagingTimeout(editor, messagingTimeout) }
        guard let selection = attribute("AXSelectedTextMarkerRange", in: editor),
              let start = endpoint(selection, start: true), let end = endpoint(selection, start: false),
              let bounds = parameter("AXTextMarkerRangeForUIElement", editor, in: editor),
              let first = endpoint(bounds, start: true), let last = endpoint(bounds, start: false),
              let beforeStart = boundedEndpoint(from: start, to: first, backwards: true, in: editor),
              let selectionEnd = boundedEndpoint(from: start, to: end, backwards: false, in: editor),
              let afterEnd = boundedEndpoint(from: end, to: last, backwards: false, in: editor),
              let before = text(from: beforeStart, to: start, in: editor),
              let selected = text(from: start, to: selectionEnd, in: editor),
              let after = text(from: end, to: afterEnd, in: editor) else { return nil }
        return (String(before.suffix(600)), String(selected.prefix(600)), String(after.prefix(600)))
    }

    nonisolated static func selectionStart(
        in editor: AXUIElement,
        messagingTimeout: Float? = nil
    ) -> CFTypeRef? {
        if let messagingTimeout { AXUIElementSetMessagingTimeout(editor, messagingTimeout) }
        return attribute("AXSelectedTextMarkerRange", in: editor).flatMap { endpoint($0, start: true) }
    }

    private nonisolated static func endpoint(_ range: CFTypeRef, start: Bool) -> CFTypeRef? {
        // Resolve at runtime: native controls/platform versions without these
        // APIs retain the normal AXSelectedTextRange path.
        typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
        typealias RangeTypeID = @convention(c) () -> CFTypeID
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // Darwin RTLD_DEFAULT
        guard let typeSymbol = dlsym(defaultHandle, "AXTextMarkerRangeGetTypeID"),
              CFGetTypeID(range) == unsafeBitCast(typeSymbol, to: RangeTypeID.self)() else { return nil }
        let name = start ? "AXTextMarkerRangeCopyStartMarker" : "AXTextMarkerRangeCopyEndMarker"
        guard let symbol = dlsym(defaultHandle, name) else { return nil }
        return unsafeBitCast(symbol, to: CopyMarker.self)(range)?.takeRetainedValue()
    }

    private nonisolated static func boundedEndpoint(
        from start: CFTypeRef, to boundary: CFTypeRef, backwards: Bool, in editor: AXUIElement
    ) -> CFTypeRef? {
        guard let range = parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, boundary] as CFArray, in: editor),
              let length = parameter("AXLengthForTextMarkerRange", range, in: editor) as? NSNumber,
              length.intValue >= 0 else { return nil }
        if length.intValue <= 600 { return boundary }
        // Never convert rich-text markers to numeric offsets and back: web
        // implementations may count embedded objects differently in those APIs.
        let operation = backwards ? "AXPreviousTextMarkerForTextMarker" : "AXNextTextMarkerForTextMarker"
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var current = start
        for _ in 0..<600 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let next = parameter(operation, current, in: editor), !CFEqual(next, current) else { break }
            current = next
        }
        return current
    }

    private nonisolated static func text(from start: CFTypeRef, to end: CFTypeRef, in editor: AXUIElement) -> String? {
        guard let range = parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray, in: editor) else { return nil }
        return parameter("AXStringForTextMarkerRange", range, in: editor) as? String
    }

    private nonisolated static func attribute(_ name: String, in editor: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func parameter(_ name: String, _ argument: CFTypeRef, in editor: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(editor, name as CFString, argument, &value) == .success else { return nil }
        return value
    }
}
