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
    func typeAtCaret(_ text: String, syntheticTag: Int64) throws {
        guard !text.isEmpty else { throw PasteError.empty }

        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() {
            postUnicodeChunks(String(line), source: source, tag: syntheticTag)
            if index < lines.count - 1 {
                postKey(36, source: source, tag: syntheticTag)
            }
        }
    }

    private func postUnicodeChunks(_ text: String, source: CGEventSource?, tag: Int64) {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }
        let chunkSize = 16
        var start = 0
        while start < units.count {
            let end = min(start + chunkSize, units.count)
            var chunk = Array(units[start..<end])
            chunk.withUnsafeMutableBufferPointer { buf in
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
            start = end
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

    /// Cmd+V after the caller has already restored the pasteboard.
    func pasteCommandV() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
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
