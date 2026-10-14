import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage("cartridges.theme") private var themeSource = "system"
    @State private var apiKey = ""
    @State private var savedApiKey = ""
    @State private var message: String?
    @State private var isError = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeSource) {
                    Text("Auto").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("Launching") {
                Picker("After launching a game", selection: Binding(get: { store.settings.afterLaunchAction }, set: saveAction)) {
                    Text("Stay open").tag(AfterLaunchAction.stay)
                    Text("Hide app").tag(AfterLaunchAction.hide)
                    Text("Minimize").tag(AfterLaunchAction.minimize)
                    Text("Quit app").tag(AfterLaunchAction.quit)
                }
                Text("What the launcher does once a game starts, to get out of your way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cover Art") {
                LabeledContent("SteamGridDB API Key") {
                    HStack {
                        SecureField("Paste your API key", text: $apiKey).focused($keyFocused)
                        Button("Save", action: saveKey).disabled(apiKey.trimmed == savedApiKey.trimmed)
                    }
                }
                Text("Used to download game cover art. Get a free key at steamgriddb.com → Preferences → API. Steam games use locally cached covers when available.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Prefer animated covers", isOn: Binding(get: { store.settings.preferAnimatedCovers }, set: saveAnimated))
                    .toggleStyle(.switch)
                Text("Applies to newly fetched covers. Use Refetch Cover to update existing ones. Playback pauses automatically when the window is inactive or covers are offscreen, and respects Reduce Motion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(isError ? Color.red : Color.green).font(.caption) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 400)
        .onAppear { apiKey = store.settings.steamGridDbApiKey; savedApiKey = apiKey }
        .onExitCommand { if !keyFocused { NSApp.keyWindow?.close() } }
    }
    private func saveAction(_ value: AfterLaunchAction) {
        let previous = store.settings.afterLaunchAction
        store.settings.afterLaunchAction = value
        do { try store.saveSettings() } catch { store.settings.afterLaunchAction = previous; report(error) }
    }
    private func saveAnimated(_ value: Bool) {
        let previous = store.settings.preferAnimatedCovers
        store.settings.preferAnimatedCovers = value
        do { try store.saveSettings() } catch { store.settings.preferAnimatedCovers = previous; report(error) }
    }
    private func saveKey() {
        let previous = store.settings.steamGridDbApiKey
        store.settings.steamGridDbApiKey = apiKey.trimmed
        do { try store.saveSettings(); savedApiKey = apiKey.trimmed; message = "SteamGridDB API key saved"; isError = false }
        catch { store.settings.steamGridDbApiKey = previous; report(error) }
    }
    private func report(_ error: Error) { message = error.localizedDescription; isError = true }
}
