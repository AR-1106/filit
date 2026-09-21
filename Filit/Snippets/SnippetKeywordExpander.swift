import AppKit
import ApplicationServices
import Carbon
import Foundation

// MARK: - Keyword matching

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

// MARK: - Keyword listener

@MainActor
final class SnippetKeywordExpander {
    private static let syntheticTag: Int64 = 0x46494C54 // "FILT"
    /// Bridge for the C tap callback (cannot capture MainActor-isolated self).
    private static weak var active: SnippetKeywordExpander?

    private let snippets: SnippetStore
    private let pasteInserter: PasteInserter

    private var policy = SnippetKeywordPolicy()
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matchTask: Task<Void, Never>?
    private var isExpanding = false
    private var lastKeywordFingerprint = ""
    private var activityObserver: NSObjectProtocol?

    private static let resetKeyCodes: Set<Int64> = [
        36, 76, 53, 48, // return, keypad enter, escape, tab
        123, 124, 125, 126, // arrows
        115, 119, 116, 121, // home end page up/down
        117, // forward delete
    ]

    init(snippets: SnippetStore, pasteInserter: PasteInserter) {
        self.snippets = snippets
        self.pasteInserter = pasteInserter
    }

    func start() {
        stop()
        Self.active = self
        refreshKeywords()
        installTapIfNeeded()
        activityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installTapIfNeeded()
            }
        }
    }

    func stop() {
        if Self.active === self { Self.active = nil }
        if let activityObserver {
            NotificationCenter.default.removeObserver(activityObserver)
            self.activityObserver = nil
        }
        matchTask?.cancel()
        matchTask = nil
        tearDownTap()
        policy.reset()
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

    private func installTapIfNeeded() {
        guard AccessibilityFieldReader.isTrusted else { return }
        guard tapPort == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tapPort = nil
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

        let typeRaw = type.rawValue
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let text = event.keyboardStringIndentingDeadKeys()
        let secure = IsSecureEventInputEnabled()

        Task { @MainActor in
            Self.active?.processEvent(
                typeRaw: typeRaw,
                keyCode: keyCode,
                flags: flags,
                text: text,
                userData: userData,
                secureEventInputEnabled: secure
            )
        }
    }

    private func processEvent(
        typeRaw: UInt32,
        keyCode: Int64,
        flags: CGEventFlags,
        text: String?,
        userData: Int64,
        secureEventInputEnabled: Bool
    ) {
        guard !isExpanding else { return }
        refreshKeywordsIfNeeded()

        let input = SnippetKeywordPolicy.classifyInput(
            text: text,
            isSynthetic: userData == Self.syntheticTag,
            secureEventInputEnabled: secureEventInputEnabled,
            isFlagsChanged: typeRaw == CGEventType.flagsChanged.rawValue,
            isKeyDown: typeRaw == CGEventType.keyDown.rawValue,
            hasCommandOrControl: flags.contains(.maskCommand) || flags.contains(.maskControl),
            isResetKey: Self.resetKeyCodes.contains(keyCode),
            isDeleteBackward: keyCode == 51
        )

        guard let match = policy.process(input, at: Date()) else { return }

        matchTask?.cancel()
        matchTask = Task { @MainActor in
            // Let the triggering keystroke land first.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            await deliver(match: match)
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

    private func deliver(match: SnippetKeywordPolicy.Match) async {
        guard AccessibilityFieldReader.isTrusted else { return }
        guard let snippet = snippets.items.first(where: { $0.id == match.snippetID }) else { return }

        // Don't expand into Filit's own UI.
        if NSApp.keyWindow != nil {
            return
        }

        isExpanding = true
        defer { isExpanding = false }

        let expanded = SnippetTemplateEngine.expand(snippet.text)
        guard !expanded.isEmpty else { return }

        postDeletes(count: match.deletionCount)
        try? await Task.sleep(for: .milliseconds(30))
        try? pasteInserter.insertAtCaret(expanded)
    }

    private func postDeletes(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let deleteKey: CGKeyCode = 51
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
            down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

private extension CGEvent {
    func keyboardStringIndentingDeadKeys() -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: Int(length))
    }
}

extension Snippet {
    /// Display keyword as stored (trimmed).
    static func normalizedKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayKeyword: String {
        Self.normalizedKeyword(keyword)
    }
}
