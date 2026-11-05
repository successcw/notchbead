// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NotchBead",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "NotchBead", path: "Sources/NotchBead"),
        .testTarget(name: "NotchBeadTests", dependencies: ["NotchBead"], path: "Tests/NotchBeadTests"),
    ]
)
