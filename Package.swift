// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Apple2Kit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "Apple2Kit", targets: ["Apple2Kit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mdaskalov/MOS6502.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Apple2Kit",
            dependencies: ["MOS6502"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "Apple2KitTests",
            dependencies: ["Apple2Kit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
