import AppKit
import ApplicationServices
import Foundation

struct FieldContext: Equatable {
    var label: String
    var placeholder: String
    var role: String
    var description: String
    var value: String
    var nearby: String

    var summary: String {
        [label, placeholder, role, description, nearby]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    var searchBlob: String {
        [label, placeholder, description, nearby, role]
            .joined(separator: " ")
            .lowercased()
    }
}

enum AccessibilityFieldReader {
    static func ensurePermission(prompt: Bool = true) -> Bool {
        if !prompt {
            return AXIsProcessTrusted()
        }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func focusedField() -> FieldContext {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return FieldContext(label: "", placeholder: "", role: "", description: "", value: "", nearby: "")
        }

        let element = focused as! AXUIElement
        let label = firstString(element, [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            "AXLabel",
            kAXHelpAttribute as String,
        ])
        let placeholder = stringAttr(element, "AXPlaceholderValue")
        let role = stringAttr(element, kAXRoleAttribute as String)
        let description = stringAttr(element, kAXDescriptionAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let nearby = nearbyText(for: element)

        // Also try linked label via AXTitleUIElement
        var titleUI: CFTypeRef?
        var linkedTitle = ""
        if AXUIElementCopyAttributeValue(element, "AXTitleUIElement" as CFString, &titleUI) == .success,
           let titleElement = titleUI {
            linkedTitle = stringAttr(titleElement as! AXUIElement, kAXValueAttribute as String)
            if linkedTitle.isEmpty {
                linkedTitle = stringAttr(titleElement as! AXUIElement, kAXTitleAttribute as String)
            }
        }

        let combinedLabel = [label, linkedTitle].first(where: { !$0.isEmpty }) ?? ""

        return FieldContext(
            label: combinedLabel,
            placeholder: placeholder,
            role: role,
            description: description,
            value: value,
            nearby: nearby
        )
    }

    private static func nearbyText(for element: AXUIElement) -> String {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef else { return "" }
        let parentElement = parent as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parentElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return "" }

        var parts: [String] = []
        for child in children.prefix(12) {
            let role = stringAttr(child, kAXRoleAttribute as String)
            if role.contains("StaticText") || role.contains("Text") || role.contains("Button") {
                let t = firstString(child, [kAXValueAttribute as String, kAXTitleAttribute as String])
                if !t.isEmpty { parts.append(t) }
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringAttr(_ element: AXUIElement, _ name: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref else { return "" }
        if let s = ref as? String { return s }
        if CFGetTypeID(ref) == CFStringGetTypeID() {
            return (ref as! CFString) as String
        }
        return ""
    }

    private static func firstString(_ element: AXUIElement, _ names: [String]) -> String {
        for name in names {
            let value = stringAttr(element, name)
            if !value.isEmpty { return value }
        }
        return ""
    }
}
