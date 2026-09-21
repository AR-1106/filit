import AppKit
import SwiftUI

enum PanelChrome {
    case borderlessRounded
    case titledSettings
}

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private weak var appState: AppState?
    private let size: NSSize
    private let chrome: PanelChrome
    private let cornerRadius: CGFloat = 20
    private let builder: (AppState) -> AnyView

    init(
        title: String,
        size: NSSize,
        chrome: PanelChrome,
        @ViewBuilder content: @escaping (AppState) -> some View
    ) {
        self.size = size
        self.chrome = chrome
        self.builder = { appState in AnyView(content(appState)) }
        _ = title
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    func show(nearMouse: Bool = false) {
        guard let appState else { return }
        let root = builder(appState)
            .frame(width: size.width, height: size.height)

        if panel == nil {
            panel = makePanel(root: root)
        } else {
            let hosting = NSHostingController(rootView: root)
            configureHosting(hosting)
            panel?.contentViewController = hosting
            panel?.setContentSize(size)
        }

        guard let panel else { return }
        position(panel, nearMouse: nearMouse)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func makePanel(root: some View) -> NSPanel {
        let hosting = NSHostingController(rootView: root)
        configureHosting(hosting)

        let style: NSWindow.StyleMask
        switch chrome {
        case .borderlessRounded:
            style = [.borderless]
        case .titledSettings:
            // Titled + closable so traffic lights sit inside the window chrome.
            style = [.titled, .closable, .fullSizeContentView]
        }

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true

        if chrome == .titledSettings {
            panel.title = "Settings"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.toolbar = nil
            // Keep standard traffic-light inset inside the rounded content.
            panel.standardWindowButton(.closeButton)?.isHidden = false
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
        }

        return panel
    }

    private func configureHosting(_ hosting: NSHostingController<some View>) {
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.layer?.cornerRadius = cornerRadius
        hosting.view.layer?.masksToBounds = true
        hosting.view.layer?.cornerCurve = .continuous
    }

    private func position(_ panel: NSPanel, nearMouse: Bool) {
        if nearMouse {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            var origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 14)
            origin.x = min(max(origin.x, visible.minX + 10), visible.maxX - size.width - 10)
            origin.y = min(max(origin.y, visible.minY + 10), visible.maxY - size.height - 10)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        } else if panel.frame.origin == .zero || !panel.isVisible {
            panel.center()
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if event.keyCode == 53 {
                Task { @MainActor in self.close() }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
