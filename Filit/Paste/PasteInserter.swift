import AppKit
import ApplicationServices
import Foundation

enum PasteError: LocalizedError {
    case empty
    case failed

    var errorDescription: String? {
        switch self {
        case .empty: return "Nothing to paste"
        case .failed: return "Could not insert text into the focused field"
        }
    }
}

final class PasteInserter {
    func insert(_ text: String) throws {
        guard !text.isEmpty else { throw PasteError.empty }

        if setAXValue(text) {
            return
        }

        try pasteViaClipboard(text)
    }

    /// Type at the caret. Does not use or change the clipboard.
    /// Chunks are ≤4 UTF-16 units so Chromium/Blink targets don't drop characters.
    func typeAtCaret(_ text: String, syntheticTag: Int64) throws {
        guard !text.isEmpty else { throw PasteError.empty }

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            postUnicodeChunks(String(line), source: source, tag: syntheticTag)
            if index < lines.count - 1 {
                postKey(36, source: source, tag: syntheticTag) // Return
            }
        }
    }

    /// Snapshot the pasteboard, lend plain text + marker, ⌘V, restore if still ours.
    @MainActor
    func pasteTemporarily(
        _ text: String,
        syntheticTag: Int64,
        clipboard: ClipboardHistoryStore
    ) async throws {
        guard !text.isEmpty else { throw PasteError.empty }

        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pb)

        clipboard.prepareForInternalMutation()
        pb.clearContents()
        pb.declareTypes([.string, ClipboardHistoryStore.internalType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardHistoryStore.internalType)
        clipboard.synchronizeAfterInternalMutation(changeCount: pb.changeCount)

        try pasteCommandV(syntheticTag: syntheticTag)
        try? await Task.sleep(for: .milliseconds(120))

        // Only restore if nothing newer landed.
        if pb.changeCount == clipboard.lastSyncedChangeCount || pb.types?.contains(ClipboardHistoryStore.internalType) == true {
            snapshot.restore(to: pb)
            clipboard.synchronizeAfterInternalMutation(changeCount: pb.changeCount)
        }
    }

    private func postUnicodeChunks(_ text: String, source: CGEventSource?, tag: Int64) {
        for chunk in UnicodeTypingChunk.split(text) {
            var units = chunk
            units.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                down?.setIntegerValueField(.eventSourceUserData, value: tag)
                up?.setIntegerValueField(.eventSourceUserData, value: tag)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    private func postKey(_ key: CGKeyCode, source: CGEventSource?, tag: Int64) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.setIntegerValueField(.eventSourceUserData, value: tag)
        up?.setIntegerValueField(.eventSourceUserData, value: tag)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func pasteCommandV(syntheticTag: Int64? = nil) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        if let syntheticTag {
            down?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            up?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        }
        guard down != nil, up != nil else { throw PasteError.failed }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func pasteViaClipboard(_ text: String) throws {
        let pb = NSPasteboard.general
        let previousString = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        try pasteCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
            if let previousString {
                pb.setString(previousString, forType: .string)
            }
        }
    }

    private func setAXValue(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
            return status == .success
        }

        return setAXSelectedText(text)
    }

    private func setAXSelectedText(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }
}

/// Full pasteboard snapshot so a temporary snippet paste doesn't leave HTML/RTF from the prior copy.
struct PasteboardSnapshot {
    private struct Item {
        var types: [NSPasteboard.PasteboardType]
        var data: [NSPasteboard.PasteboardType: Data]
        var strings: [NSPasteboard.PasteboardType: String]
    }

    private let items: [Item]

    static func capture(from pb: NSPasteboard) -> PasteboardSnapshot {
        let rawItems = pb.pasteboardItems ?? []
        let items: [Item] = rawItems.map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            var strings: [NSPasteboard.PasteboardType: String] = [:]
            let types = item.types
            for type in types {
                if let value = item.string(forType: type) {
                    strings[type] = value
                } else if let value = item.data(forType: type) {
                    data[type] = value
                }
            }
            return Item(types: types, data: data, strings: strings)
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pb: NSPasteboard) {
        guard !items.isEmpty else {
            pb.clearContents()
            return
        }
        let objects: [NSPasteboardItem] = items.map { item in
            let pbItem = NSPasteboardItem()
            for type in item.types {
                if let string = item.strings[type] {
                    pbItem.setString(string, forType: type)
                } else if let data = item.data[type] {
                    pbItem.setData(data, forType: type)
                }
            }
            return pbItem
        }
        pb.clearContents()
        pb.writeObjects(objects)
    }
}
