// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Afterword",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Afterword", targets: ["Afterword"]),
               .executable(name: "AfterwordMCP", targets: ["AfterwordMCP"])],
    dependencies: [.package(path: "Vendor/KeyboardShortcuts"),
                   .package(url: "https://github.com/jbonatakis/lookback.git", revision: "8264e15991cf7ef7c9f9a65f95ffaf71519522a1")],
    targets: [
        .target(name: "CaptureBridge", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "RecorderCore", dependencies: ["CaptureBridge", .product(name: "Lookback", package: "lookback")],
                linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"), .linkedLibrary("sqlite3")]),
        .executableTarget(name: "Afterword", dependencies: ["RecorderCore", "KeyboardShortcuts"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("IOKit"), .linkedFramework("EventKit")]),
        .executableTarget(name: "AfterwordMCP", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore", "CaptureBridge"])
    ]
)
