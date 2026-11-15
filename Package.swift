// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "CallRecorder", targets: ["CallRecorder"]),
               .executable(name: "CallRecorderMCP", targets: ["CallRecorderMCP"])],
    dependencies: [.package(path: "Vendor/KeyboardShortcuts")],
    targets: [
        .target(name: "CaptureBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "RecorderCore", dependencies: ["CaptureBridge"],
                linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"), .linkedLibrary("sqlite3")]),
        .executableTarget(name: "CallRecorder", dependencies: ["RecorderCore", "KeyboardShortcuts"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("IOKit"), .linkedFramework("EventKit")]),
        .executableTarget(name: "CallRecorderMCP", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore", "CaptureBridge"])
    ]
)
