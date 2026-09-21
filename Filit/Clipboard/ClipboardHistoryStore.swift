import AppKit
import Foundation

struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(117)) + "…"
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let settings: AppSettings
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let fileURL: URL

    init(settings: AppSettings) {
        self.settings = settings
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Filit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("clipboard-history.json")
        load()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func clear() {
        items = []
        persist()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    private func poll() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change
        guard let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else { return }

        // Skip if identical to newest
        if items.first?.text == text { return }

        let item = ClipboardItem(id: UUID(), text: text, createdAt: Date())
        items.insert(item, at: 0)
        trim()
        persist()
    }

    private func trim() {
        let limit = max(10, settings.storedHistorySize)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
