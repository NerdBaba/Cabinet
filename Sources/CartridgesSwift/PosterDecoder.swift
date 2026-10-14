import Foundation
import CoreGraphics
import ImageIO
import CWebP

struct PosterFrame: @unchecked Sendable {
    let image: CGImage
    let duration: TimeInterval
    let animated: Bool
}

/// Serialized background decoding. WebP advances a persistent compositing decoder rather than
/// asking ImageIO to reconstruct frame N from frame zero on every repaint.
actor PosterDecoder {
    private let url: URL
    private var webP: OpaquePointer?
    private var source: CGImageSource?
    private var index = 0
    private var count = 0
    private var webPCursor = 0
    private let pixelLimit = 640
    private var initialized = false

    init(url: URL) { self.url = url }
    deinit { if let webP { CartridgeWebPDelete(webP) } }

    func nextFrame() async throws -> PosterFrame {
        try Task.checkCancellation()
        if !initialized { try await initialize() }
        if let webP { return try nextWebPFrame(webP) }
        guard let source, count > 0 else { throw CartridgesError.message("Unreadable poster image") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              let decoded = Self.decompressed(image) else { throw CartridgesError.message("Unreadable poster frame") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        let duration = Self.frameDuration(properties)
        index = (index + 1) % count
        return PosterFrame(image: decoded, duration: duration, animated: count > 1)
    }
    func frameCount() async throws -> Int {
        if !initialized { try await initialize() }
        return count
    }
    func cycleFinished() -> Bool { webP != nil ? webPCursor >= count : index == 0 }

    private func initialize() async throws {
        let data: Data
        if url.isFileURL { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        else {
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            let (body, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw CartridgesError.message("Poster download failed")
            }
            data = body
        }
        try Task.checkCancellation()
        guard data.count <= 64 * 1024 * 1024 else { throw CartridgesError.message("Poster exceeds image size limit") }
        let isWebP = data.count >= 12 && String(decoding: data.prefix(4), as: UTF8.self) == "RIFF"
            && String(decoding: data[8..<12], as: UTF8.self) == "WEBP"
        if isWebP {
            webP = data.withUnsafeBytes { bytes in CartridgeWebPCreate(bytes.bindMemory(to: UInt8.self).baseAddress, data.count) }
            guard let webP else { throw CartridgesError.message("Unreadable WebP poster") }
            count = Int(CartridgeWebPFrameCount(webP))
        } else {
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            count = source.map(CGImageSourceGetCount) ?? 0
        }
        initialized = true
    }

    private func nextWebPFrame(_ decoder: OpaquePointer) throws -> PosterFrame {
        if webPCursor >= count { webPCursor = 0 }
        let width = Int(CartridgeWebPWidth(decoder)), height = Int(CartridgeWebPHeight(decoder))
        var duration: TimeInterval = 0
        var buffer: UnsafePointer<UInt8>?
        // Coalesce very fast source frames, preserving their total elapsed time (never slow the loop).
        repeat {
            try Task.checkCancellation()
            var milliseconds: Int32 = 0
            buffer = CartridgeWebPNext(decoder, &milliseconds)
            webPCursor += 1
            guard buffer != nil else { throw CartridgesError.message("WebP decode failed") }
            duration += max(0.01, Double(milliseconds) / 1000)
        } while count > 1 && duration < 0.025 && webPCursor < count
        guard let buffer, let context = CGContext(data: UnsafeMutableRawPointer(mutating: buffer), width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let image = context.makeImage(), let decoded = Self.decompressed(image, maximumDimension: pixelLimit) else {
            throw CartridgesError.message("WebP canvas decode failed")
        }
        return PosterFrame(image: decoded, duration: duration, animated: count > 1)
    }

    /// Own a small, eagerly decoded bitmap. Layer rendering never retains the compressed provider.
    static func decompressed(_ image: CGImage, maximumDimension: Int? = nil) -> CGImage? {
        let scale = maximumDimension.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func frameDuration(_ properties: [String: Any]) -> TimeInterval {
        for value in properties.values {
            guard let dictionary = value as? [String: Any] else { continue }
            let number = dictionary["UnclampedDelayTime"] ?? dictionary["DelayTime"]
            let delay = (number as? NSNumber)?.doubleValue ?? (number as? String).flatMap(Double.init)
            if let delay, delay > 0 { return max(0.01, delay) }
        }
        return 0.1
    }
}

struct PosterPlaybackPolicy {
    static func shouldAnimate(animated: Bool, active: Bool, visible: Bool, onscreen: Bool, reduceMotion: Bool) -> Bool {
        animated && active && visible && onscreen && !reduceMotion
    }
}
