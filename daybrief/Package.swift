// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Daybrief",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The app (xtool.yml `product`).
        .library(name: "Daybrief", targets: ["Daybrief"]),
    ],
    targets: [
        // Parsing, summaries and the notification plan. Plain Foundation, so the
        // tests run anywhere with `swift test`.
        .target(name: "DaybriefCore"),
        .target(name: "Daybrief", dependencies: ["DaybriefCore"]),
        .testTarget(name: "DaybriefCoreTests", dependencies: ["DaybriefCore"]),
    ],
    swiftLanguageModes: [.v5]
)
