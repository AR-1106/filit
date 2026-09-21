import AppKit
import SwiftUI

/// Side preview for clipboard items. Content first; one quiet footer line.
struct ItemPreviewPopover: View {
    enum Kind {
        case text(String)
        case url(URL, display: String)
        case image(NSImage)
    }

    let kind: Kind
    var footer: String?

    static func fromClipboardText(_ text: String, copiedAt: Date) -> ItemPreviewPopover {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = copiedAt.formatted(date: .abbreviated, time: .shortened)
        if let url = URL(string: trimmed), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return ItemPreviewPopover(
                kind: .url(url, display: trimmed),
                footer: "Copied \(time)"
            )
        }
        return ItemPreviewPopover(
            kind: .text(trimmed.isEmpty ? "Empty" : trimmed),
            footer: "Copied \(time)"
        )
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
