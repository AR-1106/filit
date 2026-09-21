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

    /// Insert at the caret without replacing the whole field (keyword expansion).
    func insertAtCaret(_ text: String) throws {
        guard !text.isEmpty else { throw PasteError.empty }
        if setAXSelectedText(text) {
            return
        }
        try pasteViaClipboard(text)
    }

    private func pasteViaClipboard(_ text: String) throws {
        let pb = NSPasteboard.general
        let previousString = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

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
