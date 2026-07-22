// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AnnoyO",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AnnoyO", targets: ["AnnoyO"])
    ],
    targets: [
        .executableTarget(
            name: "AnnoyO",
            path: "Sources/AnnoyO"
        )
    ]
)
