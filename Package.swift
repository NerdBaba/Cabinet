// swift-tools-version: 5.9
import PackageDescription
import Foundation

let webP = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/WebP").path

let package = Package(
    name: "Cabinet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cabinet", targets: ["CartridgesSwift"])],
    targets: [
        .target(name: "CWebP", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I", webP + "/include"])],
                linkerSettings: [.unsafeFlags(["-L", webP + "/lib"]), .linkedLibrary("webpdemux"), .linkedLibrary("webpdecoder")]),
        .executableTarget(name: "CartridgesSwift", dependencies: ["CWebP"]),
        .testTarget(name: "CartridgesSwiftTests", dependencies: ["CartridgesSwift"])
    ]
)
