// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "archie",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "ArchieCore", targets: ["ArchieCore"]),
        .executable(name: "archie-receiver", targets: ["ArchieReceiver"]),
    ],
    targets: [
        .target(name: "ArchieCore"),
        .executableTarget(
            name: "ArchieReceiver",
            dependencies: ["ArchieCore"]
        ),
        .testTarget(
            name: "ArchieCoreTests",
            dependencies: ["ArchieCore"]
        ),
    ]
)
