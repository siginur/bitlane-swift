// swift-tools-version: 5.5
import PackageDescription

let package = Package(
    name: "BitLane",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
    ],
    products: [
        .library(
            name: "BitLane",
            targets: ["BitLane"]
        )
    ],
    targets: [
        .target(
            name: "BitLane"
        ),
        .testTarget(
            name: "BitLaneTests",
            dependencies: ["BitLane"]
        ),
    ]
)
