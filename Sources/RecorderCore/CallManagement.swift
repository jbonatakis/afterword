import Foundation

public struct CallDetails: Codable, Equatable, Sendable {
    public var version = 2
    public var title: String?
    public var participants: [String]
    public var tags: [String]
    public var description: String
    /// Frozen defaults for existing transcript versions, keyed by their run directory name.
    public var automaticParticipants: [String: String]?
    public init(title: String? = nil, participants: [String] = [], tags: [String] = [], description: String = "", automaticParticipants: [String: String]? = nil) {
        self.title = title; self.participants = participants; self.tags = tags; self.description = description
        self.automaticParticipants = automaticParticipants
    }
    public var normalized: CallDetails {
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
        }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: title?.isEmpty == false ? title : nil, participants: unique(participants), tags: unique(tags),
                     description: description.trimmingCharacters(in: .whitespacesAndNewlines), automaticParticipants: automaticParticipants)
    }
}

public enum CallDetailsStore {
    static func singleParticipant(for input: TranscriptionInput) -> String? {
        guard let track = input.tracks.first else { return nil }
        let audio = URL(fileURLWithPath: track.path)
        let directory = RecordingTrack.allCases.contains { $0.filename == audio.lastPathComponent }
        guard let details = try? load(for: directory ? input.outputDirectory : audio, isDirectory: directory), details.participants.count == 1 else { return nil }
        return details.participants.first
    }
    public static func url(for recording: URL, isDirectory: Bool) -> URL {
        isDirectory ? recording.appendingPathComponent("CallDetails.json") : recording.appendingPathExtension("call.json")
    }
    public static func load(for recording: URL, isDirectory: Bool) throws -> CallDetails {
        let file = url(for: recording, isDirectory: isDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        guard PrivateFiles.isRegular(file) else { throw RecorderError.message("Call details must be stored in a regular file.") }
        let details = try JSONDecoder().decode(CallDetails.self, from: Data(contentsOf: file))
        guard (1...2).contains(details.version) else { throw RecorderError.message("These call details use a newer format. They have not been changed.") }
        return details.normalized
    }
    public static func save(_ details: CallDetails, for recording: LibraryRecording) throws {
        try CallFileOperations.validateRecording(recording)
        // Do not silently replace an unreadable or newer details file.
        let previous = try load(for: recording.url, isDirectory: recording.isDirectory)
        var saved = details.normalized
        var assignments = previous.automaticParticipants ?? [:]
        // Freeze the old one-person assumption BEFORE adding a second name.
        // Existing transcript bytes stay untouched, and only this call's runs are associated.
        let inferred = previous.participants.count == 1 ? previous.participants.first : saved.participants.count == 1 ? saved.participants.first : nil
        if let inferred {
            let folder = recording.isDirectory ? recording.url : recording.url.deletingLastPathComponent()
            for transcript in RecordingLibraryScanner.transcripts(in: folder) {
                guard recording.isDirectory || (transcript.document?.recording == recording.sourceName && transcript.document?.sources[TranscriptSource.mixed.rawValue] == recording.url.lastPathComponent) else { continue }
                let key = transcript.url.deletingLastPathComponent().lastPathComponent
                if assignments[key] == nil { assignments[key] = transcript.document?.automaticParticipant ?? inferred }
            }
        }
        saved.automaticParticipants = assignments.isEmpty ? nil : assignments
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFiles.atomicWrite(encoder.encode(saved), to: url(for: recording.url, isDirectory: recording.isDirectory))
    }
}

public struct CallTrashPlan: Sendable {
    public let urls: [URL]
}

public enum CallFileOperations {
    public static func contains(_ parent: URL, _ item: URL) -> Bool {
        let a = parent.standardizedFileURL.path, b = item.standardizedFileURL.path
        return a == b || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }
    static func validateRecording(_ recording: LibraryRecording) throws {
        let values = try recording.url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              recording.isDirectory ? values.isDirectory == true : values.isRegularFile == true else {
            throw RecorderError.message("This recording moved or changed. Refresh the library and try again.")
        }
    }
    public static func transcriptDirectory(_ version: LibraryTranscript, for recording: LibraryRecording) throws -> URL {
        let parent = recording.isDirectory ? recording.url : recording.url.deletingLastPathComponent()
        let root = parent.appendingPathComponent("Transcripts")
        let directory = version.url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              version.url.lastPathComponent == "Transcript.json", !directory.lastPathComponent.hasPrefix(".") else {
            throw RecorderError.message("This transcript is not stored with the selected call.")
        }
        for folder in [root, directory] {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RecorderError.message("Manage linked transcript folders in Finder.")
            }
        }
        guard PrivateFiles.isRegular(version.url) else { throw RecorderError.message("This transcript moved or changed. Refresh the library.") }
        if !recording.isDirectory {
            let document = try Transcript.read(from: version.url)
            guard document.recording == recording.sourceName,
                  document.sources[TranscriptSource.mixed.rawValue] == recording.url.lastPathComponent else {
                throw RecorderError.message("This transcript belongs to another recording.")
            }
        }
        return directory
    }
    public static func trashPlan(for recording: LibraryRecording) throws -> CallTrashPlan {
        try validateRecording(recording)
        if recording.isDirectory {
            let children = try FileManager.default.contentsOfDirectory(at: recording.url, includingPropertiesForKeys: nil)
            let allowed = Set(RecordingTrack.allCases.map(\.filename) + ["Transcripts", "CallDetails.json", ".DS_Store"])
            guard children.allSatisfy({ allowed.contains($0.lastPathComponent) }) else {
                throw RecorderError.message("This folder also contains other files. Use Show in Finder to review and move it to Trash.")
            }
            return .init(urls: [recording.url])
        }
        var urls = [recording.url]
        let details = CallDetailsStore.url(for: recording.url, isDirectory: false)
        if FileManager.default.fileExists(atPath: details.path) { urls.append(details) }
        // Re-read shared runs: a scan held by the UI can predate a completed transcription.
        let versions = RecordingLibraryScanner.transcripts(in: recording.url.deletingLastPathComponent()).filter {
            $0.document?.recording == recording.sourceName && $0.document?.sources[TranscriptSource.mixed.rawValue] == recording.url.lastPathComponent
        }
        for version in versions { urls.append(contentsOf: try trashPlan(for: version, recording: recording).urls) }
        return .init(urls: urls)
    }
    public static func trashPlan(for version: LibraryTranscript, recording: LibraryRecording) throws -> CallTrashPlan {
        try validateRecording(recording)
        let directory = try transcriptDirectory(version, for: recording)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(children).isSubset(of: ["Transcript.json", "Transcript.txt", ".DS_Store"]) else {
            throw RecorderError.message("This transcript folder contains other files. Review it in Finder before deleting it.")
        }
        return .init(urls: [directory])
    }
    /// Trash is recoverable. If a multi-file legacy move fails, attempt to put
    /// already-moved items back without replacing anything at their old paths.
    public static func moveToTrash(_ plan: CallTrashPlan, trash: ((URL) throws -> URL)? = nil) throws {
        let move = trash ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw RecorderError.message("macOS did not return the item's location in Trash.") }
            return result as URL
        }
        var moved: [(original: URL, trashed: URL)] = []
        do {
            for url in plan.urls { moved.append((url, try move(url))) }
        } catch {
            var unrestored: [String] = []
            for item in moved.reversed() {
                do { try FileManager.default.moveItem(at: item.trashed, to: item.original) }
                catch { unrestored.append(item.original.lastPathComponent) }
            }
            if !unrestored.isEmpty {
                throw RecorderError.message("The move could not finish. These items remain in Trash: \(unrestored.joined(separator: ", ")). Other items were restored. \(error.localizedDescription)")
            }
            throw error
        }
    }
    public static func saveTranscriptEdits(_ text: [String], version: LibraryTranscript, recording: LibraryRecording, participants: [String?]? = nil) throws -> URL {
        try validateRecording(recording)
        _ = try transcriptDirectory(version, for: recording)
        guard let original = version.document else { throw RecorderError.message("This transcript cannot be edited because it could not be read.") }
        let current = try Transcript.read(from: version.url)
        guard current.segments == original.segments, current.createdAt == original.createdAt, current.automaticParticipant == original.automaticParticipant else {
            throw RecorderError.message("This transcript changed while you were editing it. Reopen the editor to review the latest version.")
        }
        let details = try CallDetailsStore.load(for: recording.url, isDirectory: recording.isDirectory)
        let key = version.url.deletingLastPathComponent().lastPathComponent
        let automatic = original.automaticParticipant ?? details.automaticParticipants?[key] ?? (details.participants.count == 1 ? details.participants.first : nil)
        let edited = try original.editingParagraphs(text, parentVersion: key, participants: participants, automaticParticipant: automatic)
        return try edited.save(in: recording.isDirectory ? recording.url : recording.url.deletingLastPathComponent())
    }
}
