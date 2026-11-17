// swift-tools-version: 6.2
import PackageDescription

// Scripts/build-diarization.sh stages just the sources needed by the offline worker.
let package = Package(
    name: "SpeakerWorker",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "MachTaskSelfWrapper", publicHeadersPath: "include"),
        .target(name: "FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "FluidAudio", dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
                exclude: ["ASR/Parakeet/Unified/benchmark.md"], swiftSettings: [.define("Diarizer")]),
        .executableTarget(name: "SpeakerWorker", dependencies: ["FluidAudio"])
    ],
    cxxLanguageStandard: .cxx17)
