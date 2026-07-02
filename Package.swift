// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreAudioTapKit",
    platforms: [.macOS("14.2")],  // CATap floor: AudioHardwareCreateProcessTap
    products: [
        .library(name: "CoreAudioTapKit", targets: ["CoreAudioTapKit"]),
        .executable(name: "TapKitDemo", targets: ["TapKitDemo"]),
    ],
    targets: [
        .target(name: "CoreAudioTapKit"),
        .executableTarget(
            name: "TapKitDemo",
            dependencies: ["CoreAudioTapKit"]
        ),
        .testTarget(
            name: "CoreAudioTapKitTests",
            dependencies: ["CoreAudioTapKit"]
        ),
    ]
)
