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
        .executable(name: "archie-menubar", targets: ["ArchieMenuBar"]),
    ],
    targets: [
        .target(name: "ArchieCore"),
        .executableTarget(
            name: "ArchieReceiver",
            dependencies: ["ArchieCore"]
        ),
        .executableTarget(
            name: "ArchieMenuBar"
        ),
        .testTarget(
            name: "ArchieCoreTests",
            dependencies: ["ArchieCore"]
        ),
    ]
)
