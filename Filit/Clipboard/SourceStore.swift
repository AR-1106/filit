import Foundation

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var pinnedText: String?

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Filit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("pinned-source.txt")
        if let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
            pinnedText = text
        }
    }

    func pin(_ text: String) {
        pinnedText = text
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        pinnedText = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    func excerpt(maxChars: Int) -> String? {
        guard let pinnedText else { return nil }
        if pinnedText.count <= maxChars { return pinnedText }
        return String(pinnedText.prefix(maxChars))
    }
}
