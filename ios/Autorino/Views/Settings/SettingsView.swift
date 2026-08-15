import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DropboxSettingsSection()
                GeminiKeySection()
                Section {
                    Text("Autorino (iOS)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct DropboxSettingsSection: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isSyncing = false
    @State private var appKey: String = KeychainService.get(.dropboxAppKey) ?? ""
    @State private var appKeySaved = false

    var body: some View {
        Section {
            if env.dropboxAuth.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if let last = env.syncStatus.lastSyncedAt {
                    LabeledContent("Last synced", value: last.formatted(date: .abbreviated, time: .shortened))
                }

                switch env.syncStatus.phase {
                case .syncing:
                    HStack { ProgressView(); Text("Syncing…") }
                case .error(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                case .idle:
                    EmptyView()
                }

                Button {
                    Task {
                        isSyncing = true
                        await env.syncNow()
                        isSyncing = false
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)

                if !env.syncStatus.conflicts.isEmpty {
                    ForEach(env.syncStatus.conflicts, id: \.self) { filename in
                        Label(filename, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Text("Both versions were kept — the Dropbox copy was saved alongside your local one. Merge manually, then delete the extra copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    env.bookStore.syncIndex.reset()
                } label: {
                    Label("Reset sync state", systemImage: "arrow.counterclockwise")
                }
                .disabled(isSyncing)
                Text("Use this if sync reports success but files you expect are missing. It doesn't touch your books or your Dropbox connection — only this device's memory of what's already synced. Run Sync now again afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    env.dropboxAuth.disconnect()
                } label: {
                    Text("Disconnect Dropbox")
                }
            } else {
                SecureField("Dropbox App Key", text: $appKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    KeychainService.set(appKey, for: .dropboxAppKey)
                    appKeySaved = true
                }
                .disabled(appKey.isEmpty)
                if appKeySaved {
                    Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                }

                Button {
                    env.dropboxAuth.startAuth()
                } label: {
                    Label("Connect Dropbox", systemImage: "link")
                }
                .disabled(!DropboxConfig.isConfigured)
                if let error = env.dropboxAuth.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if !DropboxConfig.isConfigured {
                    Text("Create a Dropbox app at dropbox.com/developers/apps, paste its App Key above, and register db-autorino://oauth2redirect as its Redirect URI — see README-iOS.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Dropbox Sync")
        } footer: {
            Text("Books sync with the Dropbox App folder \"Autorino\". Point your Mac's books/ folder at ~/Dropbox/Apps/Autorino to keep both in sync.")
        }
    }
}

private struct GeminiKeySection: View {
    @State private var apiKey: String = KeychainService.get(.geminiAPIKey) ?? ""
    @State private var saved = false

    var body: some View {
        Section {
            SecureField("Gemini API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save key") {
                KeychainService.set(apiKey, for: .geminiAPIKey)
                saved = true
            }
            .disabled(apiKey.isEmpty)
            if saved {
                Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            }
        } header: {
            Text("Gemini")
        } footer: {
            Text("Used for the LLM assistant. Stored in the Keychain, never leaves the device except to call the Gemini API directly.")
        }
    }
}
