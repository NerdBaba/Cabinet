import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

extension Notification.Name {
    static let cartridgesAddGame = Notification.Name("cartridges.addGame")
    static let cartridgesRefresh = Notification.Name("cartridges.refresh")
    static let cartridgesFocusSearch = Notification.Name("cartridges.focusSearch")
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("cartridges.columns") private var columns = 7
    @AppStorage("cartridges.posterAspectRatio") private var posterAspectRatio = 1.6
    @State private var selection: String? = "all"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var search = ""
    @State private var searchOpen = false
    @State private var showHidden = false
    @State private var selectedID: String?
    @State private var addOpen = false
    @State private var editingGame: Game?
    @State private var refetchGame: Game?
    @State private var viewOptionsOpen = false
    @State private var loading = true
    @State private var notice: String?
    @FocusState private var gridFocused: Bool

    private var visibleGames: [Game] {
        store.games.filter { game in
            (showHidden || !game.hidden) && (selection == nil || selection == "all" || game.source.rawValue == selection)
                && (search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || game.title.localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }
    private var title: String { sourceTitle(selection ?? "all") }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 224, max: 300)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? Color(hex: "111111") : Color(hex: "F8F8F8"))
                .navigationTitle(title)
                .searchable(text: $search, isPresented: $searchOpen, placement: .toolbar, prompt: "Search games")
                .toolbar { ToolbarItemGroup(placement: .primaryAction) { toolbarActions } }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { _, _ in selectedID = nil }
        .sheet(isPresented: $addOpen) {
            AddGameDialog(store: store) { selection = "custom"; notify("Game added") }
        }
        .sheet(item: $editingGame) { game in EditGameDialog(store: store, game: game) }
        .sheet(item: $refetchGame) { game in
            RefetchCoverDialog(game: game) { title in refetch(game, title: title) }
        }
        .task { await store.load(); loading = false; await store.importSteam() }
        .onChange(of: store.notice) { _, message in if let message { Task { try? await Task.sleep(for: .seconds(4)); if store.notice == message { store.notice = nil } } } }
        .onReceive(NotificationCenter.default.publisher(for: .cartridgesAddGame)) { _ in addOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: .cartridgesRefresh)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .cartridgesFocusSearch)) { _ in searchOpen = true }
        .overlay(alignment: .bottom) {
            if let text = store.errorMessage ?? notice ?? store.notice {
                HStack(spacing: 10) {
                    Image(systemName: store.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(store.errorMessage == nil ? Color.green : Color.red)
                    Text(text).font(.custom("InterVariable", size: 13)).lineLimit(4)
                    Button { store.errorMessage = nil; notice = nil; store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
                .padding(24).frame(maxWidth: 600)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            sidebarRow("all", symbol: "square.grid.2x2")
            sidebarRow("custom", symbol: "plus")
            let sources = [GameSource.appstore, .steam, .heroic, .crossover].filter { source in
                store.games.contains { $0.source == source }
            }
            if !sources.isEmpty {
                Section("Imported") {
                    ForEach(sources) { source in
                        sidebarRow(source.rawValue, symbol: source == .appstore ? "bag" : source == .steam ? "gamecontroller" : source == .heroic ? "flame" : "wineglass")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .font(.custom("InterVariable", size: 13))
        .accessibilityLabel("Game sources")
    }

    private func sidebarRow(_ source: String, symbol: String) -> some View {
        Label(sourceTitle(source), systemImage: symbol)
            .badge(store.games.filter { (showHidden || !$0.hidden) && (source == "all" || $0.source.rawValue == source) }.count)
            .tag(source)
    }

    @ViewBuilder private var toolbarActions: some View {
            GlassIconButton(symbol: "plus", label: "Add game") { addOpen = true }
            GlassIconButton(symbol: "slider.horizontal.3", label: "View options") { viewOptionsOpen.toggle() }
                .popover(isPresented: $viewOptionsOpen, arrowEdge: .bottom) {
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            HStack { Text("Columns").fontWeight(.medium); Spacer(); Text("\(columns)").foregroundStyle(.secondary) }
                            Slider(value: Binding(get: { Double(columns) }, set: { columns = Int($0) }), in: 2...10, step: 1)
                        }
                        VStack(spacing: 8) {
                            HStack { Text("Poster Height").fontWeight(.medium); Spacer(); Text(String(format: "%.1f×", posterAspectRatio)).foregroundStyle(.secondary) }
                            Slider(value: $posterAspectRatio, in: 1...2, step: 0.1)
                        }
                    }.font(.custom("InterVariable", size: 11)).padding(16).frame(width: 256)
                }
            Menu {
                Button("Refresh Library", systemImage: "arrow.clockwise", action: refresh).disabled(store.isScanning)
                Button("Download Missing Covers", systemImage: "arrow.down.circle") {
                    Task { notify("Downloading missing covers…", dismiss: false); let count = await store.fetchMissingCovers(); notify("Downloaded \(count) cover\(count == 1 ? "" : "s")") }
                }.disabled(store.isFetchingCovers)
                Divider()
                Toggle("Show Hidden Games", isOn: $showHidden)
            } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).help("More options").accessibilityLabel("More options")
    }

    @ViewBuilder private var content: some View {
        if loading {
            VStack { Spacer(); LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                ForEach(0..<10, id: \.self) { _ in VStack(spacing: 6) { RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.06)).aspectRatio(2.0 / 3.0, contentMode: .fit); Capsule().fill(.primary.opacity(0.06)).frame(height: 11) } }
            }.frame(width: 384); ProgressView().controlSize(.small).padding(); Spacer() }.frame(maxWidth: .infinity)
        } else if visibleGames.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text(search.isEmpty ? "No games found" : "No matching games").font(.custom("InterVariable", size: 18).weight(.semibold))
                Text(search.isEmpty ? "Try Refresh Library or add a custom game." : "Try a different search term.").font(.custom("InterVariable", size: 13)).foregroundStyle(.secondary)
                if search.isEmpty { Button(action: refresh) { Label("Refresh Library", systemImage: "arrow.clockwise") }.disabled(store.isScanning).padding(.top, 8) }
                Spacer()
            }.frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 20), spacing: 12), count: max(2, min(10, columns))), spacing: 8) {
                        ForEach(visibleGames) { game in
                            GamePosterCard(store: store, game: game, aspectRatio: posterAspectRatio, selected: selectedID == game.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { selectedID = game.id; Task { await store.launch(game) } }
                                .onTapGesture { selectedID = game.id; gridFocused = true }
                                .contextMenu {
                                    Button("Play", systemImage: "play.fill") { Task { await store.launch(game) } }
                                    Divider()
                                    Button("Refetch Cover", systemImage: "arrow.down.circle") { refetch(game) }
                                    Button("Refetch Cover With Title…", systemImage: "magnifyingglass") { refetchGame = game }
                                    Button(game.hidden ? "Unhide" : "Hide", systemImage: game.hidden ? "eye" : "eye.slash") { Task { await store.setHidden(id: game.id, hidden: !game.hidden) } }
                                    Divider()
                                    Button("Set Custom Poster…", systemImage: "photo") { chooseArt(game, kind: .cover) }
                                    Button("Set Custom Logo…", systemImage: "app") { chooseArt(game, kind: .icon) }
                                    Divider()
                                    Button("Edit", systemImage: "pencil") { editingGame = game }
                                    if game.source == .custom { Button("Remove", systemImage: "trash", role: .destructive) { Task { await store.remove(id: game.id); notify("Game removed") } } }
                                }.id(game.id)
                        }
                    }.padding(.leading, 21).padding(.trailing, 18).padding(.top, 10).padding(.bottom, 24)
                }
                .focusable().focused($gridFocused).focusEffectDisabled()
                .onKeyPress(.return) { playSelected(); return .handled }
                .onKeyPress(KeyEquivalent("\u{F729}")) { selectedID = visibleGames.first?.id; return .handled }
                .onKeyPress(KeyEquivalent("\u{F72B}")) { selectedID = visibleGames.last?.id; return .handled }
                .onKeyPress(.leftArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.rightArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-columns); return .handled }
                .onKeyPress(.downArrow) { moveSelection(columns); return .handled }
                .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private func sourceTitle(_ source: String) -> String { ["all": "All Games", "custom": "Added", "appstore": "App Store", "steam": "Steam", "heroic": "Heroic", "crossover": "CrossOver"][source] ?? "Games" }
    private func moveSelection(_ delta: Int) { guard !visibleGames.isEmpty else { return }; let current = visibleGames.firstIndex { $0.id == selectedID } ?? -1; let next = current + delta; guard visibleGames.indices.contains(next) else { return }; selectedID = visibleGames[next].id }
    private func playSelected() { if let game = visibleGames.first(where: { $0.id == selectedID }) { Task { await store.launch(game) } } }
    private func refresh() { Task { await store.scan(); if store.errorMessage == nil { notify("Library refreshed — \(store.games.count) games found") } } }
    private func refetch(_ game: Game, title: String? = nil) { Task { do { try await store.fetchCover(id: game.id, searchTitle: title); notify("Cover updated") } catch { store.errorMessage = "Cover fetch failed: \(error.localizedDescription)" } } }
    private func chooseArt(_ game: Game, kind: ArtKind) { guard let url = pickFile(message: kind == .cover ? "Select a custom poster image" : "Select a custom logo image", images: true) else { return }; Task { do { try await store.setCustomArt(id: game.id, fileURL: url, kind: kind); notify("Custom art updated") } catch { store.errorMessage = "Could not set custom art: \(error.localizedDescription)" } } }
    private func notify(_ text: String, dismiss: Bool = true) { notice = text; if dismiss { Task { try? await Task.sleep(for: .seconds(4)); if notice == text { notice = nil } } } }
}

