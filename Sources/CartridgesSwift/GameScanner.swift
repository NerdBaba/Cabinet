import Foundation

struct GameScanner: Sendable {
    let art: ArtService
    let home: URL
    init(art: ArtService, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.art = art
        self.home = home
    }

    private func appDirectories(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
    }
    private func nativeGames(directory: URL, source: GameSource, existing: [String: Game], requireCategory: Bool) async -> [Game] {
        var games: [Game] = []
        // This nonisolated async scanner runs filesystem and plist work away from the UI actor.
        for url in appDirectories(directory) {
            if requireCategory {
                let plist = url.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let properties = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let category = properties["LSApplicationCategoryType"] as? String,
                      category.hasPrefix("public.app-category.games") else { continue }
            }
            let name = url.deletingPathExtension().lastPathComponent
            let id = "\(source.rawValue):\(gameSlug(name))"
            let old = existing[id]
            var icon = old?.iconUrl
            if icon == nil { icon = await art.extractIcon(appURL: url, id: id) }
            games.append(Game(id: id, title: old?.title ?? name, source: source, launchType: .app,
                        launchTarget: url.path, iconUrl: icon,
                        coverUrl: old?.coverUrl, hidden: old?.hidden ?? false,
                        addedAt: old?.addedAt ?? Date().timeIntervalSince1970 * 1000, lastPlayedAt: old?.lastPlayedAt))
        }
        return games
    }
    private func json(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func heroic(existing: [String: Game]) -> [Game] {
        let base = home.appendingPathComponent("Library/Application Support/heroic")
        let timestamps = json(base.appendingPathComponent("store/timestamp.json"))
        var entries: [[String: Any]] = []
        entries.append(contentsOf: json(base.appendingPathComponent("gog_store/installed.json"))["installed"] as? [[String: Any]] ?? [])
        let legendaryURL = base.appendingPathComponent("legendaryConfig/legendary/installed.json")
        let legendary = json(legendaryURL).values.compactMap { $0 as? [String: Any] }
        // Legendary is a keyed object; recover JSON insertion order from each app_name value.
        if let data = try? Data(contentsOf: legendaryURL), let pattern = try? NSRegularExpression(pattern: "\"app_name\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")") {
            let raw = String(decoding: data, as: UTF8.self)
            for match in pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                if let range = Range(match.range(at: 1), in: raw),
                   let name = try? JSONDecoder().decode(String.self, from: Data(raw[range].utf8)),
                   let entry = legendary.first(where: { ($0["app_name"] as? String) == name }) { entries.append(entry) }
            }
        } else { entries.append(contentsOf: legendary) }
        entries.append(contentsOf: json(base.appendingPathComponent("nile/installed.json"))["installed"] as? [[String: Any]] ?? [])
        entries.append(contentsOf: (json(base.appendingPathComponent("sideload_apps/library.json"))["games"] as? [[String: Any]] ?? []).filter { ($0["is_installed"] as? Bool) != false })
        return entries.compactMap { entry in
            guard let name = entry["app_name"] as? String, !name.isEmpty else { return nil }
            let id = "heroic:\(gameSlug(name))"
            let old = existing[id]
            let stamp = timestamps[name] as? [String: Any]
            return Game(id: id, title: old?.title ?? (entry["title"] as? String) ?? name,
                        source: .heroic, launchType: .heroic, launchTarget: "heroic://launch/\(name)",
                        iconUrl: old?.iconUrl, coverUrl: old?.coverUrl ?? (entry["art_cover"] as? String),
                        hidden: old?.hidden ?? false, addedAt: old?.addedAt ?? Date().timeIntervalSince1970 * 1000,
                        lastPlayedAt: old?.lastPlayedAt ?? (stamp?["lastPlayed"] as? Double)
                            ?? (stamp?["lastPlayed"] as? String).flatMap(parseGameTimestamp))
        }
    }
    func scan(existing: [String: Game], existingOrder: [Game] = []) async -> [Game] {
        var scanned = await nativeGames(directory: URL(fileURLWithPath: "/Applications"), source: .appstore, existing: existing, requireCategory: true)
        scanned += await nativeGames(directory: home.appendingPathComponent("Applications"), source: .appstore, existing: existing, requireCategory: true)
        scanned += heroic(existing: existing)
        let steamHome = home
        scanned += await Task.detached(priority: .utility) { SteamScanner(home: steamHome).scan(existing: existing) }.value
        scanned += await nativeGames(directory: home.appendingPathComponent("Applications/CrossOver"), source: .crossover, existing: existing, requireCategory: false)
        let merged = Self.merge(existing: existing, scanned: scanned)
        var ordered = existingOrder.filter { $0.source == .custom }
        if existingOrder.isEmpty { ordered = existing.values.filter { $0.source == .custom }.sorted { $0.addedAt < $1.addedAt } }
        var indices = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        for game in scanned {
            guard let mergedGame = merged[game.id] else { continue }
            if let index = indices[game.id] { ordered[index] = mergedGame }
            else { indices[game.id] = ordered.count; ordered.append(mergedGame) }
        }
        return ordered
    }
    static func merge(existing: [String: Game], scanned: [Game]) -> [String: Game] {
        var result = existing.filter { $0.value.source == .custom }
        for var game in scanned {
            if let old = existing[game.id] {
                game.hidden = old.hidden
                game.coverUrl = old.coverUrl ?? game.coverUrl
                game.iconUrl = old.iconUrl ?? game.iconUrl
                game.lastPlayedAt = old.lastPlayedAt ?? game.lastPlayedAt
                game.addedAt = old.addedAt
            }
            result[game.id] = game
        }
        return result
    }
}
