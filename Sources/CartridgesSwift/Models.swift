import Foundation

enum GameSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case appstore, heroic, crossover, steam, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appstore: return "App Store"
        case .heroic: return "Heroic"
        case .crossover: return "CrossOver"
        case .steam: return "Steam"
        case .custom: return "Custom Games"
        }
    }
}
enum LaunchType: String, Codable, CaseIterable, Sendable { case app, heroic, steam, shell }
enum AfterLaunchAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case stay, hide, minimize, quit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stay: return "Do nothing"
        case .hide: return "Hide Cabinet"
        case .minimize: return "Minimize window"
        case .quit: return "Quit Cabinet"
        }
    }
}
enum ArtKind: String, CaseIterable, Sendable { case cover, icon }

struct Game: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var source: GameSource
    var launchType: LaunchType
    var launchTarget: String
    var workingDir: String?
    var iconUrl: String?
    var coverUrl: String?
    var hidden = false
    var addedAt: Double = Date().timeIntervalSince1970 * 1000
    var lastPlayedAt: Double?
}

extension Game {
    private enum CodingKeys: String, CodingKey {
        case id, title, source, launchType, launchTarget, workingDir, iconUrl, coverUrl, hidden, addedAt, lastPlayedAt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        source = try values.decode(GameSource.self, forKey: .source)
        launchType = try values.decode(LaunchType.self, forKey: .launchType)
        launchTarget = try values.decode(String.self, forKey: .launchTarget)
        workingDir = try values.decodeIfPresent(String.self, forKey: .workingDir)
        iconUrl = try values.decodeIfPresent(String.self, forKey: .iconUrl)
        coverUrl = try values.decodeIfPresent(String.self, forKey: .coverUrl)
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        addedAt = (try? values.decode(Double.self, forKey: .addedAt)) ?? Date().timeIntervalSince1970 * 1000
        lastPlayedAt = (try? values.decode(Double.self, forKey: .lastPlayedAt))
            ?? (try? values.decode(String.self, forKey: .lastPlayedAt)).flatMap(parseGameTimestamp)
    }
}

func parseGameTimestamp(_ text: String) -> Double? {
    if let number = Double(text) { return number }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    return date.map { $0.timeIntervalSince1970 * 1000 }
}

struct GamesDocument: Codable { var games: [String: Game] = [:] }

struct AppSettings: Codable, Equatable, Sendable {
    var steamGridDbApiKey = ""
    var afterLaunchAction: AfterLaunchAction = .stay
    var preferAnimatedCovers = false

    init() {}
    private enum CodingKeys: String, CodingKey { case steamGridDbApiKey, afterLaunchAction, preferAnimatedCovers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        steamGridDbApiKey = try values.decodeIfPresent(String.self, forKey: .steamGridDbApiKey) ?? ""
        afterLaunchAction = try values.decodeIfPresent(AfterLaunchAction.self, forKey: .afterLaunchAction) ?? .stay
        preferAnimatedCovers = try values.decodeIfPresent(Bool.self, forKey: .preferAnimatedCovers) ?? false
    }
}

enum CartridgesError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

func gameSlug(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "\\.app$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func safeArtID(_ id: String) -> String {
    id.replacingOccurrences(of: "[:/\\\\]", with: "_", options: .regularExpression)
}
