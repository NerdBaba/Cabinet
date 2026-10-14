import SwiftUI
import AppKit

struct AddGameDialog: View {
    @ObservedObject var store: LibraryStore
    var onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var command = ""
    @State private var workingDir = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        DialogFrame(title: "Add Game", description: "Add a custom game or app to your library.", confirm: "Add", disabled: title.trimmed.isEmpty || command.trimmed.isEmpty || saving, saving: saving, error: error, onCancel: { dismiss() }, onConfirm: save) {
            VStack(alignment: .leading, spacing: 12) {
                GameField(label: "Title") { TextField("Game title", text: $title).focused($titleFocused) }
                GameField(label: "Command or Path") {
                    HStack(spacing: 8) {
                        TextField("/Applications/MyGame.app or ~/scripts/launch.sh", text: $command)
                        BrowseButton(label: "Browse for file") {
                            if let url = pickFile(message: "Select application or script") { command = url.path; if title.isEmpty { title = url.deletingPathExtension().lastPathComponent } }
                        }
                    }
                }
                GameField(label: "Working Directory", optional: true) {
                    HStack(spacing: 8) {
                        TextField("Leave blank to use defaults", text: $workingDir)
                        BrowseButton(label: "Browse for directory") { if let url = pickFile(message: "Select working directory (optional)", directory: true) { workingDir = url.path } }
                    }
                }
            }
        }.onAppear { titleFocused = true }
    }

    private func save() {
        saving = true; error = nil
        Task {
            do { _ = try await store.addCustom(title: title.trimmed, command: command.trimmed, workingDir: workingDir.trimmed.isEmpty ? nil : workingDir.trimmed); onAdded(); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

struct EditGameDialog: View {
    @ObservedObject var store: LibraryStore
    let game: Game
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var command: String
    @State private var workingDir: String
    @State private var saving = false
    @State private var artBusy = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(store: LibraryStore, game: Game) {
        self.store = store; self.game = game
        _title = State(initialValue: game.title); _command = State(initialValue: game.launchTarget); _workingDir = State(initialValue: game.workingDir ?? "")
    }
    private var currentGame: Game { store.games.first { $0.id == game.id } ?? game }
    private var isCustom: Bool { game.source == .custom }
    var body: some View {
        DialogFrame(title: "Edit Game", confirm: "Save", disabled: title.trimmed.isEmpty || (isCustom && command.trimmed.isEmpty) || saving, saving: saving, error: error, onCancel: { dismiss() }, onConfirm: save) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        PosterArt(title: title.isEmpty ? game.title : title, url: store.artURL(for: currentGame.coverUrl)).frame(width: 96, height: 144).clipShape(RoundedRectangle(cornerRadius: 12))
                        Button(action: pickCover) { Label("Custom…", systemImage: "photo.badge.arrow.up").font(.custom("InterVariable", size: 11)).frame(maxWidth: .infinity) }.disabled(artBusy)
                        if currentGame.coverUrl != nil { Button(action: resetCover) { Label("Reset", systemImage: "arrow.counterclockwise").font(.custom("InterVariable", size: 11)) }.buttonStyle(.plain).disabled(artBusy) }
                    }.frame(width: 96)
                    VStack(alignment: .leading, spacing: 12) {
                        GameField(label: "Title") { TextField("Game title", text: $title).focused($titleFocused) }
                        if !isCustom { Text("Command and location are managed automatically for scanned games.").font(.custom("InterVariable", size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if isCustom {
                    GameField(label: "Command or Path") { HStack(spacing: 8) { TextField("Command or Path", text: $command); BrowseButton(label: "Browse for file") { if let url = pickFile(message: "Select application or script") { command = url.path } } } }
                    GameField(label: "Working Directory", optional: true) { HStack(spacing: 8) { TextField("Leave blank to use defaults", text: $workingDir); BrowseButton(label: "Browse for directory") { if let url = pickFile(message: "Select working directory", directory: true) { workingDir = url.path } } } }
                }
            }
        }.onAppear { titleFocused = true }
    }
    private func pickCover() {
        guard let url = pickFile(message: "Select a custom poster image", images: true) else { return }; artBusy = true
        Task { do { try await store.setCustomArt(id: game.id, fileURL: url, kind: .cover) } catch { self.error = error.localizedDescription }; artBusy = false }
    }
    private func resetCover() { artBusy = true; Task { await store.clearArt(id: game.id, kind: .cover); artBusy = false } }
    private func save() {
        saving = true; error = nil
        Task {
            do { try await store.update(id: game.id, title: title.trimmed, command: isCustom ? command.trimmed : nil, workingDir: isCustom ? workingDir.trimmed : nil); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

struct RefetchCoverDialog: View {
    let game: Game
    var onSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @FocusState private var titleFocused: Bool
    init(game: Game, onSearch: @escaping (String) -> Void) { self.game = game; self.onSearch = onSearch; _title = State(initialValue: game.title) }
    var body: some View {
        DialogFrame(title: "Refetch Cover", confirm: "Search", disabled: title.trimmed.isEmpty, onCancel: { dismiss() }, onConfirm: { onSearch(title.trimmed); dismiss() }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search SteamGridDB with a different title if the automatic match for “\(game.title)” was wrong.").font(.custom("InterVariable", size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Search title", text: $title).focused($titleFocused)
            }
        }.onAppear { titleFocused = true }
    }
}

struct DialogFrame<Content: View>: View {
    var title: String
    var description: String? = nil
    var confirm: String
    var disabled = false
    var saving = false
    var error: String? = nil
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.custom("InterVariable", size: 18).weight(.semibold)); if let description { Text(description).font(.custom("InterVariable", size: 13)).foregroundStyle(.secondary) } }
            content().textFieldStyle(GameTextFieldStyle()).font(.custom("InterVariable", size: 13))
            if let error { Text(error).font(.custom("InterVariable", size: 11)).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction); Button(action: onConfirm) { if saving { ProgressView().controlSize(.small).frame(width: 40) } else { Text(confirm).frame(minWidth: 40) } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(disabled) }.padding(.top, 4)
        }.padding(24).frame(width: 460)
    }
}

struct GameField<Content: View>: View {
    var label: String
    var optional = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) { Text(label).foregroundStyle(.secondary); if optional { Text("(optional)").foregroundStyle(.tertiary) } }.font(.custom("InterVariable", size: 11))
            content()
        }
    }
}
struct GameTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.padding(.horizontal, 10).padding(.vertical, 8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
    }
}
struct BrowseButton: View {
    var label: String
    var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: "folder").font(.custom("InterVariable", size: 16)).frame(width: 30, height: 30) }.buttonStyle(.bordered).help(label).accessibilityLabel(label) }
}
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
