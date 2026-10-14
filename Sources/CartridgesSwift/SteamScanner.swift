import Foundation

/// Reads installed-game manifests only. Owned-but-uninstalled titles are not installations.
struct SteamScanner: Sendable {
    let root: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        root = home.appendingPathComponent("Library/Application Support/Steam")
    }

    func scan(existing: [String: Game]) -> [Game] {
        let manager = FileManager.default
        var libraries = [root]
        for location in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            guard let document = read(root.appendingPathComponent(location)),
                  let folders = document.object("libraryfolders") else { continue }
            for key in folders.keys.sorted() where Int(key) != nil {
                let path = folders[key]?.stringValue ?? folders[key]?.objectValue?.string("path")
                if let path, !path.isEmpty { libraries.append(URL(fileURLWithPath: path)) }
            }
        }
        var seenLibraries = Set<String>()
        var seenGames = Set<String>()
        var games: [Game] = []
        for library in libraries where seenLibraries.insert(library.standardizedFileURL.path).inserted {
            let apps = library.appendingPathComponent("steamapps")
            let files = (try? manager.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let state = read(file)?.object("AppState"),
                      let appID = state.string("appid"), UInt64(appID) != nil,
                      let name = state.string("name"), !name.isEmpty,
                      let directory = state.string("installdir"), !directory.isEmpty,
                      let flags = state.string("StateFlags").flatMap(Int.init), flags & 4 != 0 else { continue }
                let installation = apps.appendingPathComponent("common").appendingPathComponent(directory).standardizedFileURL
                guard installation.path.hasPrefix(apps.appendingPathComponent("common").path + "/"),
                      manager.fileExists(atPath: installation.path) else { continue }
                let id = "steam:\(appID)"
                guard seenGames.insert(id).inserted else { continue }
                let old = existing[id]
                games.append(Game(id: id, title: old?.title ?? name, source: .steam, launchType: .steam,
                                  launchTarget: "steam://rungameid/\(appID)", iconUrl: old?.iconUrl,
                                  coverUrl: old?.coverUrl ?? cachedCover(appID: appID)?.absoluteString,
                                  hidden: old?.hidden ?? false, addedAt: old?.addedAt ?? Date().timeIntervalSince1970 * 1000,
                                  lastPlayedAt: old?.lastPlayedAt ?? state.string("LastPlayed").flatMap(Double.init).map { $0 * 1000 }))
            }
        }
        return games
    }

    private func cachedCover(appID: String) -> URL? {
        let cache = root.appendingPathComponent("appcache/librarycache")
        let names = ["library_600x900.jpg", "library_600x900.png", "library_600x900.webp"]
        var directories = [cache.appendingPathComponent(appID)]
        // New Steam builds add one hash directory; never traverse the complete cache.
        directories += (try? FileManager.default.contentsOfDirectory(at: directories[0], includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            for name in names {
                let file = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { return file }
            }
        }
        for name in names {
            let file = cache.appendingPathComponent(appID + "_" + name)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }
    private func read(_ url: URL) -> [String: VDFValue]? {
        guard let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return try? VDFParser.parse(text)
    }
}

indirect enum VDFValue {
    case string(String), object([String: VDFValue])
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var objectValue: [String: VDFValue]? { if case .object(let value) = self { return value }; return nil }
}
extension Dictionary where Key == String, Value == VDFValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func object(_ key: String) -> [String: VDFValue]? { self[key]?.objectValue }
}

enum VDFParser {
    static func parse(_ text: String) throws -> [String: VDFValue] {
        let characters = Array(text)
        var index = 0
        func token() throws -> String? {
            while index < characters.count {
                if characters[index].isWhitespace { index += 1; continue }
                if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count && characters[index] != "\n" { index += 1 }
                    continue
                }
                break
            }
            guard index < characters.count else { return nil }
            let first = characters[index]; index += 1
            if first == "{" || first == "}" { return String(first) }
            var result = ""
            if first == "\"" {
                while index < characters.count {
                    let character = characters[index]; index += 1
                    if character == "\"" { return result }
                    if character == "\\", index < characters.count {
                        let escaped = characters[index]; index += 1
                        switch escaped {
                        case "\"", "\\": result.append(escaped)
                        case "n": result.append("\n")
                        case "t": result.append("\t")
                        default: result.append("\\"); result.append(escaped)
                        }
                    } else { result.append(character) }
                }
                throw CartridgesError.message("Unterminated Steam manifest string")
            }
            result.append(first)
            while index < characters.count && !characters[index].isWhitespace && characters[index] != "{" && characters[index] != "}" {
                result.append(characters[index]); index += 1
            }
            return result
        }
        func object(depth: Int, nested: Bool) throws -> [String: VDFValue] {
            guard depth < 64 else { throw CartridgesError.message("Steam manifest nesting too deep") }
            var values: [String: VDFValue] = [:]
            while let key = try token() {
                if key == "}" {
                    guard nested else { throw CartridgesError.message("Unexpected Steam manifest brace") }
                    return values
                }
                guard key != "{", let value = try token(), value != "}" else { throw CartridgesError.message("Invalid Steam manifest pair") }
                values[key] = value == "{" ? .object(try object(depth: depth + 1, nested: true)) : .string(value)
            }
            guard !nested else { throw CartridgesError.message("Unterminated Steam manifest object") }
            return values
        }
        return try object(depth: 0, nested: false)
    }
}
