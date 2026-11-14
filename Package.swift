// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "CallRecorder", targets: ["CallRecorder"])],
    dependencies: [.package(path: "Vendor/KeyboardShortcuts")],
    targets: [
        .target(name: "CaptureBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "RecorderCore", dependencies: ["CaptureBridge"],
                linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio")]),
        .executableTarget(name: "CallRecorder", dependencies: ["RecorderCore", "KeyboardShortcuts"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("IOKit")]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore", "CaptureBridge"])
    ]
)
