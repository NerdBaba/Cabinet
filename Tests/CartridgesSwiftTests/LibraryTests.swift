import XCTest
@testable import CartridgesSwift

final class LibraryTests: XCTestCase {
    func testHeroicISODateInOriginalLibraryDecodesAlongsideNumericDates() throws {
        let fixture = Data("{\"id\":\"heroic:test\",\"title\":\"Test\",\"source\":\"heroic\",\"launchType\":\"heroic\",\"launchTarget\":\"heroic://launch/test\",\"hidden\":false,\"addedAt\":123,\"lastPlayedAt\":\"2026-04-22T15:26:11.974Z\"}".utf8)
        let game = try JSONDecoder().decode(Game.self, from: fixture)
        XCTAssertEqual(game.lastPlayedAt ?? 0, 1776871571974, accuracy: 1)
        let roundTrip = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(game))
        XCTAssertEqual(roundTrip, game)
    }

    @MainActor
    func testBrokenGamesFileStillLoadsIndependentSettings() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("broken json".utf8).write(to: root.appendingPathComponent("games.json"))
        try Data("{\"afterLaunchAction\":\"minimize\"}".utf8).write(to: root.appendingPathComponent("settings.json"))
        let store = LibraryStore(directory: root, originalDirectory: root.appendingPathComponent("absent"))
        await store.load()
        XCTAssertTrue(store.games.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.settings.afterLaunchAction, .minimize)
    }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CartridgesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testMigrationCopiesOnceAndLeavesOriginalUntouched() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let rebuilt = root.appendingPathComponent("rebuilt")
        try FileManager.default.createDirectory(at: original.appendingPathComponent("art"), withIntermediateDirectories: true)
        let fixture = Data("{\"games\":{\"custom:a\":{\"id\":\"custom:a\",\"title\":\"Original\",\"source\":\"custom\",\"launchType\":\"shell\",\"launchTarget\":\"/usr/bin/true\",\"hidden\":false,\"addedAt\":123}}}".utf8)
        try fixture.write(to: original.appendingPathComponent("games.json"))
        try Data("{\"afterLaunchAction\":\"hide\"}".utf8).write(to: original.appendingPathComponent("settings.json"))
        try Data([1, 2, 3]).write(to: original.appendingPathComponent("art/custom_a.png"))
        let store = LibraryStore(directory: rebuilt, originalDirectory: original)
        await store.load()
        XCTAssertEqual(store.games.map(\.title), ["Original"])
        XCTAssertEqual(store.settings.afterLaunchAction, .hide)
        XCTAssertEqual(store.settings.steamGridDbApiKey, "")
        XCTAssertEqual(try Data(contentsOf: rebuilt.appendingPathComponent("art/custom_a.png")), Data([1, 2, 3]))
        try await store.update(id: "custom:a", title: "Rebuilt")
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("games.json")), fixture)
        let reopened = LibraryStore(directory: rebuilt, originalDirectory: original)
        await reopened.load()
        XCTAssertEqual(reopened.games.first?.title, "Rebuilt")
    }

    @MainActor
    func testCustomCRUDAndWorkingDirectoryRoundTrip() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(directory: root.appendingPathComponent("store"), originalDirectory: root.appendingPathComponent("absent"))
        await store.load()
        let game = try await store.addCustom(title: "Test Game", command: "/usr/bin/true", workingDir: "/tmp")
        try await store.update(id: game.id, title: "Edited", command: "/usr/bin/false", workingDir: "")
        await store.setHidden(id: game.id, hidden: true)
        let reopened = LibraryStore(directory: store.directory, originalDirectory: root.appendingPathComponent("absent"))
        await reopened.load()
        XCTAssertEqual(reopened.games.first?.title, "Edited")
        XCTAssertEqual(reopened.games.first?.launchTarget, "/usr/bin/false")
        XCTAssertNil(reopened.games.first?.workingDir)
        XCTAssertEqual(reopened.games.first?.hidden, true)
        await reopened.remove(id: game.id)
        let removed = LibraryStore(directory: store.directory, originalDirectory: root.appendingPathComponent("absent"))
        await removed.load()
        XCTAssertTrue(removed.games.isEmpty)
    }

    @MainActor
    func testScanMergeRetainsOverridesAndCustomButDropsAbsentImportedGames() {
        let custom = Game(id: "custom:test", title: "Custom", source: .custom, launchType: .shell, launchTarget: "true")
        let prior = Game(id: "heroic:test", title: "Renamed", source: .heroic, launchType: .heroic, launchTarget: "heroic://launch/test", iconUrl: "old-icon", coverUrl: "old-cover", hidden: true, addedAt: 100, lastPlayedAt: 200)
        let absent = Game(id: "appstore:gone", title: "Gone", source: .appstore, launchType: .app, launchTarget: "/gone.app")
        let scan = Game(id: prior.id, title: "Scanned", source: .heroic, launchType: .heroic, launchTarget: "heroic://launch/test", iconUrl: "new-icon", coverUrl: "new-cover", hidden: false, addedAt: 300, lastPlayedAt: 400)
        let result = GameScanner.merge(existing: [custom.id: custom, prior.id: prior, absent.id: absent], scanned: [scan])
        XCTAssertEqual(result[custom.id], custom)
        XCTAssertNil(result[absent.id])
        XCTAssertEqual(result[prior.id]?.coverUrl, "old-cover")
        XCTAssertEqual(result[prior.id]?.iconUrl, "old-icon")
        XCTAssertEqual(result[prior.id]?.hidden, true)
        XCTAssertEqual(result[prior.id]?.addedAt, 100)
        XCTAssertEqual(result[prior.id]?.lastPlayedAt, 200)
    }
}
