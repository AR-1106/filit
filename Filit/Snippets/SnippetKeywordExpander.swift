import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// MARK: - Keyword matching (Tinycast-style)

struct SnippetKeywordPolicy: Sendable {
    struct Keyword: Equatable, Sendable {
        let snippetID: UUID
        let value: String
        let deletionCount: Int

        init(snippetID: UUID, value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            self.snippetID = snippetID
            self.value = trimmed.lowercased()
            self.deletionCount = trimmed.count
        }
    }

    struct Match: Equatable, Sendable {
        let snippetID: UUID
        let keyword: String
        let deletionCount: Int
    }

    enum Input: Equatable, Sendable {
        case text(String)
        case deleteBackward
        case reset
        case ignored
    }

    static let timeout: TimeInterval = 15
    static let maximumBufferLength = 256

    private(set) var keywords: [Keyword] = []
    private(set) var buffer = ""
    private var lastInputAt: Date?

    mutating func update(_ keywords: [Keyword]) {
        self.keywords = keywords
            .filter { !$0.value.isEmpty && $0.deletionCount <= Self.maximumBufferLength }
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.snippetID.uuidString < $1.snippetID.uuidString
            }
        reset()
    }

    /// Longest suffix match. Keyword characters are already in the target app (listen-only tap).
    mutating func process(_ input: Input, at now: Date) -> Match? {
        if case .ignored = input { return nil }
        if let lastInputAt, now.timeIntervalSince(lastInputAt) > Self.timeout {
            reset()
        }

        switch input {
        case .ignored:
            return nil
        case .reset:
            reset()
            return nil
        case .deleteBackward:
            lastInputAt = now
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        case .text(let text):
            lastInputAt = now
            buffer.append(text)
            if buffer.count > Self.maximumBufferLength {
                buffer.removeFirst(buffer.count - Self.maximumBufferLength)
            }
        }

        let normalizedBuffer = buffer.lowercased()
        guard let keyword = keywords.first(where: { normalizedBuffer.hasSuffix($0.value) }) else {
            return nil
        }
        reset()
        return Match(
            snippetID: keyword.snippetID,
            keyword: keyword.value,
            deletionCount: keyword.deletionCount
        )
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        lastInputAt = nil
    }

    static func classifyInput(
        text: String?,
        isSynthetic: Bool,
        secureEventInputEnabled: Bool,
        isFlagsChanged: Bool,
        isKeyDown: Bool,
        hasCommandOrControl: Bool,
        isResetKey: Bool,
        isDeleteBackward: Bool
    ) -> Input {
        if isSynthetic { return .ignored }
        if secureEventInputEnabled || hasCommandOrControl || isResetKey { return .reset }
        if isFlagsChanged { return .ignored }
        guard isKeyDown else { return .ignored }
        if isDeleteBackward { return .deleteBackward }
        guard let text, !text.isEmpty else { return .reset }
        return .text(text)
    }
}

// MARK: - Template expansion

enum SnippetTemplateEngine {
    static func expand(_ template: String) -> String {
        var result = template
        let now = Date()

        result = replaceToken(result, name: "clipboard") {
            NSPasteboard.general.string(forType: .string) ?? ""
        }
        result = replaceToken(result, name: "selection") {
            selectedText() ?? ""
        }
        result = replaceToken(result, name: "selectedText") {
            selectedText() ?? ""
        }
        result = replaceToken(result, name: "date") {
            now.formatted(date: .abbreviated, time: .omitted)
        }
        result = replaceToken(result, name: "time") {
            now.formatted(date: .omitted, time: .shortened)
        }
        result = replaceToken(result, name: "datetime") {
            now.formatted(date: .abbreviated, time: .shortened)
        }
        result = replaceToken(result, name: "day") {
            now.formatted(.dateTime.weekday(.wide))
        }
        result = replaceUUID(result)
        result = result.replacingOccurrences(of: "{cursor}", with: "")
        return result
    }

    private static func replaceToken(_ source: String, name: String, value: () -> String) -> String {
        let pattern = "\\{\(NSRegularExpression.escapedPattern(for: name))\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        let replacement = NSRegularExpression.escapedTemplate(for: value())
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: replacement)
    }

    private static func replaceUUID(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{uuid\}"#) else { return source }
        var result = source
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            result.replaceSubrange(range, with: UUID().uuidString.lowercased())
        }
        return result
    }

    private static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let selected = selectedRef as? String else { return nil }
        return selected
    }
}

// MARK: - Four-unit unicode chunks (Chromium / Blink limit)

enum UnicodeTypingChunk {
    static let maxUTF16Units = 4

