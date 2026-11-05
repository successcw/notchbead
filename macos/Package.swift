// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Heed",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Heed", path: "Sources/Heed"),
        .testTarget(name: "HeedTests", dependencies: ["Heed"], path: "Tests/HeedTests"),
    ]
)
