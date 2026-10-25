import AppKit
import os

/// Web editors expose rendered list markers as AXList/AXListMarker nodes, not
/// necessarily in AXValue or AXStringForRange. Resolve the cursor's own item via
/// the editor's text-marker API; never infer a list from unrelated blank lines.
enum DictationRichListCapture {
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pixelforty.dictate-anywhere", category: "RichListCapture"
    )
    nonisolated static func capture(in editor: AXUIElement, selectedRange: CFRange) -> DictationListInsertion? {
        guard selectedRange.location >= 0, selectedRange.length == 0,
              let marker = DictationTextMarkerCapture.selectionStart(in: editor)
                ?? parameter("AXTextMarkerForIndex", NSNumber(value: selectedRange.location), in: editor),
              DictationTextMarkerCapture.markerIsInsideEditor(marker, in: editor),
              let rawNode = parameter("AXUIElementForTextMarker", marker, in: editor),
              CFGetTypeID(rawNode) == AXUIElementGetTypeID() else { return nil }

        var item = rawNode as! AXUIElement
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        for _ in 0..<8 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  !CFEqual(item, editor),
                  let rawParent = attribute(kAXParentAttribute, in: item),
                  CFGetTypeID(rawParent) == AXUIElementGetTypeID() else {
                logger.info("richListCapture: stopped before a list ancestor; atEditor=\(CFEqual(item, editor))")
                return nil
            }
            let parent = rawParent as! AXUIElement
            AXUIElementSetMessagingTimeout(parent, 0.05)
            if attribute(kAXRoleAttribute, in: parent) as? String == "AXList" {
                guard let itemText = text(of: item, in: editor),
                      let siblings = attribute(kAXChildrenAttribute, in: parent) as? [AXUIElement],
                      let index = siblings.firstIndex(where: { CFEqual($0, item) }) else { return nil }
                let result = DictationListInsertion.emptyStructuralItem(
                    itemText: itemText,
                    previousItemText: index > 0 ? text(of: siblings[index - 1], in: editor) : nil,
                    nextItemText: index + 1 < siblings.count ? text(of: siblings[index + 1], in: editor) : nil
                )
                logger.info("richListCapture: found list; emptyItem=\(result != nil)")
                return result
            }
            item = parent
        }
        logger.info("richListCapture: ancestor depth limit")
        return nil
    }

    private nonisolated static func text(of item: AXUIElement, in editor: AXUIElement) -> String? {
        guard let range = parameter("AXTextMarkerRangeForUIElement", item, in: editor),
              let text = parameter("AXStringForTextMarkerRange", range, in: editor) as? String else { return nil }
        // Do not derive formatting from a truncated or unusually large item.
        guard text.count <= 600 else { return nil }
        return text
    }

    private nonisolated static func attribute(_ name: String, in element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func parameter(_ name: String, _ argument: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
        guard status == .success else {
            logger.info("richListCapture: API=\(name, privacy: .public) status=\(status.rawValue)")
            return nil
        }
        return value
    }
}
