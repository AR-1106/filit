import Foundation

struct Snippet: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var keyword: String
    var text: String
    var tags: [String]
    /// When false, keyword expansion still works but Smart Paste / Jev never sees this snippet.
    var includeInSmartPaste: Bool

    init(
        id: UUID = UUID(),
        name: String,
        keyword: String = "",
        text: String,
        tags: [String] = [],
        includeInSmartPaste: Bool = true
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.text = text
        self.tags = tags
        self.includeInSmartPaste = includeInSmartPaste
    }

    enum CodingKeys: String, CodingKey {
        case id, name, keyword, text, tags, includeInSmartPaste
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        text = try container.decode(String.self, forKey: .text)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        includeInSmartPaste = try container.decodeIfPresent(Bool.self, forKey: .includeInSmartPaste) ?? true
    }
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published var items: [Snippet] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Filit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("snippets.json")
        load()
    }

    func add(_ snippet: Snippet) {
        var next = snippet
        next.keyword = Snippet.normalizedKeyword(snippet.keyword)
        items.insert(next, at: 0)
        persist()
    }

    func update(_ snippet: Snippet) {
        guard let idx = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        var next = snippet
        next.keyword = Snippet.normalizedKeyword(snippet.keyword)
        items[idx] = next
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    func remove(_ snippet: Snippet) {
        items.removeAll { $0.id == snippet.id }
        persist()
    }

    /// Import a snippets JSON export (array or `{ "snippets": [...] }`).
    @discardableResult
    func importSnippetsJSON(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let imported = try SnippetJSONImport.parse(data)
        var count = 0
        for snippet in imported {
            if !items.contains(where: { $0.name == snippet.name && $0.text == snippet.text }) {
                items.append(snippet)
                count += 1
            }
        }
        persist()
        return count
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        for i in decoded.indices {
            decoded[i].keyword = Snippet.normalizedKeyword(decoded[i].keyword)
        }
        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

enum SnippetJSONImport {
    struct Item: Decodable {
        var name: String?
        var title: String?
        var text: String?
        var content: String?
        var keyword: String?
        var tags: [String]?
        var includeInSmartPaste: Bool?
    }

    struct Wrapper: Decodable {
        var snippets: [Item]?
    }

    static func parse(_ data: Data) throws -> [Snippet] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([Item].self, from: data) {
            return list.compactMap(map)
        }
        if let wrapper = try? decoder.decode(Wrapper.self, from: data), let list = wrapper.snippets {
            return list.compactMap(map)
        }
        throw NSError(domain: "Filit", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unrecognized snippets JSON format",
        ])
    }

    private static func map(_ item: Item) -> Snippet? {
        let name = item.name ?? item.title ?? "Untitled"
        let text = item.text ?? item.content ?? ""
        guard !text.isEmpty else { return nil }
        return Snippet(
            name: name,
            keyword: item.keyword ?? "",
            text: text,
            tags: item.tags ?? [],
            includeInSmartPaste: item.includeInSmartPaste ?? true
        )
    }
}
