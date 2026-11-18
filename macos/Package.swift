// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirrorMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MirrorApp", targets: ["MirrorAppLauncher"]),
        .library(name: "MirrorCoreBridge", targets: ["MirrorCoreBridge"]),
        .library(name: "MirrorRenderer", targets: ["MirrorRenderer"]),
        .library(name: "MirrorWebcamExtension", targets: ["MirrorWebcamExtension"]),
        .library(name: "MirrorFSExtension", targets: ["MirrorFSExtension"]),
        .library(name: "NearDropReceiver", targets: ["NearDropReceiver"]),
        .library(name: "MirrorAppLib", targets: ["MirrorApp"]),
        .library(name: "MirrorDesk", targets: ["MirrorDesk"]),
        .executable(name: "mirror-desk", targets: ["MirrorDeskCLI"]),
        .executable(name: "mirror-window", targets: ["MirrorWindowCLI"]),
    ],
    // NearbyShare's dependencies, pinned to the versions NearDrop's Xcode project resolves.
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.21.0"),
        .package(url: "https://github.com/leif-ibsen/SwiftECC", exact: "3.5.3"),
        .package(url: "https://github.com/leif-ibsen/BigInt", exact: "1.9.0"),
    ],
    targets: [
        .target(
            name: "MirrorCoreBridge",
            dependencies: [],
            path: "Sources/MirrorCoreBridge"
        ),
        .target(
            name: "MirrorRenderer",
            dependencies: ["MirrorCoreBridge"],
            path: "Sources/MirrorRenderer"
        ),
        .target(
            name: "MirrorWebcamExtension",
            dependencies: ["MirrorCoreBridge"],
            path: "Sources/MirrorWebcamExtension"
        ),
        .target(
            name: "MirrorFSExtension",
            dependencies: ["MirrorCoreBridge"],
            path: "Sources/MirrorFSExtension"
        ),
        .target(
            name: "NearDropReceiver",
            dependencies: ["MirrorCoreBridge"],
            path: "Sources/NearDropReceiver"
        ),
        .target(
            name: "NearbyShare",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftECC", package: "SwiftECC"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            path: "Vendor/NearbyShare",
            exclude: ["UNLICENSE", "README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MirrorDesk",
            dependencies: ["MirrorRenderer", "NearbyShare"],
            path: "Sources/MirrorDesk"
        ),
        .executableTarget(
            name: "MirrorDeskCLI",
            dependencies: ["MirrorDesk"],
            path: "Sources/MirrorDeskCLI"
        ),
        .executableTarget(
            name: "MirrorWindowCLI",
            dependencies: ["MirrorDesk"],
            path: "Sources/MirrorWindowCLI"
        ),
        .target(
            name: "MirrorApp",
            dependencies: [
                "MirrorCoreBridge",
                "MirrorRenderer",
                "MirrorWebcamExtension",
                "MirrorFSExtension",
                "NearDropReceiver"
            ],
            path: "Sources/MirrorApp"
        ),
        .executableTarget(
            name: "MirrorAppLauncher",
            dependencies: [
                "MirrorApp",
                "MirrorDesk"
            ],
            path: "Sources/MirrorAppLauncher"
        ),
        .testTarget(
            name: "MirrorTests",
            dependencies: [
                "MirrorCoreBridge",
                "MirrorRenderer",
                "MirrorWebcamExtension",
                "MirrorFSExtension",
                "NearDropReceiver",
                "MirrorApp",
                "MirrorDesk"
            ],
            path: "Tests/MirrorTests"
        ),
    ]
)
