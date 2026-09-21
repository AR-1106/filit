import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let error = appState.lastError {
            Text(error)
        } else if let status = appState.statusMessage {
            Text(status)
        }

        Button("Clipboard History") {
            appState.openClipboardHistory()
        }

        Divider()

        Button("Settings…") {
            appState.openSettings()
        }

        Button("Quit Filit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