    static func split(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maxUTF16Units)
        for scalar in text.unicodeScalars {
            if current.count + UTF16.width(scalar) > maxUTF16Units {
                chunks.append(current)
                current = []
            }
            UTF16.encode(scalar) { current.append($0) }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Keyword listener (listen-only, Tinycast-style)

@MainActor
final class SnippetKeywordExpander {
    /// Stamped on Filit's synthetic keystrokes so the tap can ignore them.
    static let syntheticTag: Int64 = 0x46494C54 // "FILT"

    private static weak var active: SnippetKeywordExpander?

    private let snippets: SnippetStore
    private let pasteInserter: PasteInserter
    private let clipboard: ClipboardHistoryStore

    private var policy = SnippetKeywordPolicy()
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matchTask: Task<Void, Never>?
    private var isExpanding = false
    private var lastKeywordFingerprint = ""
    private var observers: [NSObjectProtocol] = []

    private static let resetKeyCodes: Set<Int> = [
        kVK_Return,
        kVK_ANSI_KeypadEnter,
        kVK_Escape,
        kVK_Tab,
        kVK_LeftArrow,
        kVK_RightArrow,
        kVK_UpArrow,
        kVK_DownArrow,
        kVK_Home,
        kVK_End,
        kVK_PageUp,
        kVK_PageDown,
        kVK_ForwardDelete,
    ]

    init(snippets: SnippetStore, pasteInserter: PasteInserter, clipboard: ClipboardHistoryStore) {
        self.snippets = snippets
        self.pasteInserter = pasteInserter
        self.clipboard = clipboard
    }

    func start() {
        stop()
        Self.active = self
        refreshKeywords()
        installObservers()
        installTapIfNeeded()
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        matchTask?.cancel()
        matchTask = nil
        tearDownTap()
        policy.reset()
        isExpanding = false
    }

    func refreshKeywords() {
        let keywords = snippets.items.compactMap { snippet -> SnippetKeywordPolicy.Keyword? in
            let raw = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !snippet.text.isEmpty else { return nil }
            return .init(snippetID: snippet.id, value: raw)
        }
        policy.update(keywords)
        lastKeywordFingerprint = fingerprint(for: snippets.items)
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default

        observers = [
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.clearBuffer() }
            },
            workspace.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.clearBuffer()
                    self?.tearDownTap()
                }
            },
            workspace.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.clearBuffer()
                    self?.installTapIfNeeded()
                }
            },
            appCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.installTapIfNeeded() }
            },
        ]
    }

    private func clearBuffer() {
        matchTask?.cancel()
        matchTask = nil
        policy.reset()
    }

    private func installTapIfNeeded() {
        guard AccessibilityFieldReader.isTrusted else { return }
        guard tapPort == nil else {
            if let tapPort, !CGEvent.tapIsEnabled(tap: tapPort) {
                CGEvent.tapEnable(tap: tapPort, enable: true)
            }
            return
        }

        // Listen-only: keyword characters reach the target app; we delete them on match.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                SnippetKeywordExpander.handleTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            NSLog("Filit: could not create snippet keyword event tap (needs Accessibility)")
            return
        }

        tapPort = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func tearDownTap() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tapPort = nil
    }

    private struct EventSnapshot: Sendable {
        var typeRaw: UInt32
        var keyCode: Int
        var flagsRaw: UInt64
        var userData: Int64
        var text: String?
        var secure: Bool
    }

    nonisolated private static func handleTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let tapPort = Self.active?.tapPort {
                    CGEvent.tapEnable(tap: tapPort, enable: true)
                }
            }
            return
        }

        let snapshot = EventSnapshot(
            typeRaw: type.rawValue,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flagsRaw: event.flags.rawValue,
            userData: event.getIntegerValueField(.eventSourceUserData),
            text: event.keyboardString(),
            secure: IsSecureEventInputEnabled()
        )

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.active?.process(snapshot)
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Self.active?.process(snapshot)
                }
            }
        }
    }

    private func process(_ event: EventSnapshot) {
        if isExpanding { return }

        let type = CGEventType(rawValue: event.typeRaw) ?? .null

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            clearBuffer()
            return
        }

        refreshKeywordsIfNeeded()

        let flags = CGEventFlags(rawValue: event.flagsRaw)
        let input = SnippetKeywordPolicy.classifyInput(
            text: event.text,
            isSynthetic: event.userData == Self.syntheticTag,
            secureEventInputEnabled: event.secure,
            isFlagsChanged: type == .flagsChanged,
            isKeyDown: type == .keyDown,
            hasCommandOrControl: flags.contains(.maskCommand) || flags.contains(.maskControl),
            isResetKey: Self.resetKeyCodes.contains(event.keyCode),
            isDeleteBackward: event.keyCode == kVK_Delete
        )

        guard let match = policy.process(input, at: Date()) else { return }

        // Head-insert tap fires before the keystroke reaches the app — let it land first.
        matchTask?.cancel()
        matchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            await self.deliver(match)
        }
    }

    private func refreshKeywordsIfNeeded() {
        let next = fingerprint(for: snippets.items)
        guard next != lastKeywordFingerprint else { return }
        refreshKeywords()
    }

    private func fingerprint(for items: [Snippet]) -> String {
        items.map { "\($0.id.uuidString):\($0.keyword):\($0.text.count)" }.joined(separator: "|")
    }

    private func deliver(_ match: SnippetKeywordPolicy.Match) async {
        guard AccessibilityFieldReader.isTrusted else { return }
        guard let snippet = snippets.items.first(where: { $0.id == match.snippetID }) else { return }

        // Filit's own key window — don't expand into the launcher/settings.
        if NSApp.keyWindow != nil { return }

        let expanded = SnippetTemplateEngine.expand(snippet.text)
        guard !expanded.isEmpty else { return }

        isExpanding = true
        defer { isExpanding = false }

        if match.deletionCount > 0 {
            await postDeletes(count: match.deletionCount)
            try? await Task.sleep(for: .milliseconds(40))
        }

        let isShortSingleLine =
            expanded.count <= 100
            && !expanded.contains("\n")
            && !expanded.contains("\r")

        if isShortSingleLine {
            try? pasteInserter.typeAtCaret(expanded, syntheticTag: Self.syntheticTag)
        } else {
            try? await pasteInserter.pasteTemporarily(
                expanded,
                syntheticTag: Self.syntheticTag,
                clipboard: clipboard
            )
        }
    }

    private func postDeletes(count: Int) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey = CGKeyCode(kVK_Delete)
        for index in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
            down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            if index < count - 1 {
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }
}

private extension CGEvent {
    func keyboardString() -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 16)
        keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: Int(length))
    }
}

extension Snippet {
    static func normalizedKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayKeyword: String {
        Self.normalizedKeyword(keyword)
    }
}
