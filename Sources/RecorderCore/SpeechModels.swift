import Foundation
import CryptoKit

public struct SpeechModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let repository: String
    public let revision: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let licenseURL: URL
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    public var downloadURL: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")! }
    public var modelCardURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    public var englishOnly: Bool { id == "parakeet-unified-en-0.6b" || id == "whisper-base.en" }
    // Published Handy GGUFs pinned to immutable revisions and LFS SHA-256 digests.
    public static let catalog: [SpeechModel] = [
        SpeechModel(id: "parakeet-unified-en-0.6b", name: "Parakeet Unified", detail: "English · a good starting point for calls",
                    repository: "handy-computer/parakeet-unified-en-0.6b-gguf", revision: "843b1b175ace04f5a89d379c79e2518c0d065b25",
                    filename: "parakeet-unified-en-0.6b-Q8_0.gguf", bytes: 731357568,
                    sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795", licenseURL: URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/")!),
        SpeechModel(id: "nemotron-3.5-asr-streaming-0.6b", name: "Nemotron 3.5", detail: "Multilingual · also used by Handy",
                    repository: "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf", revision: "53ce288f69326b415aeef030cfcb02a08a8096dd",
                    filename: "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf", bytes: 751094240,
                    sha256: "b94545b313b3223fda7b2857a52681da813935c2127643d1e9ff0c23d988089c", licenseURL: URL(string: "https://openmdw.ai/license/1-1/")!),
        SpeechModel(id: "whisper-base.en", name: "Whisper Base English", detail: "English · smaller download, lighter on memory",
                    repository: "handy-computer/whisper-base.en-gguf", revision: "0dd374130837de419035c77d76440aad61ca135c",
                    filename: "whisper-base.en-Q8_0.gguf", bytes: 84886208,
                    sha256: "3b46ca40bccbf7609c68d88a36d96077a04ca7c87f2060ede06f129fac3e7652", licenseURL: URL(string: "https://huggingface.co/handy-computer/whisper-base.en-gguf")!),
        SpeechModel(id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", detail: "Multilingual · larger Whisper model",
                    repository: "handy-computer/whisper-large-v3-turbo-gguf", revision: "18ada752005f5fddef499256f9a458d0b37a203a",
                    filename: "whisper-large-v3-turbo-Q8_0.gguf", bytes: 886381728,
                    sha256: "257aa7ec9121c22c167d5e2c49e3e76b4ba0e6e27ebc13074eba0a80f8190220", licenseURL: URL(string: "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf")!),
    ]
}
