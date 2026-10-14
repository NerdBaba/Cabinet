import XCTest
import CoreGraphics
import AVFoundation
@testable import CartridgesSwift

final class PosterTests: XCTestCase {
    func testWebPFramesAdvanceAndLoopWithoutCorruptingPriorFrame() async throws {
        // Two original 32x32 solid-color fixture frames, losslessly encoded at 40ms each.
        let data = Data(base64Encoded: "UklGRooAAABXRUJQVlA4WAoAAAACAAAAHwAAHwAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAB8AAB8AACgAAAJWUDhMEAAAAC8fwAcAB1CT/kf/AxHR/wBBTk1GLgAAAAAAAAAAAB8AAB8AACgAAABWUDhMFQAAAC8fwAcAB9AZAklbvO3vf//jiIj+BwA=")!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webp")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = PosterDecoder(url: url)
        let red = try await decoder.nextFrame()
        let firstFinished = await decoder.cycleFinished()
        XCTAssertFalse(firstFinished)
        let blue = try await decoder.nextFrame()
        let secondFinished = await decoder.cycleFinished()
        XCTAssertTrue(secondFinished)
        let loop = try await decoder.nextFrame()
        XCTAssertTrue(red.animated)
        XCTAssertEqual(red.duration, 0.04, accuracy: 0.001)
        XCTAssertEqual(blue.duration, 0.04, accuracy: 0.001)
        let first = pixel(red.image), second = pixel(blue.image), third = pixel(loop.image)
        XCTAssertGreaterThan(first.0, 200); XCTAssertLessThan(first.2, 40)
        XCTAssertGreaterThan(second.2, 200); XCTAssertLessThan(second.0, 40)
        XCTAssertEqual(first.0, third.0)
        XCTAssertGreaterThan(pixel(red.image).0, 200, "Decoding another frame must not overwrite a retained frame's bitmap")
    }
    func testPreparedVideoPreservesLoopDurationAndIsReused() async throws {
        let data = Data(base64Encoded: "UklGRooAAABXRUJQVlA4WAoAAAACAAAAHwAAHwAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAB8AAB8AACgAAAJWUDhMEAAAAC8fwAcAB1CT/kf/AxHR/wBBTk1GLgAAAAAAAAAAAB8AAB8AACgAAABWUDhMFQAAAC8fwAcAB9AZAklbvO3vf//jiIj+BwA=")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.webp")
        try data.write(to: source)
        let cache = PosterVideoCache(directory: directory.appendingPathComponent("cache"))
        let first = try await cache.video(for: source)
        let second = try await cache.video(for: source)
        XCTAssertEqual(first, second)
        let asset = AVURLAsset(url: first)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 0.08, accuracy: 0.015)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let firstImage = try generator.copyCGImage(at: .zero, actualTime: nil)
        let secondImage = try generator.copyCGImage(at: CMTime(seconds: 0.04, preferredTimescale: 60000), actualTime: nil)
        XCTAssertGreaterThan(pixel(firstImage).0, 180)
        XCTAssertGreaterThan(pixel(secondImage).2, 180)
    }

    func testPlaybackStopsForInactiveHiddenOffscreenAndReduceMotion() {
        XCTAssertTrue(PosterPlaybackPolicy.shouldAnimate(animated: true, active: true, visible: true, onscreen: true, reduceMotion: false))
        XCTAssertFalse(PosterPlaybackPolicy.shouldAnimate(animated: true, active: false, visible: true, onscreen: true, reduceMotion: false))
        XCTAssertFalse(PosterPlaybackPolicy.shouldAnimate(animated: true, active: true, visible: false, onscreen: true, reduceMotion: false))
        XCTAssertFalse(PosterPlaybackPolicy.shouldAnimate(animated: true, active: true, visible: true, onscreen: false, reduceMotion: false))
        XCTAssertFalse(PosterPlaybackPolicy.shouldAnimate(animated: true, active: true, visible: true, onscreen: true, reduceMotion: true))
        XCTAssertFalse(PosterPlaybackPolicy.shouldAnimate(animated: false, active: true, visible: true, onscreen: true, reduceMotion: false))
    }

    private func pixel(_ image: CGImage) -> (UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (bytes[0], bytes[1], bytes[2])
    }
}
