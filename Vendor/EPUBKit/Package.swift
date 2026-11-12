// swift-tools-version: 6.1
import Foundation
import PackageDescription

// The public source snapshot ships without Tests/, so the test target is
// declared only where its sources exist.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/EPUBKitTests")

let package = Package(
    name: "EPUBKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EPUBKit", targets: ["EPUBKit"])
    ],
    dependencies: [
        .package(path: "../ZIPFoundation")
    ],
    targets: [
        .target(name: "EPUBKit", dependencies: ["ZIPFoundation"])
    ] + (hasTests ? [
        .testTarget(name: "EPUBKitTests", dependencies: ["EPUBKit", "ZIPFoundation"])
    ] : [])
)
