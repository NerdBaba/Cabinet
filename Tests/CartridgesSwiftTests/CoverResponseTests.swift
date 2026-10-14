import XCTest
@testable import CartridgesSwift

final class CoverResponseTests: XCTestCase {
    func testGridDoesNotRequireOptionalAnimationMetadata() throws {
        let response = Data("{\"id\":1,\"url\":\"https://example.com/poster.png\",\"width\":600,\"height\":900,\"mime\":\"image/png\"}".utf8)
        let grid = try JSONDecoder().decode(ArtService.Grid.self, from: response)
        XCTAssertEqual(grid.mime, "image/png")
        XCTAssertFalse(grid.is_animated)
    }
    func testDocumentedMinimalGridInfersMimeAndPosterDimensions() throws {
        let response = Data("{\"id\":1,\"url\":\"https://example.com/poster.webp\",\"score\":0,\"style\":\"alternate\",\"thumb\":\"https://example.com/thumb\",\"tags\":[],\"author\":{\"name\":\"Fixture\"}}".utf8)
        let grid = try JSONDecoder().decode(ArtService.Grid.self, from: response)
        XCTAssertEqual(grid.mime, "image/webp")
        XCTAssertEqual(grid.width / grid.height, 2.0 / 3.0, accuracy: 0.001)
    }
}
