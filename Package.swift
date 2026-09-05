// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyncCastReceiver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "synccast-receiver", targets: ["synccast-receiver"]),
        .library(name: "ReceiverCore", targets: ["ReceiverCore"]),
    ],
    targets: [
        // Header-only C shim for release/acquire atomics. The PCM ring is
        // written by the UDP thread and read by the CoreAudio render thread;
        // no Darwin lock may ever be taken on the render thread.
        .target(name: "CReceiverAtomics"),
        .target(
            name: "ReceiverCore",
            dependencies: ["CReceiverAtomics"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "synccast-receiver",
            dependencies: ["ReceiverCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReceiverCoreTests",
            dependencies: ["ReceiverCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
