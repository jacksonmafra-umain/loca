// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loca",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocaCore", targets: ["LocaCore"]),
        .executable(name: "LocaHelper", targets: ["LocaHelper"]),
        .executable(name: "LocaApp", targets: ["LocaApp"]),
    ],
    targets: [
        .target(name: "LocaCore"),
        .executableTarget(name: "LocaHelper", dependencies: ["LocaCore"]),
        .executableTarget(name: "LocaApp", dependencies: ["LocaCore"]),
        .testTarget(
            name: "LocaCoreTests",
            dependencies: ["LocaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
