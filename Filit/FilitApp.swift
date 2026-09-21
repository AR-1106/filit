import AppKit
import SwiftUI

@main
struct FilitApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .onAppear {
                    appState.installURLHandler()
                }
        } label: {
            Image(systemName: "doc.on.clipboard.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
    }
}
