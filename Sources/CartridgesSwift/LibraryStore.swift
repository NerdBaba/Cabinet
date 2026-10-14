import AppKit
import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var settings = AppSettings()
    @Published var isLoading = false
    @Published var isScanning = false
    @Published var isFetchingCovers = false
    @Published var notice: String?
    @Published var errorMessage: String?
    let directory: URL
    let art: ArtService
    private var hasLoaded = false
    private let originalDirectory: URL

    init(directory: URL? = nil, originalDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        self.directory = directory ?? support.appendingPathComponent("dev.cartridges.swift.rebuild")
        self.originalDirectory = originalDirectory ?? support.appendingPathComponent("app.glaze.macos.1fzw0ugp-local")
        self.art = ArtService(directory: self.directory.appendingPathComponent("art"))
    }
    private var dictionary: [String: Game] { Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }) }
    private func prepareStorage() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createDirectory(at: art.directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(".migration-complete")
        guard !manager.fileExists(atPath: marker.path) else { return }
        for name in ["games.json", "settings.json"] {
            let source = originalDirectory.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(name)
            if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: destination)
            }
        }
        if let files = try? manager.contentsOfDirectory(at: originalDirectory.appendingPathComponent("art"), includingPropertiesForKeys: nil) {
            for file in files {
                let destination = art.directory.appendingPathComponent(file.lastPathComponent)
                if !manager.fileExists(atPath: destination.path) { try manager.copyItem(at: file, to: destination) }
            }
        }
        try Data("Copied original library once; original data remains untouched.\n".utf8).write(to: marker, options: .atomic)
        // Settings contain the user's cover API key. Keep the runtime copy private.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("settings.json").path)
    }
    func load() async {
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try prepareStorage()
            let file = directory.appendingPathComponent("games.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                let document = try JSONDecoder().decode(GamesDocument.self, from: data)
                // Match original JS object insertion order using each record's id field.
                let raw = String(decoding: data, as: UTF8.self)
                let expression = try NSRegularExpression(pattern: "\"id\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")")
                let range = NSRange(raw.startIndex..., in: raw)
                var ordered: [Game] = []
                var seen: Set<String> = []
                for match in expression.matches(in: raw, range: range) {
                    guard let range = Range(match.range(at: 1), in: raw),
                          let id = try? JSONDecoder().decode(String.self, from: Data(raw[range].utf8)),
                          let game = document.games[id], seen.insert(id).inserted else { continue }
                    ordered.append(game)
                }
                ordered += document.games.values.filter { !seen.contains($0.id) }.sorted { $0.addedAt < $1.addedAt }
                games = ordered
            }
        } catch { report(error) }
        do {
            let settingsFile = directory.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: settingsFile.path) {
                settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsFile))
            }
        } catch { report(error) }
        hasLoaded = true
    }
    private func saveGames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let entries = try games.map { game -> String in
            let key = String(decoding: try JSONEncoder().encode(game.id), as: UTF8.self)
            let value = String(decoding: try encoder.encode(game), as: UTF8.self)
            return "    \(key): \(value.replacingOccurrences(of: "\n", with: "\n    "))"
        }
        let data = Data(("{\n  \"games\": {\n" + entries.joined(separator: ",\n") + "\n  }\n}\n").utf8)
        try data.write(to: directory.appendingPathComponent("games.json"), options: .atomic)
    }
    func saveSettings() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = directory.appendingPathComponent("settings.json")
        try encoder.encode(settings).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let old = dictionary
        games = await GameScanner(art: art).scan(existing: old, existingOrder: games)
        do { try saveGames(); notice = "Scan complete — \(games.count) games" } catch { report(error) }
    }
    /// Adds Steam on startup without dropping other saved sources or running the full scanner.
    func importSteam() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let old = dictionary
        let imported = await Task.detached(priority: .utility) { SteamScanner().scan(existing: old) }.value
        let existingSteam = games.filter { $0.source == .steam }
        guard imported != existingSteam else { return }
        games = games.filter { $0.source != .steam } + imported
        do { try saveGames() } catch { report(error) }
    }
    private func index(_ id: String) throws -> Int {
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw CartridgesError.message("Game not found: \(id)") }
        return index
    }
    @discardableResult
    func addCustom(title: String, command: String, workingDir: String? = nil) async throws -> Game {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CartridgesError.message("Enter a game title") }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CartridgesError.message("Enter a launch command") }
        var id = "custom:\(gameSlug(title))-\(Int(Date().timeIntervalSince1970 * 1000))"
        while games.contains(where: { $0.id == id }) { id += "1" }
        let game = Game(id: id, title: title, source: .custom, launchType: .shell, launchTarget: command, workingDir: workingDir)
        games.append(game)
        do { try saveGames() } catch { games.removeLast(); throw error }
        notice = "Added \(title)"
        return game
    }
    func update(id: String, title: String? = nil, command: String? = nil, workingDir: String? = nil) async throws {
        let i = try index(id)
        let old = games[i]
        if let title { games[i].title = title }
        if let command { games[i].launchTarget = command }
        if let workingDir { games[i].workingDir = workingDir.isEmpty ? nil : workingDir }
        do { try saveGames() } catch { games[i] = old; throw error }
        notice = "Updated \(games[i].title)"
    }
    func setHidden(id: String, hidden: Bool) async {
        do { let i = try index(id); games[i].hidden = hidden; try saveGames(); notice = hidden ? "Game hidden" : "Game shown" }
        catch { report(error) }
    }
    func hide(_ game: Game) async { await setHidden(id: game.id, hidden: !game.hidden) }
    func remove(id: String) async {
        do {
            let i = try index(id)
            guard games[i].source == .custom else { throw CartridgesError.message("Only custom games can be removed") }
            let removed = games.remove(at: i)
            do { try saveGames() } catch { games.insert(removed, at: i); throw error }
            notice = "Removed \(removed.title)"
        } catch { report(error) }
    }
    func remove(_ game: Game) async { await remove(id: game.id) }
    func launch(_ game: Game) async {
        do {
            notice = "Launching \(game.title)…"
            try await LaunchService.launch(game)
            let i = try index(game.id)
            games[i].lastPlayedAt = Date().timeIntervalSince1970 * 1000
            try saveGames()
            notice = "Launched \(game.title)"
            LaunchService.afterLaunch(settings.afterLaunchAction)
        } catch { report(CartridgesError.message("Failed to launch \"\(game.title)\": \(error.localizedDescription)")) }
    }
    func fetchCover(id: String, searchTitle: String? = nil) async throws {
        let game = games[try index(id)]
        let result = try await art.fetchCover(id: id, title: game.title, settings: settings, force: true, searchTitle: searchTitle)
        games[try index(id)].coverUrl = result
        try saveGames()
        notice = "Updated cover for \(game.title)"
    }
    func refetch(_ game: Game, searchTitle: String? = nil) async {
        do { try await fetchCover(id: game.id, searchTitle: searchTitle) } catch { report(error) }
    }
    @discardableResult
    func fetchMissingCovers() async -> Int {
        guard !isFetchingCovers else { return 0 }
        isFetchingCovers = true
        defer { isFetchingCovers = false }
        var count = 0
        for game in games.filter({ $0.coverUrl == nil && !$0.hidden }) {
            do {
                let cover = try await art.fetchCover(id: game.id, title: game.title, settings: settings)
                games[try index(game.id)].coverUrl = cover
                try saveGames()
                count += 1
            } catch { errorMessage = error.localizedDescription }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        notice = "Fetched \(count) covers"
        return count
    }
    func setCustomArt(id: String, fileURL: URL, kind: ArtKind) async throws {
        let i = try index(id)
        let result = try art.setCustom(id: id, fileURL: fileURL, kind: kind)
        if kind == .cover { games[i].coverUrl = result } else { games[i].iconUrl = result }
        try saveGames()
        notice = "Updated \(kind.rawValue)"
    }
    func setArt(_ game: Game, path: String, kind: ArtKind) async {
        do { try await setCustomArt(id: game.id, fileURL: URL(fileURLWithPath: path), kind: kind) } catch { report(error) }
    }
    func clearArt(id: String, kind: ArtKind) async {
        do {
            let i = try index(id)
            try art.clear(id: id, kind: kind)
            if kind == .cover { games[i].coverUrl = nil } else { games[i].iconUrl = nil }
            try saveGames()
            notice = "Cleared \(kind.rawValue)"
        } catch { report(error) }
    }
    func artURL(for raw: String?) -> URL? { art.resolve(raw) }
    private func report(_ error: Error) { errorMessage = error.localizedDescription; notice = error.localizedDescription }
}
