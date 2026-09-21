import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: NSObject, ObservableObject {
    let settings: AppSettings
    let keychain: KeychainStore
    let clipboard: ClipboardHistoryStore
    let snippets: SnippetStore
    let source: SourceStore
    let hotkeys: HotkeyManager
    let pasteInserter: PasteInserter
    let typeSafe: TypeSafeClient
    private let snippetExpander: SnippetKeywordExpander

    lazy var historyPanel = FloatingPanelController(
        title: "Filit",
        size: NSSize(width: 420, height: 520),
        chrome: .borderlessRounded,
        activatesApplication: false
    ) { appState in
        FilitLauncherView()
            .environmentObject(appState)
    }

    lazy var settingsPanel = FloatingPanelController(
        title: "Settings",
        size: NSSize(width: 460, height: 600),
        chrome: .borderlessRounded
    ) { appState in
        SettingsView()
            .environmentObject(appState)
    }

    lazy var onboardingPanel = FloatingPanelController(
        title: "Welcome to Filit",
        size: NSSize(width: 440, height: 560),
        chrome: .borderlessRounded
    ) { appState in
        OnboardingView()
            .environmentObject(appState)
    }

    @Published var statusMessage: String?
    @Published var isSmartPasting = false
    @Published var lastError: String?
    @Published var hasSavedAPIKey = false
    @Published var lastPasteUsage: TokenUsage?
    @Published var lastCandidateCount: Int = 0
    @Published var estimatedNextPaste: TokenUsage?

    /// App that was frontmost before Filit — paste from the launcher returns here.
    private(set) var pasteTargetApp: NSRunningApplication?
    private var frontAppObserver: NSObjectProtocol?

    private var cancellables = Set<AnyCancellable>()

    override init() {
        let settings = AppSettings()
        let keychain = KeychainStore()

        self.settings = settings
        self.keychain = keychain
        self.clipboard = ClipboardHistoryStore(settings: settings)
        self.snippets = SnippetStore()
        self.source = SourceStore()
        self.pasteInserter = PasteInserter()
        self.typeSafe = TypeSafeClient(keychain: keychain)
        self.hotkeys = HotkeyManager(settings: settings)
        self.snippetExpander = SnippetKeywordExpander(
            snippets: snippets,
            pasteInserter: pasteInserter,
            clipboard: clipboard
        )
        self.hasSavedAPIKey = keychain.apiKey != nil

        super.init()

        clipboard.start()
        bindHotkeys()
        hotkeys.start()
        snippetExpander.start()
        trackFrontmostApp()
        refreshCostEstimate()
        DispatchQueue.main.async { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    private func trackFrontmostApp() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            pasteTargetApp = front
        }
        frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                guard let self else { return }
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.pasteTargetApp = app
                }
            }
        }
    }

    /// Close the launcher, restore the previous app, then ⌘V what is on the pasteboard.
    func pasteClipboardIntoPreviousApp() async {
        closeClipboardHistory()
        let target = pasteTargetApp
        if let target, !target.isTerminated {
            target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            for _ in 0..<25 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(40))
            try? pasteInserter.pasteCommandV(toPid: target.processIdentifier)
        } else {
            try? pasteInserter.pasteCommandV()
        }
    }

    func pasteHistoryItem(_ item: ClipboardItem) async {
        clipboard.copyToPasteboard(item)
        await pasteClipboardIntoPreviousApp()
    }

    func pasteSnippetItem(_ snippet: Snippet) async {
        let text = snippet.text
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        await pasteClipboardIntoPreviousApp()
    }

    func restartSnippetExpansion() {
        snippetExpander.start()
    }

    func saveAPIKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.apiKey = trimmed.isEmpty ? nil : trimmed
        hasSavedAPIKey = keychain.apiKey != nil
        objectWillChange.send()
    }

    func clearAPIKey() {
        keychain.apiKey = nil
        hasSavedAPIKey = false
        objectWillChange.send()
    }

    private func bindHotkeys() {
        hotkeys.onSmartPaste = { [weak self] in
            Task { @MainActor in
                await self?.performSmartPaste()
            }
        }
        hotkeys.onOpenHistory = { [weak self] in
            self?.openClipboardHistory()
        }
    }

    func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else { return }
        switch url.host {
        case "settings":
            openSettings()
        case "history":
            openClipboardHistory()
        default:
            break
        }
    }

    func pinClipboardAsSource() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            source.pin(text)
            statusMessage = "Pinned clipboard as source"
            lastError = nil
            refreshCostEstimate()
        } else {
            lastError = "Clipboard is empty"
        }
    }

    func clearPinnedSource() {
        source.clear()
        statusMessage = "Cleared pinned source"
        refreshCostEstimate()
    }

    func openClipboardHistory() {
        closeSettings()
        historyPanel.attach(appState: self)
        historyPanel.show(nearMouse: true)
    }

    func closeClipboardHistory() {
        historyPanel.close()
    }

    func openSettings() {
        closeClipboardHistory()
        refreshCostEstimate()
        settingsPanel.attach(appState: self)
        settingsPanel.show(nearMouse: false)
    }

    func closeSettings() {
        settingsPanel.close()
    }

    func presentOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardingKey) else { return }
        closeClipboardHistory()
        closeSettings()
        onboardingPanel.attach(appState: self)
        onboardingPanel.show(nearMouse: false)
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        onboardingPanel.close()
    }

    private static let onboardingKey = "hasCompletedOnboarding"

    func refreshCostEstimate() {
        let field = FieldContext(
            label: "example field",
            placeholder: "",
            role: "AXTextField",
            description: "",
            value: "",
            nearby: ""
        )
        let candidates = CandidateBuilder.build(
            settings: settings,
            pinnedSource: source.pinnedText,
            history: clipboard.items,
            snippets: snippets.items,
            field: field
        )
        lastCandidateCount = candidates.count
        estimatedNextPaste = PasteCostEstimator.estimate(
            field: field,
            sourceExcerpt: source.excerpt(maxChars: 4000),
            candidates: candidates
        )
    }

    func performSmartPaste() async {
        guard !isSmartPasting else { return }
        isSmartPasting = true
        lastError = nil
        defer { isSmartPasting = false }

        guard keychain.apiKey != nil else {
            lastError = "Add your TypeSafe API key in Settings"
            openSettings()
            return
        }

        guard AccessibilityFieldReader.ensurePermission() else {
            lastError = "Grant Accessibility permission in System Settings"
            return
        }

        let field = AccessibilityFieldReader.focusedField()
        let candidates = CandidateBuilder.build(
            settings: settings,
            pinnedSource: source.pinnedText,
            history: clipboard.items,
            snippets: snippets.items,
            field: field
        )
        lastCandidateCount = candidates.count

        guard !candidates.isEmpty else {
            lastError = "No candidates — pin a source, copy text, or add snippets"
            return
        }

        let estimate = PasteCostEstimator.estimate(
            field: field,
            sourceExcerpt: source.excerpt(maxChars: 4000),
            candidates: candidates
        )
        estimatedNextPaste = estimate

        do {
            let result = try await typeSafe.pickCandidate(
                field: field,
                sourceExcerpt: source.excerpt(maxChars: 4000),
                candidates: candidates
            )
            lastPasteUsage = result.usage
            if result.choice == TypeSafeClient.noneOption {
                lastError = "No matching value · \(result.usage.costDescription)"
                return
            }
            guard let value = candidates.first(where: { $0.id == result.choice })?.value
                    ?? candidates.first(where: { $0.value == result.choice })?.value else {
                lastError = "Unexpected choice from TypeSafe"
                return
            }
            try pasteInserter.insert(value)
            statusMessage = "Pasted · \(result.usage.costDescription)"
        } catch {
            lastError = error.localizedDescription
        }
    }
}
