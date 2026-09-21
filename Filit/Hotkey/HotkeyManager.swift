import AppKit
import Carbon
import Foundation

@MainActor
final class HotkeyManager {
    var onSmartPaste: (() -> Void)?
    var onOpenHistory: (() -> Void)?

    private let settings: AppSettings
    private var smartPasteHotKeyRef: EventHotKeyRef?
    private var historyHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var observer: NSObjectProtocol?

    private let smartPasteID = EventHotKeyID(signature: OSType(0x464C5031), id: 1) // FLP1
    private let historyID = EventHotKeyID(signature: OSType(0x464C5032), id: 2) // FLP2

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        installHandlerIfNeeded()
        registerAll()
        observer = NotificationCenter.default.addObserver(
            forName: .filitHotkeysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerAll()
            }
        }
    }

    func stop() {
        unregisterAll()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Temporarily unregister global hotkeys so Settings can record a new shortcut.
    func suspend() {
        unregisterAll()
    }

    func resume() {
        registerAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                Task { @MainActor in
                    if hotKeyID.id == manager.smartPasteID.id {
                        manager.onSmartPaste?()
                    } else if hotKeyID.id == manager.historyID.id {
                        manager.onOpenHistory?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }

    private func registerAll() {
        unregisterAll()
        register(settings.smartPasteShortcut, id: smartPasteID, ref: &smartPasteHotKeyRef)
        register(settings.historyShortcut, id: historyID, ref: &historyHotKeyRef)
    }

    private func register(_ shortcut: KeyboardShortcutSpec, id: EventHotKeyID, ref: inout EventHotKeyRef?) {
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            ref = hotKeyRef
        } else {
            NSLog("Filit: failed to register hotkey \(shortcut.displayString) status=\(status)")
        }
    }

    private func unregisterAll() {
        if let smartPasteHotKeyRef {
            UnregisterEventHotKey(smartPasteHotKeyRef)
            self.smartPasteHotKeyRef = nil
        }
        if let historyHotKeyRef {
            UnregisterEventHotKey(historyHotKeyRef)
            self.historyHotKeyRef = nil
        }
    }
}
