import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tab: SettingsTab = .general
    @State private var apiKeyDraft = ""
    @State private var showAPIKey = false
    @State private var importMessage: String?
    @State private var selectedSnippetID: UUID?
    @State private var snippetPopoverID: UUID?
    @State private var accessibilityTrusted = AccessibilityFieldReader.isTrusted

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case smartPaste = "Smart Paste"
        case snippets = "Snippets"

        var id: String { rawValue }
    }

    private var keyIsSaved: Bool { appState.hasSavedAPIKey }
    private var keyDraftMatchesSaved: Bool {
        let draft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = appState.keychain.apiKey ?? ""
        return !draft.isEmpty && draft == saved
    }
    private var keyDirty: Bool {
        let draft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = appState.keychain.apiKey ?? ""
        return draft != saved
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    switch tab {
                    case .general: generalTab
                    case .smartPaste: smartPasteTab
                    case .snippets: snippetsTab
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear {
            apiKeyDraft = appState.keychain.apiKey ?? ""
            showAPIKey = false
            accessibilityTrusted = AccessibilityFieldReader.isTrusted
            appState.refreshCostEstimate()
            if selectedSnippetID == nil {
                selectedSnippetID = appState.snippets.items.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AccessibilityFieldReader.isTrusted
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    appState.closeSettings()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")

                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }

            // Full-width segmented tabs
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { tab = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(tab == item ? FilitGlass.selectedFill : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(4)
            .background(
                Capsule(style: .continuous)
                    .fill(FilitGlass.elevatedFill)
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsSection(
                title: "Shortcuts",
                footer: "Click a shortcut, then press the new keys."
            ) {
                HotkeyRecorderRow(
                    title: "Smart Paste",
                    shortcut: Binding(
                        get: { appState.settings.smartPasteShortcut },
                        set: { appState.settings.smartPasteShortcut = $0 }
                    )
                )
                rowDivider
                HotkeyRecorderRow(
                    title: "Clipboard History",
                    shortcut: Binding(
                        get: { appState.settings.historyShortcut },
                        set: { appState.settings.historyShortcut = $0 }
                    )
                )
            }

            settingsSection(
                title: "Clipboard",
                footer: "Filit keeps your recent copies for Smart Paste and the history panel."
            ) {
                HStack {
                    Text("History size")
                        .font(.system(size: 13))
                    Spacer()
                    Text("Up to \(appState.settings.storedHistorySize) items")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection(
                title: "TypeSafe",
                footer: keyFooter
            ) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Group {
                            if showAPIKey {
                                TextField("API key", text: $apiKeyDraft)
                            } else {
                                SecureField("API key", text: $apiKeyDraft)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .id(showAPIKey ? "visible" : "hidden")

                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showAPIKey ? "Hide" : "Show")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(FilitGlass.hairline, lineWidth: 1)
                            )
                    )

                    if keyIsSaved && !keyDirty {
                        Button("Replace") {
                            showAPIKey = true
                            apiKeyDraft = ""
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(keyIsSaved ? "Update" : "Save") {
                            appState.saveAPIKey(apiKeyDraft)
                            showAPIKey = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if keyIsSaved && !keyDirty {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.top, 6)
                } else if keyIsSaved && keyDirty {
                    Button("Cancel") {
                        apiKeyDraft = appState.keychain.apiKey ?? ""
                        showAPIKey = false
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }
            }

            settingsSection(
                title: "Accessibility",
                footer: accessibilityTrusted
                    ? "Filit can read the focused field and paste into it."
                    : "Required to read the focused field and paste."
            ) {
                HStack {
                    if accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("Not allowed")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow Access") {
                            _ = AccessibilityFieldReader.ensurePermission(prompt: true)
                            accessibilityTrusted = AccessibilityFieldReader.isTrusted
                            if accessibilityTrusted {
                                appState.restartSnippetExpansion()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var keyFooter: String {
        if keyIsSaved && !keyDirty {
            return "Stored in Keychain on this Mac."
        }
        if keyDirty && keyIsSaved {
            return "You have unsaved changes."
        }
        return "Paste your TypeSafe key, then Save."
    }

    // MARK: - Smart Paste

    private var smartPasteTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsSection(
                title: "This paste",
                footer: "Based on your current sources and limits.",
                trailing: {
                    Button("Refresh") {
                        appState.refreshCostEstimate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            ) {
                if let estimate = appState.estimatedNextPaste {
                    costRow(
                        title: "Candidates",
                        value: "\(appState.lastCandidateCount)",
                        detail: appState.lastCandidateCount == 1
                            ? "1 option for Jev to choose from"
                            : "\(appState.lastCandidateCount) options for Jev to choose from"
                    )
                    rowDivider
                    costRow(
                        title: "Tokens",
                        value: "~\(estimate.totalTokens)",
                        detail: estimate.friendlyTokenLine
                    )
                    rowDivider
                    costRow(
                        title: "Cost",
                        value: estimate.friendlyCostValue,
                        detail: estimate.shortCostDescription
                    )
                } else {
                    Text("Nothing to estimate yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection(
                title: "Sources",
                footer: "What Smart Paste can pull from."
            ) {
                toggleRow("Snippets", isOn: Binding(
                    get: { appState.settings.alwaysIncludeSnippets },
                    set: { appState.settings.alwaysIncludeSnippets = $0; appState.refreshCostEstimate() }
                ))
                rowDivider
                toggleRow("Clipboard", isOn: Binding(
                    get: { appState.settings.includeClipboardHistory },
                    set: { appState.settings.includeClipboardHistory = $0; appState.refreshCostEstimate() }
                ))
            }

            settingsSection(
                title: "How much to send",
                footer: "Smaller sets cost less and stay faster."
            ) {
                stepperRow(
                    title: "Clipboard items",
                    value: Binding(
                        get: { appState.settings.clipboardItemsForSmartPaste },
                        set: { appState.settings.clipboardItemsForSmartPaste = $0; appState.refreshCostEstimate() }
                    ),
                    range: 0...500
                )
                rowDivider
                stepperRow(
                    title: "Max options",
                    value: Binding(
                        get: { appState.settings.maxCandidates },
                        set: { appState.settings.maxCandidates = $0; appState.refreshCostEstimate() }
                    ),
                    range: 1...254
                )
            }
        }
    }

    // MARK: - Snippets

    private var snippetsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snippets")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(appState.snippets.items.count) saved")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import…") { importSnippets() }
                    .buttonStyle(.bordered)
                Button("Add") {
                    let fresh = Snippet(name: "New snippet", keyword: "", text: "")
                    appState.snippets.add(fresh)
                    selectedSnippetID = fresh.id
                    snippetPopoverID = fresh.id
                    appState.refreshCostEstimate()
                }
                .buttonStyle(.borderedProminent)
            }

            if let importMessage {
                Text(importMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if appState.snippets.items.isEmpty {
                settingsGroup {
                    VStack(spacing: 10) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No snippets yet")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Import a snippets JSON file, or add one.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                settingsSection(title: "Library") {
                    ForEach(Array(appState.snippets.items.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { rowDivider }
                        snippetLibraryRow(snippet)
                    }
                }
            }
        }
    }

    private func snippetLibraryRow(_ snippet: Snippet) -> some View {
        let isSelected = snippet.id == selectedSnippetID
        return Button {
            selectedSnippetID = snippet.id
            snippetPopoverID = snippet.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !snippet.displayKeyword.isEmpty {
                    Text(snippet.displayKeyword)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                withAnimation(.easeOut(duration: 0.12)) {
                    selectedSnippetID = snippet.id
                }
            }
        }
        .popover(isPresented: Binding(
            get: { snippetPopoverID == snippet.id },
            set: { if !$0 { snippetPopoverID = nil } }
        ), arrowEdge: .trailing) {
            SnippetQuickEditor(
                snippet: snippet,
                onSave: { updated in
                    appState.snippets.update(updated)
                    snippetPopoverID = nil
                    appState.refreshCostEstimate()
                },
                onDelete: {
                    appState.snippets.remove(snippet)
                    if selectedSnippetID == snippet.id {
                        selectedSnippetID = appState.snippets.items.first?.id
                    }
                    snippetPopoverID = nil
                    appState.refreshCostEstimate()
                }
            )
        }
    }

    // MARK: - Building blocks

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func costRow(title: String, value: String, detail: String, valueIsPrimary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func settingsSection<Content: View, Trailing: View>(
        title: String,
        footer: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 4)

            settingsGroup(content: content)

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FilitGlass.elevatedFill)
        )
    }

    private var rowDivider: some View {
        Divider()
            .opacity(0.4)
            .padding(.vertical, 10)
    }

    private func stepperRow(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try appState.snippets.importSnippetsJSON(from: url)
            importMessage = "Imported \(count)"
            selectedSnippetID = appState.snippets.items.first?.id
            appState.refreshCostEstimate()
        } catch {
            importMessage = error.localizedDescription
        }
    }
}

struct SnippetQuickEditor: View {
    @State var snippet: Snippet
    var onSave: (Snippet) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("Content") {
                TextEditor(text: $snippet.text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 160)
                    .padding(10)
                    .background(subtleField)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            labeled("Name") {
                subtleTextField("Name", text: $snippet.name)
            }
            labeled("Keyword") {
                subtleTextField("!hello or /sig", text: $snippet.keyword)
            }
            Text("Type the keyword anywhere — it expands instantly. Placeholders: {clipboard}, {date}, {time}, {uuid}.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Save") { onSave(snippet) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var subtleField: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(FilitGlass.hairline, lineWidth: 1)
            )
    }

    private func subtleTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(subtleField)
    }
}

struct HotkeyRecorderRow: View {
    let title: String
    @Binding var shortcut: KeyboardShortcutSpec
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Button {
                isRecording.toggle()
            } label: {
                Text(isRecording ? "Press keys…" : shortcut.displayString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .background(HotkeyCatcher(isRecording: $isRecording) { event in
                shortcut = KeyboardShortcutSpec.from(flags: event.modifierFlags, keyCode: event.keyCode)
                isRecording = false
            })
        }
    }
}

struct HotkeyCatcher: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onKey = onKey
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onKey = onKey
        view.isRecording = isRecording
    }

    final class MonitorView: NSView {
        var onKey: ((NSEvent) -> Void)?
        private var monitor: Any?
        var isRecording: Bool = false {
            didSet { updateMonitor() }
        }

        private func updateMonitor() {
            clearMonitor()
            guard isRecording else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let modifiersOnly: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]
                if modifiersOnly.contains(event.keyCode) { return nil }
                self.onKey?(event)
                return nil
            }
        }

        private func clearMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { clearMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