struct GlassIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help(label).accessibilityLabel(label)
    }
}

struct GamePosterCard: View {
    var store: LibraryStore
    var game: Game
    var aspectRatio: Double
    var selected: Bool
    var body: some View {
        VStack(spacing: 6) {
            PosterArt(title: game.title, url: store.artURL(for: game.coverUrl ?? game.iconUrl), isCover: game.coverUrl != nil)
                .aspectRatio(1 / aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .shadow(color: .black.opacity(selected ? 0.25 : 0), radius: 4, y: 2)
            Text(game.title).font(.custom("InterVariable", size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity)
        }.opacity(game.hidden ? 0.5 : 1).accessibilityElement(children: .ignore).accessibilityLabel(game.title).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct PosterArt: View {
    var title: String
    var url: URL?
    var isCover = true
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.025)
                if let url, !url.isFileURL || FileManager.default.fileExists(atPath: url.path) {
                    if isCover {
                        AnimatedPosterImage(url: url, fill: true).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        AnimatedPosterImage(url: url, fill: false).frame(width: geometry.size.width * 2 / 3, height: geometry.size.height * 2 / 3)
                    }
                } else { GeneratedPoster(title: title) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct GeneratedPoster: View {
    var title: String
    private var hash: Int { var hash: Int32 = 0; for char in title.utf16 { hash = hash &* 31 &+ Int32(char) }; return abs(Int(hash)) }
    private var gradients: [(String, String)] { [("f97316","db2777"),("7c3aed","2563eb"),("059669","0891b2"),("dc2626","ea580c"),("0ea5e9","4f46e5"),("d97706","b91c1c"),("16a34a","65a30d"),("9333ea","c026d3"),("0d9488","3b82f6"),("e11d48","7c3aed")] }
    private var emoji: String {
        let words: [(String, String)] = [("race","🏁"),("racing","🏁"),("car","🏎️"),("drift","🏎️"),("war","⚔️"),("battle","⚔️"),("fight","🥊"),("soccer","⚽"),("football","🏈"),("basketball","🏀"),("golf","⛳"),("space","🚀"),("star","⭐"),("galaxy","🌌"),("zombie","🧟"),("dead","💀"),("horror","👻"),("ghost","👻"),("dragon","🐉"),("witch","🧙"),("wizard","🧙"),("magic","✨"),("sword","🗡️"),("knight","🛡️"),("castle","🏰"),("pirate","🏴‍☠️"),("ship","🚢"),("ocean","🌊"),("fish","🐟"),("city","🏙️"),("crime","🕵️"),("detective","🕵️"),("spy","🕶️"),("robot","🤖"),("cyber","🤖"),("puzzle","🧩"),("chess","♟️"),("card","🃏"),("poker","🃏"),("farm","🌾"),("garden","🌱"),("animal","🐾"),("cat","🐱"),("dog","🐶"),("monster","👹"),("alien","👽"),("world","🌍"),("survival","🏕️"),("craft","⛏️"),("build","🧱"),("tower","🏯"),("run","🏃"),("jump","🤸"),("hero","🦸"),("legend","🏆"),("quest","🗺️"),("adventure","🗺️"),("rpg","🎲"),("strategy","♟️"),("tank","🪖"),("gun","🔫"),("shooter","🔫"),("music","🎵"),("dance","💃"),("party","🎉")]
        return words.first(where: { title.lowercased().contains($0.0) })?.1 ?? ["🎮","🕹️","👾","🎯","🎲","🧩","⚡","🔥","💎","🌟"][hash % 10]
    }
    var body: some View {
        let colors = gradients[hash % gradients.count]
        ZStack {
            LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 4) {
                Text(emoji).font(.custom("InterVariable", size: 40)).shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                Text(title.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap { $0.first.map(String.init)?.uppercased() }.joined()).font(.custom("InterVariable", size: 11).weight(.medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

extension Color {
    init(hex: String) { let value = UInt64(hex, radix: 16) ?? 0; self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255, opacity: 1) }
}

@MainActor func pickFile(message: String, directory: Bool = false, images: Bool = false) -> URL? {
    let panel = NSOpenPanel(); panel.message = message; panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
    if images { panel.allowedContentTypes = [.png, .jpeg, .webP] }
    return panel.runModal() == .OK ? panel.url : nil
}
