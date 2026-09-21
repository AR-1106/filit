import Foundation

struct Candidate: Identifiable, Hashable {
    let id: String
    let value: String
    let origin: String
}

enum CandidateBuilder {
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )
    private static let phoneRegex = try! NSRegularExpression(
        pattern: #"\(?\+?\d[\d\s()\-.]{6,}\d"#
    )
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s]+"#
    )

    /// Origin prefix for values taken from the newest clipboard item — ranked above snippets.
    static let latestHistoryOriginPrefix = "history-latest"

    @MainActor
    static func build(
        settings: AppSettings,
        pinnedSource: String?,
        history: [ClipboardItem],
        snippets: [Snippet],
        field: FieldContext
    ) -> [Candidate] {
        var collected: [Candidate] = []
        var seen = Set<String>()

        func add(_ value: String, origin: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let truncated = trimmed.count > 500 ? String(trimmed.prefix(500)) : trimmed
            collected.append(
                Candidate(id: "c\(collected.count)", value: truncated, origin: origin)
            )
        }

        func addClipboardItem(_ item: ClipboardItem, latest: Bool) {
            let emailOrigin = latest ? "\(latestHistoryOriginPrefix)-email" : "history-email"
            let phoneOrigin = latest ? "\(latestHistoryOriginPrefix)-phone" : "history-phone"
            let lineOrigin = latest ? "\(latestHistoryOriginPrefix)-line" : "history-line"
            let plainOrigin = latest ? latestHistoryOriginPrefix : "history"

            if item.text.count > 280 {
                for email in matches(emailRegex, in: item.text) { add(email, origin: emailOrigin) }
                for phone in matches(phoneRegex, in: item.text) { add(phone, origin: phoneOrigin) }
                for line in item.text.split(whereSeparator: \.isNewline).prefix(8) {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    if (2...200).contains(s.count) { add(s, origin: lineOrigin) }
                }
            } else {
                add(item.text, origin: plainOrigin)
            }
        }

        if settings.includePinnedSource, let source = pinnedSource, !source.isEmpty {
            for email in matches(emailRegex, in: source) { add(email, origin: "source-email") }
            for phone in matches(phoneRegex, in: source) { add(phone, origin: "source-phone") }
            for url in matches(urlRegex, in: source) { add(url, origin: "source-url") }
            for line in source.split(whereSeparator: \.isNewline) {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.count >= 2 && s.count <= 200 {
                    add(s, origin: "source-line")
                }
            }
        }

        // Newest clipboard first (before snippets) so it wins duplicates and ranks above them.
        let historyLimit = settings.includeClipboardHistory
            ? max(0, settings.clipboardItemsForSmartPaste)
            : 0
        let eligibleHistory = history.prefix(historyLimit).filter(\.isSmartPasteEligible)
        if let latest = eligibleHistory.first {
            addClipboardItem(latest, latest: true)
        }

        if settings.alwaysIncludeSnippets {
            let eligible = snippets.filter(\.includeInSmartPaste)
            let ranked = rankSnippets(eligible, field: field)
            for snippet in ranked {
                add(snippet.text, origin: "snippet:\(snippet.name)")
            }
        }

        for item in eligibleHistory.dropFirst() {
            addClipboardItem(item, latest: false)
        }

        collected = preferFieldFit(collected, field: field)

        let maxCount = max(1, min(254, settings.maxCandidates))
        return Array(collected.prefix(maxCount))
    }

    private static func rankSnippets(_ snippets: [Snippet], field: FieldContext) -> [Snippet] {
        let blob = field.searchBlob
        return snippets.sorted { a, b in
            scoreSnippet(a, blob: blob) > scoreSnippet(b, blob: blob)
        }
    }

    private static func scoreSnippet(_ snippet: Snippet, blob: String) -> Int {
        var score = 0
        let name = snippet.name.lowercased()
        let keyword = snippet.keyword.lowercased()
        if !blob.isEmpty {
            if !name.isEmpty && blob.contains(name) { score += 5 }
            if !keyword.isEmpty && blob.contains(keyword) { score += 5 }
            for tag in snippet.tags {
                if blob.contains(tag.lowercased()) { score += 3 }
            }
            for token in name.split(separator: " ") where token.count > 2 {
                if blob.contains(token) { score += 1 }
            }
        }
        return score
    }

    /// Rank by field shape first, then prefer the newest clipboard item over snippets.
    private static func preferFieldFit(_ candidates: [Candidate], field: FieldContext) -> [Candidate] {
        let blob = field.searchBlob
        func typeWeight(_ c: Candidate) -> Int {
            if blob.contains("email") || blob.contains("e-mail") {
                return c.value.contains("@") ? 10 : 0
            }
            if blob.contains("phone") || blob.contains("mobile") || blob.contains("tel") {
                return c.origin.contains("phone") || c.value.contains(where: \.isNumber) ? 10 : 0
            }
            if blob.contains("url") || blob.contains("website") || blob.contains("link") {
                return c.value.lowercased().hasPrefix("http") ? 10 : 0
            }
            if blob.contains("name") {
                if c.origin.hasPrefix(latestHistoryOriginPrefix) { return 6 }
                return c.origin.contains("line") || c.origin.hasPrefix("snippet") ? 5 : 0
            }
            return 0
        }
        func sourceWeight(_ c: Candidate) -> Int {
            if c.origin.hasPrefix(latestHistoryOriginPrefix) { return 20 }
            if c.origin.hasPrefix("snippet") { return 10 }
            if c.origin.hasPrefix("history") { return 5 }
            if c.origin.hasPrefix("source") { return 8 }
            return 0
        }
        return candidates.sorted {
            let tw = typeWeight($0)
            let tw2 = typeWeight($1)
            if tw != tw2 { return tw > tw2 }
            return sourceWeight($0) > sourceWeight($1)
        }
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty && !seen.contains(s) {
                seen.insert(s)
                out.append(s)
            }
        }
        return out
    }
}
