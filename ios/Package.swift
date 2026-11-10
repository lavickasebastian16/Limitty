// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Limitty",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The app (xtool.yml `product`).
        .library(name: "Limitty", targets: ["Limitty"]),
        // The home/lock-screen widget extension (xtool.yml `extensions`).
        .library(name: "LimittyWidget", targets: ["LimittyWidget"]),
    ],
    targets: [
        // Networking, parsing and storage shared by the app and the widget.
        // Plain Foundation, so it also builds and tests on Linux.
        .target(name: "LimittyCore"),
        .target(name: "Limitty", dependencies: ["LimittyCore"]),
        .target(name: "LimittyWidget", dependencies: ["LimittyCore"]),
        .testTarget(name: "LimittyCoreTests", dependencies: ["LimittyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
