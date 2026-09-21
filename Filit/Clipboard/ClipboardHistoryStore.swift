import AppKit
import Foundation

enum ClipboardKind: String, Codable, Hashable {
    case text
    case richText
    case image
    case file
    case color
}

struct ClipboardStoredRepresentation: Codable, Hashable {
    /// `NSPasteboard.PasteboardType.rawValue`
    var pasteboardType: String
    /// Relative path under the blobs directory, for binary payloads.
    var relativePath: String?
    /// Inline string payloads (plain text / HTML).
    var stringValue: String?
}

struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    var kind: ClipboardKind
    /// Searchable plain text. Empty for pure images/files without names.
    var plainText: String
    var title: String
    var contentHash: String
    var representations: [ClipboardStoredRepresentation]

    /// Compatibility alias used by smart-paste candidate building.
    var text: String { plainText }

    var preview: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(117)) + "…"
    }

    var isSmartPasteEligible: Bool {
        !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, plainText, title, contentHash, representations
        // Legacy
        case text
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: ClipboardKind,
        plainText: String,
        title: String,
        contentHash: String,
        representations: [ClipboardStoredRepresentation]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.plainText = plainText
        self.title = title
        self.contentHash = contentHash
        self.representations = representations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let kind = try container.decodeIfPresent(ClipboardKind.self, forKey: .kind) {
            self.kind = kind
            plainText = try container.decodeIfPresent(String.self, forKey: .plainText)
                ?? container.decodeIfPresent(String.self, forKey: .text)
                ?? ""
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? plainText
            contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
                ?? ClipboardItem.hash(for: Data(plainText.utf8))
            representations = try container.decodeIfPresent([ClipboardStoredRepresentation].self, forKey: .representations)
                ?? [
                    ClipboardStoredRepresentation(
                        pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                        relativePath: nil,
                        stringValue: plainText
                    ),
                ]
        } else {
            // Pre-rich-history schema: { id, text, createdAt }
            let legacyText = try container.decode(String.self, forKey: .text)
            kind = .text
            plainText = legacyText
            title = legacyText
            contentHash = ClipboardItem.hash(for: Data(legacyText.utf8))
            representations = [
                ClipboardStoredRepresentation(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    relativePath: nil,
                    stringValue: legacyText
                ),
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(kind, forKey: .kind)
        try container.encode(plainText, forKey: .plainText)
        try container.encode(title, forKey: .title)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(representations, forKey: .representations)
    }

    static func hash(for data: Data) -> String {
        var hasher = Hasher()
        hasher.combine(data)
        return String(hasher.finalize())
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let settings: AppSettings
    private var timer: Timer?
    private(set) var lastSyncedChangeCount: Int = NSPasteboard.general.changeCount
    private let rootDir: URL
    private let fileURL: URL
    private let blobsDir: URL

    /// Marker type for Filit's own temporary pasteboard writes (snippet expansion).
    static let internalType = NSPasteboard.PasteboardType("com.filit.app.internal")

    private static let maxImageBytes = 25 * 1024 * 1024
    private static let ignoredTypeHints: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.apple.is-remote-clipboard",
        "com.filit.app.internal",
    ]

    /// Call before mutating the pasteboard for an internal paste so the poller skips it.
    func prepareForInternalMutation() {
        // No-op placeholder — synchronizeAfterInternalMutation stamps the change count.
    }

    func synchronizeAfterInternalMutation(changeCount: Int) {
        lastSyncedChangeCount = changeCount
    }

    init(settings: AppSettings) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Filit", isDirectory: true)
        rootDir = support
        fileURL = support.appendingPathComponent("clipboard-history.json")
        blobsDir = support.appendingPathComponent("clipboard-blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
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
        for item in items {
            removeBlobDirectory(for: item.id)
        }
        items = []
        persist()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        removeBlobDirectory(for: item.id)
        persist()
    }

    /// Restore this history entry onto the general pasteboard (carbon copy).
    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var wrote = false
        for rep in item.representations {
            let type = NSPasteboard.PasteboardType(rep.pasteboardType)
            if let relative = rep.relativePath {
                let url = blobsDir.appendingPathComponent(relative)
                if let data = try? Data(contentsOf: url), !data.isEmpty {
                    pb.setData(data, forType: type)
                    wrote = true
                }
            } else if let string = rep.stringValue {
                pb.setString(string, forType: type)
                wrote = true
            }
        }
        if !wrote, !item.plainText.isEmpty {
            pb.setString(item.plainText, forType: .string)
        }
        lastSyncedChangeCount = pb.changeCount
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image || item.kind == .richText else { return nil }
        for rep in item.representations {
            guard let relative = rep.relativePath else { continue }
            let type = NSPasteboard.PasteboardType(rep.pasteboardType)
            guard type == .tiff || type == .png || type.rawValue.contains("image") else { continue }
            let url = blobsDir.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    func fileURLs(for item: ClipboardItem) -> [URL] {
        item.representations.compactMap { rep -> URL? in
            guard rep.pasteboardType == NSPasteboard.PasteboardType.fileURL.rawValue,
                  let value = rep.stringValue,
                  let url = URL(string: value) else { return nil }
            return url
        }
    }

    // MARK: - Polling

    private func poll() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastSyncedChangeCount else { return }
        lastSyncedChangeCount = change

        guard let item = capture(from: pb) else { return }
        if items.first?.contentHash == item.contentHash { return }

        items.insert(item, at: 0)
        trim()
        persist()
    }

    private func capture(from pb: NSPasteboard) -> ClipboardItem? {
        let types = Set((pb.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: Self.ignoredTypeHints) {
            return nil
        }

        let id = UUID()
        var representations: [ClipboardStoredRepresentation] = []
        var plainText = ""
        var title = ""
        var kind: ClipboardKind = .text
        var hashParts: [Data] = []

        // Files first — Finder copies are primarily file URLs.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty {
            kind = .file
            for url in urls.prefix(40) {
                representations.append(
                    ClipboardStoredRepresentation(
                        pasteboardType: NSPasteboard.PasteboardType.fileURL.rawValue,
                        relativePath: nil,
                        stringValue: url.absoluteString
                    )
                )
                hashParts.append(Data(url.absoluteString.utf8))
            }
            if urls.count == 1 {
                title = urls[0].lastPathComponent
            } else {
                title = "\(urls.count) files"
            }
            plainText = urls.map(\.path).joined(separator: "\n")
        }

        // Image
        if let tiff = pb.data(forType: .tiff), !tiff.isEmpty, tiff.count <= Self.maxImageBytes {
            if kind != .file { kind = .image }
            if let relative = writeBlob(tiff, itemID: id, name: "image.tiff") {
                representations.append(
                    ClipboardStoredRepresentation(
                        pasteboardType: NSPasteboard.PasteboardType.tiff.rawValue,
                        relativePath: relative,
                        stringValue: nil
                    )
                )
                hashParts.append(tiff.prefix(64 * 1024) as Data)
                if title.isEmpty { title = "Image" }
            }
        } else if let png = pb.data(forType: .png), !png.isEmpty, png.count <= Self.maxImageBytes {
            if kind != .file { kind = .image }
            if let relative = writeBlob(png, itemID: id, name: "image.png") {
                representations.append(
                    ClipboardStoredRepresentation(
                        pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
                        relativePath: relative,
                        stringValue: nil
                    )
                )
                hashParts.append(png.prefix(64 * 1024) as Data)
                if title.isEmpty { title = "Image" }
            }
        }

        // Rich text
        var hasRich = false
        if let rtf = pb.data(forType: .rtf), !rtf.isEmpty {
            hasRich = true
            if let relative = writeBlob(rtf, itemID: id, name: "content.rtf") {
                representations.append(
                    ClipboardStoredRepresentation(
                        pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue,
                        relativePath: relative,
                        stringValue: nil
                    )
                )
                hashParts.append(rtf.prefix(32 * 1024) as Data)
            }
        }
        if let html = pb.string(forType: .html), !html.isEmpty {
            hasRich = true
            representations.append(
                ClipboardStoredRepresentation(
                    pasteboardType: NSPasteboard.PasteboardType.html.rawValue,
                    relativePath: nil,
                    stringValue: html
                )
            )
            hashParts.append(Data(html.utf8))
        }

        // Plain text / color
        if let string = pb.string(forType: .string)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !string.isEmpty {
            if plainText.isEmpty { plainText = string }
            if title.isEmpty {
                title = string.replacingOccurrences(of: "\n", with: " ")
            }
            representations.append(
                ClipboardStoredRepresentation(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    relativePath: nil,
                    stringValue: string
                )
            )
            hashParts.append(Data(string.utf8))
            if kind == .text, hasRich {
                kind = .richText
            }
        } else if let color = pb.readObjects(forClasses: [NSColor.self], options: nil)?.first as? NSColor {
            kind = .color
            let hex = color.filitHexString
            plainText = hex
            title = hex
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false),
               let relative = writeBlob(data, itemID: id, name: "color.archive") {
                representations.append(
                    ClipboardStoredRepresentation(
                        pasteboardType: NSPasteboard.PasteboardType.color.rawValue,
                        relativePath: relative,
                        stringValue: hex
                    )
                )
                hashParts.append(Data(hex.utf8))
            }
        }

        guard !representations.isEmpty else {
            removeBlobDirectory(for: id)
            return nil
        }

        if title.isEmpty {
            title = kind == .image ? "Image" : "Clipboard item"
        }
        if title.count > 200 {
            title = String(title.prefix(197)) + "…"
        }

        var hasher = Hasher()
        for part in hashParts {
            hasher.combine(part)
        }
        hasher.combine(kind.rawValue)

        return ClipboardItem(
            id: id,
            createdAt: Date(),
            kind: kind,
            plainText: plainText,
            title: title,
            contentHash: String(hasher.finalize()),
            representations: representations
        )
    }

    private func writeBlob(_ data: Data, itemID: UUID, name: String) -> String? {
        let dir = blobsDir.appendingPathComponent(itemID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic])
            return "\(itemID.uuidString)/\(name)"
        } catch {
            return nil
        }
    }

    private func removeBlobDirectory(for id: UUID) {
        let dir = blobsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private func trim() {
        let limit = max(10, settings.storedHistorySize)
        guard items.count > limit else { return }
        let removed = items.suffix(from: limit)
        for item in removed {
            removeBlobDirectory(for: item.id)
        }
        items = Array(items.prefix(limit))
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

private extension NSColor {
    var filitHexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
