import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var apiKeyDraft = ""
    @State private var showAPIKey = false
    @State private var accessibilityTrusted = AccessibilityFieldReader.isTrusted

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    accessibilityCard
                    apiKeyCard
                }
                .padding(24)
            }
            footer
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear {
            apiKeyDraft = appState.keychain.apiKey ?? ""
            accessibilityTrusted = AccessibilityFieldReader.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AccessibilityFieldReader.isTrusted
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: FilitSymbol.name)
                .font(.system(size: 18, weight: .semibold))
            Text("Welcome to Filit")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart paste for the field in front of you.")
                .font(.system(size: 15, weight: .semibold))
            Text("Copy a resume or contact block, click a form field, and press ⌥⌘V. Filit picks the value that belongs there.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityCard: some View {
        card {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accessibilityTrusted ? Color.green : Color.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .semibold))
                    Text(accessibilityTrusted
                         ? "Filit can read the focused field and paste into it."
                         : "Required to read the focused field and insert text.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if accessibilityTrusted {
                    Text("Allowed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Allow Access") {
                        _ = AccessibilityFieldReader.ensurePermission(prompt: true)
                        accessibilityTrusted = AccessibilityFieldReader.isTrusted
                        if accessibilityTrusted {
                            appState.restartSnippetExpansion()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private var apiKeyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: appState.hasSavedAPIKey ? "checkmark.circle.fill" : "key.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(appState.hasSavedAPIKey ? Color.green : Color.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TypeSafe API key")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Stored in Keychain on this Mac. Get one at typesafe.ai.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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

                    Button("Save") {
                        appState.saveAPIKey(apiKeyDraft)
                        showAPIKey = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Get started") {
                appState.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FilitGlass.hairline)
                .frame(height: 1)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FilitGlass.cardRadius, style: .continuous)
                    .fill(FilitGlass.elevatedFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: FilitGlass.cardRadius, style: .continuous)
                            .strokeBorder(FilitGlass.hairline, lineWidth: 1)
                    )
            )
    }
}
