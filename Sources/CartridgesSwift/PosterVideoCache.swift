import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit

/// Converts compressed image animations once, serially, then lets AVFoundation handle playback.
/// Converted files contain artwork only; keys include source URL, modification time and renderer version.
actor PosterVideoCache {
    static let shared = PosterVideoCache()
    private var jobs: [String: Task<URL, Error>] = [:]
    private var tail: Task<URL, Error>?
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.cartridges.swift.rebuild/playback-cache")
    }

    func video(for url: URL) async throws -> URL {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
        let signature = "hevc-alpha-v1-640|\(url.absoluteString)|\(modified?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(modified?.fileSize ?? 0)"
        let key = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(key + ".mov")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let job = jobs[key] { return try await job.value }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = tail
        let job = Task.detached(priority: .utility) {
            // Serialize conversions to prevent several large covers saturating the CPU at startup.
            _ = await previous?.result
            return try await Self.convert(url: url, destination: destination)
        }
        jobs[key] = job; tail = job
        defer { jobs[key] = nil }
        return try await job.value
    }

    private static func convert(url: URL, destination: URL) async throws -> URL {
        let decoder = PosterDecoder(url: url)
        let count = try await decoder.frameCount()
        guard count > 1 else { throw CartridgesError.message("Image is not animated") }
        let first = try await decoder.nextFrame()
        let width = max(2, first.image.width / 2 * 2), height = max(2, first.image.height / 2 * 2)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                                      AVVideoWidthKey: width, AVVideoHeightKey: height,
                                      AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 30]]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 2_000_000]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw CartridgesError.message("Video encoder is unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CartridgesError.message("Video preparation failed") }
        writer.startSession(atSourceTime: .zero)
        var elapsed: TimeInterval = 0
        var frame = first
        do {
            while true {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CartridgesError.message("Video encoder stopped") }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard let pool = adaptor.pixelBufferPool else { throw CartridgesError.message("Video buffer unavailable") }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                      let pixelBuffer else { throw CartridgesError.message("Video buffer allocation failed") }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
                context?.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context?.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard context != nil, adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 60000)) else {
                    throw writer.error ?? CartridgesError.message("Video frame preparation failed")
                }
                elapsed += frame.duration
                if await decoder.cycleFinished() { break }
                frame = try await decoder.nextFrame()
                // A small yield bounds one-time preparation work and keeps UI tasks responsive.
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            writer.endSession(atSourceTime: CMTime(seconds: elapsed, preferredTimescale: 60000))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CartridgesError.message("Video preparation failed") }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch { writer.cancelWriting(); throw error }
    }
}
