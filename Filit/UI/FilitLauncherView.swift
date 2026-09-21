import AppKit
import SwiftUI

enum LauncherMode: String, CaseIterable, Identifiable {
    case history = "Clipboard History"
    case snippets = "Snippets"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .history: return "clock"
        case .snippets: return "text.badge.plus"
        }
    }
}

/// Menu-bar list launcher with hover/keyboard side popover previews.
struct FilitLauncherView: View {
    @EnvironmentObject private var appState: AppState
    @State private var mode: LauncherMode = .history
    @State private var query = ""
    @State private var selectedHistoryID: UUID?
    @State private var selectedSnippetID: UUID?
    @State private var editingSnippet: Snippet?
    @State private var isKeyboardNavigating = true
    @State private var pendingHoverID: UUID?
    @State private var previewID: UUID?
    @State private var hoveredID: UUID?
    @State private var hoverEnabled = false
    @State private var hoverPreviewTask: Task<Void, Never>?
    @State private var previewEdge: Edge = .trailing
    @State private var showSnippetEditor = false
    @FocusState private var searchFocused: Bool

    private var historyItems: [ClipboardItem] {
        let limit = max(1, appState.settings.storedHistorySize)
        let base = Array(appState.clipboard.items.prefix(limit))
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.text.lowercased().contains(q) }
    }

    private var snippetItems: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return appState.snippets.items }
        return appState.snippets.items.filter {
            $0.name.lowercased().contains(q)
                || $0.keyword.lowercased().contains(q)
                || $0.text.lowercased().contains(q)
        }
    }

    private var selectedHistoryItem: ClipboardItem? {
        historyItems.first { $0.id == selectedHistoryID }
    }

    private var selectedSnippet: Snippet? {
        snippetItems.first { $0.id == selectedSnippetID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let editingSnippet, showSnippetEditor {
                SnippetEditorView(
                    snippet: editingSnippet,
                    onBack: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showSnippetEditor = false
                            self.editingSnippet = nil
                        }
                    },
                    onSave: { updated in
                        appState.snippets.update(updated)
                        withAnimation(.easeOut(duration: 0.18)) {
                            showSnippetEditor = false
                            self.editingSnippet = nil
                        }
                        appState.refreshCostEstimate()
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                searchBar
                Divider().opacity(0.25)
                listPane
                Divider().opacity(0.25)
                footer
            }
        }
        .background(.ultraThinMaterial)
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
            isKeyboardNavigating = true
            hoverEnabled = false
            dismissPreview()
            selectFirst()
            updatePreviewEdge()
        }
        .onDisappear {
            dismissPreview()
        }
        .onChange(of: mode) { _, _ in
            query = ""
            pendingHoverID = nil
            isKeyboardNavigating = true
            hoverEnabled = false
            dismissPreview()
            selectFirst()
        }
        .onChange(of: query) { _, _ in
            hoverEnabled = false
            dismissPreview()
            pruneOrReselect()
        }
        .background(KeyCatcher { key in handleKey(key) })
        .background(MouseMoveCatcher { armHoverFromMouse() })
        .background(WindowAccess { window in
            previewEdge = PreviewEdgeHelper.arrowEdge(for: window)
        })
        // Reliable SwiftUI shortcuts while the launcher is key.
        .background {
            Button("") { mode = .history }
                .keyboardShortcut("1", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            Button("") { mode = .snippets }
                .keyboardShortcut("2", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(mode == .history ? "Type to filter entries…" : "Search snippets…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var listPane: some View {
        Group {
            switch mode {
            case .history: historyList
            case .snippets: snippetsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        Group {
            if historyItems.isEmpty {
                emptyState(
                    title: query.isEmpty ? "Nothing copied yet" : "No matches",
                    systemImage: "doc.on.clipboard",
                    detail: query.isEmpty ? "Copy something and it will show up here." : "Try a different search."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(groupedHistory, id: \.title) { section in
                                Text(section.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 6)

                                ForEach(section.items) { item in
                                    historyRow(item)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selectedHistoryID) { _, id in
                        guard isKeyboardNavigating, let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var snippetsList: some View {
        Group {
            if snippetItems.isEmpty {
                emptyState(
                    title: query.isEmpty ? "No snippets" : "No matches",
                    systemImage: "text.badge.plus",
                    detail: query.isEmpty ? "Add a snippet or import a JSON file." : "Try a different search."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(snippetItems) { snippet in
                                snippetRow(snippet)
                                    .id(snippet.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selectedSnippetID) { _, id in
                        guard isKeyboardNavigating, let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ item: ClipboardItem) -> some View {
        let isSelected = item.id == selectedHistoryID
        let meta = ClipboardMeta.forText(item.text, copiedAt: item.createdAt)
        return HStack(spacing: 12) {
            Image(systemName: meta.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 22)
            Text(item.preview)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pasteHistory(item) }
        .onTapGesture(count: 1) {
            isKeyboardNavigating = false
            withAnimation(.easeOut(duration: 0.12)) {
                selectedHistoryID = item.id
            }
        }
        .onHover { hovering in
            handleHover(item.id, hovering: hovering)
        }
        .popover(
            isPresented: Binding(
                get: { previewID == item.id && mode == .history },
                set: { if !$0, previewID == item.id { previewID = nil } }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: previewEdge
        ) {
            ItemPreviewPopover.fromClipboardText(item.text, copiedAt: item.createdAt)
        }
        .contextMenu {
            Button("Paste") { pasteHistory(item) }
            Button("Pin as Source") {
                appState.source.pin(item.text)
                appState.refreshCostEstimate()
            }
            Divider()
            Button("Delete", role: .destructive) {
                appState.clipboard.remove(item)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        let isSelected = snippet.id == selectedSnippetID
        return HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 22)
            Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if !snippet.displayKeyword.isEmpty {
                Text(snippet.displayKeyword)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pasteSnippet(snippet) }
        .onTapGesture(count: 1) {
            isKeyboardNavigating = false
            withAnimation(.easeOut(duration: 0.12)) {
                selectedSnippetID = snippet.id
            }
        }
        .onHover { hovering in
            handleHover(snippet.id, hovering: hovering)
        }
        .popover(
            isPresented: Binding(
                get: { previewID == snippet.id && mode == .snippets && !showSnippetEditor },
                set: { if !$0, previewID == snippet.id { previewID = nil } }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: previewEdge
        ) {
            SnippetPopoverContent(
                snippet: snippet,
                onEdit: {
                    editingSnippet = snippet
                    showSnippetEditor = true
                },
                onPaste: { pasteSnippet(snippet) }
            )
        }
        .contextMenu {
            Button("Paste") { pasteSnippet(snippet) }
            Button("Edit") {
                editingSnippet = snippet
                showSnippetEditor = true
            }
            Divider()
            Button("Delete", role: .destructive) {
                appState.snippets.remove(snippet)
                appState.refreshCostEstimate()
            }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(LauncherMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        Text("\(item.rawValue)  \(item == .history ? "⌘1" : "⌘2")")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mode.symbol)
                    Text(mode.rawValue)
                        .lineLimit(1)
                    Text(mode == .history ? "⌘1" : "⌘2")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if mode == .snippets {
                Button {
                    let fresh = Snippet(name: "New snippet", keyword: "", text: "")
                    appState.snippets.add(fresh)
                    editingSnippet = fresh
                    showSnippetEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New snippet")
            }

            Spacer()

            Button {
                appState.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button("Paste") {
                confirmPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(primaryItemMissing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var primaryItemMissing: Bool {
        switch mode {
        case .history: return selectedHistoryItem == nil
        case .snippets: return selectedSnippet == nil
        }
    }

    private func emptyState(title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private struct HistorySection: Identifiable {
        var id: String { title }
        let title: String
        let items: [ClipboardItem]
    }

    private var groupedHistory: [HistorySection] {
        let cal = Calendar.current
        var today: [ClipboardItem] = []
        var yesterday: [ClipboardItem] = []
        var earlier: [ClipboardItem] = []
        for item in historyItems {
            if cal.isDateInToday(item.createdAt) {
                today.append(item)
            } else if cal.isDateInYesterday(item.createdAt) {
                yesterday.append(item)
            } else {
                earlier.append(item)
            }
        }
        var sections: [HistorySection] = []
        if !today.isEmpty { sections.append(.init(title: "Today", items: today)) }
        if !yesterday.isEmpty { sections.append(.init(title: "Yesterday", items: yesterday)) }
        if !earlier.isEmpty { sections.append(.init(title: "Earlier", items: earlier)) }
        return sections
    }

    private func handleHover(_ id: UUID, hovering: Bool) {
        if !hovering {
            if hoveredID == id { hoveredID = nil }
            if pendingHoverID == id { pendingHoverID = nil }
            hoverPreviewTask?.cancel()
            hoverPreviewTask = nil
            if previewID == id { previewID = nil }
            return
        }
        pendingHoverID = id
        guard hoverEnabled else { return }
        hoveredID = id
        hoverSelect(id: id)
        hoverPreviewTask?.cancel()
        hoverPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, hoveredID == id, hoverEnabled else { return }
            previewID = id
        }
    }

    private func dismissPreview() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        hoveredID = nil
        previewID = nil
    }

    private func hoverSelect(id: UUID) {
        if isKeyboardNavigating {
            pendingHoverID = id
            return
        }
        applySelection(id: id)
    }

    private func armHoverFromMouse() {
        let wasEnabled = hoverEnabled
        hoverEnabled = true
        if isKeyboardNavigating {
            isKeyboardNavigating = false
        }
        if let pending = pendingHoverID {
            applySelection(id: pending)
            if !wasEnabled {
                handleHover(pending, hovering: true)
            }
        }
    }

    private func applySelection(id: UUID) {
        switch mode {
        case .history:
            guard historyItems.contains(where: { $0.id == id }) else { return }
            selectedHistoryID = id
        case .snippets:
            guard snippetItems.contains(where: { $0.id == id }) else { return }
            selectedSnippetID = id
        }
    }

    private func selectFirst() {
        switch mode {
        case .history:
            selectedHistoryID = historyItems.first?.id
            selectedSnippetID = nil
        case .snippets:
            selectedSnippetID = snippetItems.first?.id
            selectedHistoryID = nil
        }
        pendingHoverID = nil
    }

    private func pruneOrReselect() {
        switch mode {
        case .history:
            if selectedHistoryID == nil || !historyItems.contains(where: { $0.id == selectedHistoryID }) {
                selectedHistoryID = historyItems.first?.id
            }
        case .snippets:
            if selectedSnippetID == nil || !snippetItems.contains(where: { $0.id == selectedSnippetID }) {
                selectedSnippetID = snippetItems.first?.id
            }
        }
    }

    private func confirmPrimaryAction() {
        switch mode {
        case .history:
            if let item = selectedHistoryItem { pasteHistory(item) }
        case .snippets:
            if let snippet = selectedSnippet { pasteSnippet(snippet) }
        }
    }

    private func pasteHistory(_ item: ClipboardItem) {
        appState.clipboard.copyToPasteboard(item)
        appState.closeClipboardHistory()
        try? appState.pasteInserter.insert(item.text)
    }

    private func pasteSnippet(_ snippet: Snippet) {
        appState.closeClipboardHistory()
        try? appState.pasteInserter.insert(snippet.text)
    }

    private func handleKey(_ key: KeyCatcher.Key) {
        switch key {
        case .escape:
            appState.closeClipboardHistory()
        case .return:
            confirmPrimaryAction()
        case .down:
            moveSelection(1)
        case .up:
            moveSelection(-1)
        case .modeHistory:
            mode = .history
        case .modeSnippets:
            mode = .snippets
        }
    }

    private func moveSelection(_ delta: Int) {
        isKeyboardNavigating = true
        pendingHoverID = nil
        hoverEnabled = false
        dismissPreview()
        switch mode {
        case .history:
            guard !historyItems.isEmpty else { return }
            guard let idx = historyItems.firstIndex(where: { $0.id == selectedHistoryID }) else {
                selectedHistoryID = delta >= 0 ? historyItems.first?.id : historyItems.last?.id
                return
            }
            let next = min(max(idx + delta, 0), historyItems.count - 1)
            selectedHistoryID = historyItems[next].id
        case .snippets:
            guard !snippetItems.isEmpty else { return }
            guard let idx = snippetItems.firstIndex(where: { $0.id == selectedSnippetID }) else {
                selectedSnippetID = delta >= 0 ? snippetItems.first?.id : snippetItems.last?.id
                return
            }
            let next = min(max(idx + delta, 0), snippetItems.count - 1)
            selectedSnippetID = snippetItems[next].id
        }
    }

    private func updatePreviewEdge() {
        // Filled by WindowAccess on appear / move.
    }
}

// MARK: - Snippet editor

struct SnippetEditorView: View {
    @State var snippet: Snippet
    var onBack: () -> Void
    var onSave: (Snippet) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Edit Snippet")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Save") { onSave(snippet) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.25)

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Name") {
                    TextField("Name", text: $snippet.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Keyword") {
                    TextField("!hello or /sig", text: $snippet.keyword)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Type the keyword anywhere to expand. Supports {clipboard}, {date}, {time}, {uuid}.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Content")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $snippet.text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .frame(maxHeight: .infinity)
            }
            .padding(16)
        }
    }
}

// MARK: - Key / mouse / window helpers

struct KeyCatcher: NSViewRepresentable {
    enum Key { case up, down, `return`, escape, modeHistory, modeSnippets }
    var onKey: (Key) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatchView()
        view.onKey = onKey
        view.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatchView)?.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? CatchView)?.teardown()
    }

    final class CatchView: NSView {
        var onKey: ((Key) -> Void)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if mods == .command {
                    switch event.keyCode {
                    case 18: // 1
                        self.onKey?(.modeHistory)
                        return nil
                    case 19: // 2
                        self.onKey?(.modeSnippets)
                        return nil
                    default:
                        break
                    }
                }
                switch event.keyCode {
                case 126: self.onKey?(.up); return nil
                case 125: self.onKey?(.down); return nil
                case 36 where mods.isEmpty:
                    self.onKey?(.return); return nil
                case 53: self.onKey?(.escape); return nil
                default: return event
                }
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { teardown() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

struct MouseMoveCatcher: NSViewRepresentable {
    var onMove: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MoveView()
        view.onMove = onMove
        view.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MoveView)?.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? MoveView)?.teardown()
    }

    final class MoveView: NSView {
        var onMove: (() -> Void)?
        private var monitor: Any?
        private var lastLocation: NSPoint?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                let loc = event.locationInWindow
                if let last = self.lastLocation {
                    let dx = loc.x - last.x
                    let dy = loc.y - last.y
                    if (dx * dx + dy * dy) < 36 { return event }
                } else {
                    // First event is often synthetic when the window becomes key.
                    self.lastLocation = loc
                    return event
                }
                self.lastLocation = loc
                self.onMove?()
                return event
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { teardown() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

struct WindowAccess: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onWindow(nsView.window)
    }
}

/// Launcher snippet popover: content + actions only (no duplicate name metadata).
struct SnippetPopoverContent: View {
    let snippet: Snippet
    var onEdit: () -> Void
    var onPaste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(snippet.text.isEmpty ? "Empty snippet" : snippet.text)
                    .font(.system(size: 15))
                    .foregroundStyle(snippet.text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(width: 320, height: 160)

            Divider().opacity(0.35)

            HStack(spacing: 10) {
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button("Paste", action: onPaste)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(14)
        }
        .frame(width: 320)
    }
}
