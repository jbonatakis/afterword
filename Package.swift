// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS("14.2")],
    products: [.library(name: "RecorderCore", targets: ["RecorderCore"])],
    targets: [
        .target(name: "CaptureBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "RecorderCore", dependencies: ["CaptureBridge"],
                linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio")]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore", "CaptureBridge"])
    ]
)
