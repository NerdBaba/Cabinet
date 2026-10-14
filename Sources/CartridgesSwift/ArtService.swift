import AppKit
import Foundation

@MainActor
final class ArtService {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private let extensions = ["png", "jpg", "webp"]

    func fileURL(id: String, kind: ArtKind) -> URL? {
        extensions.map { directory.appendingPathComponent("\(kind.rawValue)_\(safeArtID(id)).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    func resolve(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw) else { return nil }
        guard url.scheme == "cartridge-art" else { return url }
        guard let kind = ArtKind(rawValue: url.host ?? "") else { return nil }
        let id = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
        return fileURL(id: id, kind: kind)
    }
    func reference(id: String, kind: ArtKind, bust: Bool = true) -> String {
        let id = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return "cartridge-art://\(kind.rawValue)/\(id)" + (bust ? "?v=\(Int(Date().timeIntervalSince1970 * 1000))" : "")
    }
    func clear(id: String, kind: ArtKind) throws {
        for ext in extensions {
            let file = directory.appendingPathComponent("\(kind.rawValue)_\(safeArtID(id)).\(ext)")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    func setCustom(id: String, fileURL: URL, kind: ArtKind) throws -> String {
        var ext = fileURL.pathExtension.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        guard extensions.contains(ext) else { throw CartridgesError.message("Unsupported image type — use PNG, JPG, or WEBP") }
        // Read first, so a failed selection cannot erase the previous override.
        let data = try Data(contentsOf: fileURL)
        guard NSImage(data: data) != nil else { throw CartridgesError.message("The selected file is not a readable image.") }
        let destination = directory.appendingPathComponent("\(kind.rawValue)_\(safeArtID(id)).\(ext)")
        try clear(id: id, kind: kind)
        try data.write(to: destination, options: .atomic)
        return reference(id: id, kind: kind)
    }
    func extractIcon(appURL: URL, id: String) -> String? {
        if fileURL(id: id, kind: .icon) != nil { return reference(id: id, kind: .icon, bust: false) }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 64, height: 64)
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: directory.appendingPathComponent("icon_\(safeArtID(id)).png"), options: .atomic)
            return reference(id: id, kind: .icon, bust: false)
        } catch { return nil }
    }

    private struct Envelope<T: Decodable>: Decodable { let success: Bool; let data: T }
    private struct SearchResult: Decodable { let id: Int; let name: String }
    struct Grid: Decodable {
        let id: Int; let url: String; let width: Double; let height: Double; let mime: String; let is_animated: Bool
        private enum CodingKeys: String, CodingKey { case id, url, width, height, mime, is_animated, animated }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(Int.self, forKey: .id)
            url = try values.decode(String.self, forKey: .url)
            width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 600
            height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 900
            let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
            let fallback = ext == "webp" ? "image/webp" : (ext == "png" || ext == "apng") ? "image/png" : "image/jpeg"
            mime = try values.decodeIfPresent(String.self, forKey: .mime) ?? fallback
            is_animated = try values.decodeIfPresent(Bool.self, forKey: .is_animated)
                ?? values.decodeIfPresent(Bool.self, forKey: .animated) ?? false
        }
    }
    private func api<T: Decodable>(_ endpoint: String, settings: AppSettings) async throws -> [T] {
        guard let url = URL(string: "https://www.steamgriddb.com/api/v2" + endpoint) else { throw CartridgesError.message("Invalid cover search URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(settings.steamGridDbApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CartridgesError.message("SteamGridDB API error \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        if let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any], header["success"] as? Bool == false {
            throw CartridgesError.message((header["errors"] as? [String])?.joined(separator: "; ") ?? "SteamGridDB request failed")
        }
        let result: Envelope<[T]>
        do { result = try JSONDecoder().decode(Envelope<[T]>.self, from: data) }
        catch DecodingError.keyNotFound(let key, _) {
            throw CartridgesError.message("SteamGridDB response is missing \(key.stringValue)")
        }
        return result.success ? result.data : []
    }
    static func searchCandidates(_ title: String) -> [String] {
        let normalized = title.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "\\.(exe|app)$", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\b(win64|win32|x64|x86|shipping|dlss|directx\\d*|launcher|demo|trial)\\b", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        return [title, normalized, normalized.split(separator: " ").prefix(2).joined(separator: " ")]
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    private func closest(_ grids: [Grid]) -> Grid? {
        grids.min { abs($0.width / max($0.height, 1) - 2 / 3) < abs($1.width / max($1.height, 1) - 2 / 3) }
    }
    func fetchCover(id: String, title: String, settings: AppSettings, force: Bool = false, searchTitle: String? = nil) async throws -> String {
        guard !settings.steamGridDbApiKey.isEmpty else { throw CartridgesError.message("SteamGridDB API key not configured") }
        if !force, fileURL(id: id, kind: .cover) != nil { return reference(id: id, kind: .cover, bust: false) }
        let query = searchTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = (query?.isEmpty == false ? query : nil) ?? title
        var matched: Int?
        var searchError: Error?
        for candidate in Self.searchCandidates(term) {
            do {
                let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? candidate
                let results: [SearchResult] = try await api("/search/autocomplete/\(encoded)", settings: settings)
                if let first = results.first { matched = first.id; break }
            } catch { searchError = error }
        }
        guard let matched else {
            if let searchError { throw searchError }
            throw CartridgesError.message("No SteamGridDB match for \"\(term)\"")
        }
        let base = "/grids/game/\(matched)"
        var selected: Grid?
        if settings.preferAnimatedCovers {
            let animated: [Grid] = try await api(base + "?dimensions=600x900&types=animated&nsfw=false&humor=false", settings: settings)
            selected = closest(animated)
        }
        if selected == nil {
            let grids: [Grid] = try await api(base + "?dimensions=600x900&types=static&nsfw=false&humor=false", settings: settings)
            selected = grids.first
            if selected == nil {
                let all: [Grid] = try await api(base, settings: settings)
                let preferred = all.filter { $0.is_animated == settings.preferAnimatedCovers }
                selected = closest(preferred.isEmpty ? all : preferred)
            }
        }
        guard let grid = selected, let url = URL(string: grid.url) else { throw CartridgesError.message("No grid art found for \"\(term)\"") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CartridgesError.message("Cover image download failed") }
        var ext = "jpg"
        if ["image/png", "image/apng"].contains(grid.mime) { ext = "png" }
        else if grid.mime == "image/webp" { ext = "webp" }
        else if extensions.contains(url.pathExtension.lowercased()) { ext = url.pathExtension.lowercased() }
        try clear(id: id, kind: .cover)
        try data.write(to: directory.appendingPathComponent("cover_\(safeArtID(id)).\(ext)"), options: .atomic)
        return reference(id: id, kind: .cover, bust: force)
    }
}
