import XCTest
@testable import CartridgesSwift

final class SteamTests: XCTestCase {
    @MainActor
    func testSteamDiscoversInstalledGamesAcrossLibrariesWithCachedArt() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("SteamFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        let external = home.appendingPathComponent("External Library")
        for library in [steam, external] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent("steamapps/common/TestGame"), withIntermediateDirectories: true)
        }
        let folders = "\"libraryfolders\" { \"0\" { \"path\" \"\(steam.path)\" } \"1\" { \"path\" \"\(external.path)\" } }"
        try Data(folders.utf8).write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        try Data("\"AppState\" { \"appid\" \"123\" \"name\" \"Installed Game\" \"StateFlags\" \"4\" \"installdir\" \"TestGame\" \"LastPlayed\" \"1700000000\" }".utf8)
            .write(to: external.appendingPathComponent("steamapps/appmanifest_123.acf"))
        try Data("\"AppState\" { \"appid\" \"124\" \"name\" \"Downloading Game\" \"StateFlags\" \"1024\" \"installdir\" \"TestGame\" }".utf8)
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_124.acf"))
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("appcache/librarycache/123"), withIntermediateDirectories: true)
        let cover = steam.appendingPathComponent("appcache/librarycache/123/library_600x900.jpg")
        try Data([1, 2, 3]).write(to: cover)
        let artDirectory = home.appendingPathComponent("art")
        try FileManager.default.createDirectory(at: artDirectory, withIntermediateDirectories: true)
        let games = await GameScanner(art: ArtService(directory: artDirectory), home: home).scan(existing: [:])
        let found = games.filter { $0.source.rawValue == "steam" }
        XCTAssertEqual(found.count, 1, "Installed Steam games must be imported from external libraries; incomplete downloads excluded")
        XCTAssertEqual(found.first?.id, "steam:123")
        XCTAssertEqual(found.first?.title, "Installed Game")
        XCTAssertEqual(found.first?.launchTarget, "steam://rungameid/123")
        XCTAssertEqual(found.first?.lastPlayedAt, 1700000000000)
        XCTAssertEqual(found.first?.coverUrl, cover.absoluteString)
    }
}
