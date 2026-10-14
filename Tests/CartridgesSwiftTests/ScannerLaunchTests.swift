import XCTest
@testable import CartridgesSwift

final class ScannerLaunchTests: XCTestCase {
    @MainActor
    func testLaunchReportsStartupAndImmediateFailure() async throws {
        let success = Game(id: "custom:test-success", title: "Safe test", source: .custom, launchType: .shell, launchTarget: "/usr/bin/true")
        try await LaunchService.launch(success)
        var failure = success
        failure.launchTarget = "/usr/bin/false"
        do {
            try await LaunchService.launch(failure)
            XCTFail("Immediate nonzero process exit should report a launch failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("status"))
        }
    }
    @MainActor
    func testHeroicAllStoresAndInstalledFilterPreserveOrderAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CartridgesScanner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("Library/Application Support/heroic")
        func write(_ path: String, _ json: String) throws {
            let destination = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: destination)
        }
        try write("gog_store/installed.json", "{\"installed\":[{\"app_name\":\"gog-one\",\"title\":\"GOG Game\"}]}")
        try write("legendaryConfig/legendary/installed.json", "{\"epic-two\":{\"app_name\":\"epic-two\",\"title\":\"Epic Two\"},\"epic-one\":{\"app_name\":\"epic-one\",\"title\":\"Epic One\"}}")
        try write("nile/installed.json", "{\"installed\":[{\"app_name\":\"amazon-one\",\"title\":\"Amazon Game\"}]}")
        try write("sideload_apps/library.json", "{\"games\":[{\"app_name\":\"sideload\",\"title\":\"Sideload\",\"art_cover\":\"https://example.invalid/cover.png\"},{\"app_name\":\"uninstalled\",\"is_installed\":false}]}")
        try write("store/timestamp.json", "{\"gog-one\":{\"lastPlayed\":777},\"epic-two\":{\"lastPlayed\":888}}")
        let old = Game(id: "heroic:gog-one", title: "Renamed", source: .heroic, launchType: .heroic,
                       launchTarget: "heroic://launch/gog-one", coverUrl: "custom-cover", hidden: true,
                       addedAt: 100, lastPlayedAt: 123)
        let scanner = GameScanner(art: ArtService(directory: root.appendingPathComponent("art")), home: root)
        let games = scanner.heroic(existing: [old.id: old])
        XCTAssertEqual(games.map(\.id), ["heroic:gog-one", "heroic:epic-two", "heroic:epic-one", "heroic:amazon-one", "heroic:sideload"])
        XCTAssertEqual(games.first?.title, "Renamed")
        XCTAssertEqual(games.first?.lastPlayedAt, 123)
        XCTAssertEqual(games.first?.coverUrl, "custom-cover")
        XCTAssertEqual(games.first?.hidden, true)
        XCTAssertEqual(games[1].lastPlayedAt, 888)
        XCTAssertEqual(games.last?.coverUrl, "https://example.invalid/cover.png")
        XCTAssertEqual(games.last?.launchTarget, "heroic://launch/sideload")
    }

    @MainActor
    func testArgvHandlesSpacesQuotesAndEmptyArgumentsWithoutShellEvaluation() throws {
        XCTAssertEqual(try LaunchService.arguments("\"/Applications/My Game/game\" --name 'two words' escaped\\ space \"\""),
                       ["/Applications/My Game/game", "--name", "two words", "escaped space", ""])
        XCTAssertEqual(try LaunchService.arguments("echo '$HOME' ; rm -rf fake"), ["echo", "$HOME", ";", "rm", "-rf", "fake"])
        XCTAssertEqual(try LaunchService.arguments("   "), [])
        XCTAssertThrowsError(try LaunchService.arguments("command 'unfinished"))
        XCTAssertThrowsError(try LaunchService.arguments("command trailing\\"))
    }

    @MainActor
    func testCoverSearchNormalizationAndCustomLogoResolution() throws {
        XCTAssertEqual(ArtService.searchCandidates("LegoBatmanLOTDK-Win64-Shipping-DLSS"),
                       ["LegoBatmanLOTDK-Win64-Shipping-DLSS", "Lego Batman LOTDK", "Lego Batman"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CartridgesArt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let art = ArtService(directory: root)
        let expected = root.appendingPathComponent("icon_custom_logo.jpg")
        try Data([1]).write(to: expected)
        XCTAssertEqual(art.resolve("cartridge-art://icon/custom%3Alogo?v=123"), expected)
        XCTAssertEqual(safeArtID("heroic:a/b\\c"), "heroic_a_b_c")
    }
}
