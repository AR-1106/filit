import AppKit
import SwiftUI

/// Side preview for clipboard items. Content first; one quiet footer line.
struct ItemPreviewPopover: View {
    enum Kind {
        case text(String)
        case url(URL, display: String)
        case image(NSImage)
        case files([URL])
        case color(String)
    }

    let kind: Kind
    var footer: String?

    static func fromClipboardItem(_ item: ClipboardItem, image: NSImage?, files: [URL]) -> ItemPreviewPopover {
        let time = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        let footer = "Copied \(time)"

        switch item.kind {
        case .image:
            if let image {
                return ItemPreviewPopover(kind: .image(image), footer: footer)
            }
            return ItemPreviewPopover(kind: .text(item.title), footer: footer)
        case .file:
            return ItemPreviewPopover(kind: .files(files.isEmpty ? [] : files), footer: footer)
        case .color:
            return ItemPreviewPopover(kind: .color(item.title), footer: footer)
        case .richText, .text:
            let trimmed = item.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme,
               scheme == "http" || scheme == "https" {
                return ItemPreviewPopover(kind: .url(url, display: trimmed), footer: footer)
            }
            return ItemPreviewPopover(
                kind: .text(trimmed.isEmpty ? item.title : trimmed),
                footer: footer
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch kind {
                case .text(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                case .url(_, let display):
                    ScrollView {
                        Text(display)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                case .image(let image):
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 340, maxHeight: 260)
                        .padding(16)
                case .files(let urls):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if urls.isEmpty {
                                Text("Files")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(urls, id: \.self) { url in
                                    Label(url.lastPathComponent, systemImage: "doc")
                                        .font(.system(size: 14))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                case .color(let hex):
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: NSColor(filitHex: hex) ?? .gray))
                            .frame(width: 48, height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                        Text(hex)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                        Spacer()
                    }
                    .padding(16)
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
            .frame(minHeight: 100, idealHeight: 180, maxHeight: 300)

            if let footer {
                Divider().opacity(0.35)
                Text(footer)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 320)
    }
}

enum PreviewEdgeHelper {
    @MainActor
    static func arrowEdge(for window: NSWindow?) -> Edge {
        guard let window, let screen = window.screen ?? NSScreen.main else {
            return .trailing
        }
        let frame = window.frame
        let visible = screen.visibleFrame
        let spaceRight = visible.maxX - frame.maxX
        let spaceLeft = frame.minX - visible.minX
        if spaceRight >= spaceLeft {
            return .trailing
        }
        return .leading
    }
}

private extension NSColor {
    convenience init?(filitHex: String) {
        var hex = filitHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
