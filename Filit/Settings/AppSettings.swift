import AppKit
import Carbon
import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let smartPasteKeyCode = "smartPasteKeyCode"
        static let smartPasteModifiers = "smartPasteModifiers"
        static let historyKeyCode = "historyKeyCode"
        static let historyModifiers = "historyModifiers"
        static let includePinnedSource = "includePinnedSource"
        static let alwaysIncludeSnippets = "alwaysIncludeSnippets"
        static let includeClipboardHistory = "includeClipboardHistory"
        static let clipboardItemsForSmartPaste = "clipboardItemsForSmartPaste"
        static let maxCandidates = "maxCandidates"
        static let storedHistorySize = "storedHistorySize"
    }

    @Published var smartPasteShortcut: KeyboardShortcutSpec {
        didSet { persistShortcut(smartPasteShortcut, keyCodeKey: Keys.smartPasteKeyCode, modifiersKey: Keys.smartPasteModifiers) }
    }

    @Published var historyShortcut: KeyboardShortcutSpec {
        didSet { persistShortcut(historyShortcut, keyCodeKey: Keys.historyKeyCode, modifiersKey: Keys.historyModifiers) }
    }

    @Published var includePinnedSource: Bool {
        didSet { UserDefaults.standard.set(includePinnedSource, forKey: Keys.includePinnedSource) }
    }

    @Published var alwaysIncludeSnippets: Bool {
        didSet { UserDefaults.standard.set(alwaysIncludeSnippets, forKey: Keys.alwaysIncludeSnippets) }
    }

    @Published var includeClipboardHistory: Bool {
        didSet { UserDefaults.standard.set(includeClipboardHistory, forKey: Keys.includeClipboardHistory) }
    }

    @Published var clipboardItemsForSmartPaste: Int {
        didSet {
            let clamped = max(0, min(500, clipboardItemsForSmartPaste))
            if clamped != clipboardItemsForSmartPaste {
                clipboardItemsForSmartPaste = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Keys.clipboardItemsForSmartPaste)
        }
    }

    @Published var maxCandidates: Int {
        didSet {
            let clamped = max(1, min(254, maxCandidates))
            if clamped != maxCandidates {
                maxCandidates = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Keys.maxCandidates)
        }
    }

    @Published var storedHistorySize: Int {
        didSet {
            let clamped = max(10, min(5000, storedHistorySize))
            if clamped != storedHistorySize {
                storedHistorySize = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Keys.storedHistorySize)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.includePinnedSource: true,
            Keys.alwaysIncludeSnippets: true,
            Keys.includeClipboardHistory: true,
            Keys.clipboardItemsForSmartPaste: 20,
            Keys.maxCandidates: 32,
            Keys.storedHistorySize: 200,
            Keys.smartPasteKeyCode: Int(KeyboardShortcutSpec.defaultSmartPaste.keyCode),
            Keys.smartPasteModifiers: Int(KeyboardShortcutSpec.defaultSmartPaste.carbonModifiers),
            Keys.historyKeyCode: Int(KeyboardShortcutSpec.defaultHistory.keyCode),
            Keys.historyModifiers: Int(KeyboardShortcutSpec.defaultHistory.carbonModifiers),
        ])

        smartPasteShortcut = KeyboardShortcutSpec(
            keyCode: UInt32(defaults.integer(forKey: Keys.smartPasteKeyCode)),
            carbonModifiers: UInt32(defaults.integer(forKey: Keys.smartPasteModifiers))
        )
        historyShortcut = KeyboardShortcutSpec(
            keyCode: UInt32(defaults.integer(forKey: Keys.historyKeyCode)),
            carbonModifiers: UInt32(defaults.integer(forKey: Keys.historyModifiers))
        )
        includePinnedSource = defaults.bool(forKey: Keys.includePinnedSource)
        alwaysIncludeSnippets = defaults.bool(forKey: Keys.alwaysIncludeSnippets)
        includeClipboardHistory = defaults.bool(forKey: Keys.includeClipboardHistory)
        clipboardItemsForSmartPaste = defaults.integer(forKey: Keys.clipboardItemsForSmartPaste)
        maxCandidates = defaults.integer(forKey: Keys.maxCandidates)
        storedHistorySize = defaults.integer(forKey: Keys.storedHistorySize)
    }

    private func persistShortcut(_ shortcut: KeyboardShortcutSpec, keyCodeKey: String, modifiersKey: String) {
        UserDefaults.standard.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(shortcut.carbonModifiers), forKey: modifiersKey)
        NotificationCenter.default.post(name: .filitHotkeysChanged, object: nil)
    }
}

extension Notification.Name {
    static let filitHotkeysChanged = Notification.Name("filitHotkeysChanged")
}

struct KeyboardShortcutSpec: Equatable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultSmartPaste = KeyboardShortcutSpec(
        keyCode: 9,
        carbonModifiers: UInt32(optionKey | cmdKey)
    )

    static let defaultHistory = KeyboardShortcutSpec(
        keyCode: 2,
        carbonModifiers: UInt32(shiftKey | cmdKey)
    )

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyCodeToGlyph(keyCode))
        return parts.joined()
    }

    static func from(flags: NSEvent.ModifierFlags, keyCode: UInt16) -> KeyboardShortcutSpec {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return KeyboardShortcutSpec(keyCode: UInt32(keyCode), carbonModifiers: carbon)
    }

    private static func keyCodeToGlyph(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        ]
        return map[code] ?? "Key\(code)"
    }
}
