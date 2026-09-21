import SwiftUI

/// Shared visual tokens for Filit panels.
enum FilitGlass {
    static let shellRadius: CGFloat = 24
    static let cardRadius: CGFloat = 20
    static let rowRadius: CGFloat = 14
    static let pillRadius: CGFloat = 14

    static var elevatedFill: Color {
        Color.primary.opacity(0.06)
    }

    static var selectedFill: Color {
        Color.primary.opacity(0.10)
    }

    static var hairline: Color {
        Color.primary.opacity(0.08)
    }

    static var iconWellFill: Color {
        Color.primary.opacity(0.08)
    }
}

struct GlassShellBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: FilitGlass.shellRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: FilitGlass.shellRadius, style: .continuous)
                    .strokeBorder(FilitGlass.hairline, lineWidth: 1)
            )
    }
}

struct ClipboardMeta {
    let kindLabel: String
    let title: String
    let subtitle: String
    let symbol: String

    static func forItem(_ item: ClipboardItem) -> ClipboardMeta {
        let time = item.createdAt.formatted(date: .omitted, time: .shortened)
        switch item.kind {
        case .image:
            return ClipboardMeta(
                kindLabel: "Image",
                title: item.title,
                subtitle: "Image · Copied \(time)",
                symbol: "photo"
            )
        case .file:
            return ClipboardMeta(
                kindLabel: "File",
                title: item.title,
                subtitle: "File · Copied \(time)",
                symbol: "doc"
            )
        case .color:
            return ClipboardMeta(
                kindLabel: "Color",
                title: item.title,
                subtitle: "Color · Copied \(time)",
                symbol: "paintpalette"
            )
        case .richText:
            return ClipboardMeta(
                kindLabel: "Rich Text",
                title: item.preview.replacingOccurrences(of: "\n", with: " "),
                subtitle: "Rich Text · Copied \(time)",
                symbol: "doc.richtext"
            )
        case .text:
            return forText(item.plainText, copiedAt: item.createdAt)
        }
    }

    static func forText(_ text: String, copiedAt: Date) -> ClipboardMeta {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = copiedAt.formatted(date: .omitted, time: .shortened)
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https", let host = url.host {
            return ClipboardMeta(
                kindLabel: "URL",
                title: trimmed,
                subtitle: "URL · \(host) · Copied \(time)",
                symbol: "globe"
            )
        }
        let title = trimmed.count <= 80 ? trimmed : String(trimmed.prefix(77)) + "…"
        return ClipboardMeta(
            kindLabel: "Text",
            title: title.replacingOccurrences(of: "\n", with: " "),
            subtitle: "Text · Copied \(time)",
            symbol: "doc.text"
        )
    }
}
