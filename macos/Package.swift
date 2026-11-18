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
    ],
    dependencies: [],
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
                "MirrorApp"
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
                "MirrorApp"
            ],
            path: "Tests/MirrorTests"
        ),
    ]
)
