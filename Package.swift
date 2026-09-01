// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zero-copy-feed-kit",
    // Only platforms CI actually builds are declared. Linux needs no declaration;
    // the demo app's CI builds for `generic/platform=iOS Simulator`.
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ZeroCopyFeed", targets: ["ZeroCopyFeed"]),
        .library(name: "ZeroCopyFeedUI", targets: ["ZeroCopyFeedUI"])
    ],
    targets: [
        .target(name: "ZeroCopyFeed"),
        .target(name: "ZeroCopyFeedUI", dependencies: ["ZeroCopyFeed"]),
        .testTarget(name: "ZeroCopyFeedTests", dependencies: ["ZeroCopyFeed"])
    ]
)
