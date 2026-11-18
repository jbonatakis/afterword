import Foundation

public struct CallDetails: Codable, Equatable, Sendable {
    public var version = 4
    public var title: String?
    public var participants: [String]
    public var tags: [String]
    public var description: String
    /// Defaults retained when adding people, updated when renaming/removing them.
    /// Keyed by transcript run directory; an empty value clears the embedded default.
    public var automaticParticipants: [String: String]?
    /// Per-version corrections to names stored in immutable transcript files.
    /// An empty value removes an assignment, including if that name is later reused.
    public var participantOverrides: [String: [String: String]]?
    public var attendees: [CallAttendee]?
    public var allowSingleParticipantInference: Bool?
    public var meeting: MeetingReference?
    public init(title: String? = nil, participants: [String] = [], tags: [String] = [], description: String = "", automaticParticipants: [String: String]? = nil,
                participantOverrides: [String: [String: String]]? = nil, attendees: [CallAttendee]? = nil,
                allowSingleParticipantInference: Bool? = nil, meeting: MeetingReference? = nil) {
        self.title = title; self.participants = participants; self.tags = tags; self.description = description
        self.automaticParticipants = automaticParticipants
        self.participantOverrides = participantOverrides
        self.attendees = attendees; self.allowSingleParticipantInference = allowSingleParticipantInference; self.meeting = meeting
    }
    public var normalized: CallDetails {
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
        }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: title?.isEmpty == false ? title : nil, participants: unique(participants), tags: unique(tags),
                     description: description.trimmingCharacters(in: .whitespacesAndNewlines), automaticParticipants: automaticParticipants, participantOverrides: participantOverrides,
                     attendees: attendees, allowSingleParticipantInference: allowSingleParticipantInference, meeting: meeting)
    }
    public var callAttendees: [CallAttendee] { attendees ?? participants.map { .init(id: "legacy:" + $0, name: $0) } }
    public var hasActiveGroups: Bool { callAttendees.contains { $0.kind == .group && $0.attendance != .absent } }
    public var inferredParticipant: String? { allowSingleParticipantInference != false && !hasActiveGroups && participants.count == 1 ? participants.first : nil }
    public func updatingAttendance(_ attendees: [CallAttendee], confirmOnly personID: String? = nil) throws -> Self {
        var result = self
        result.attendees = attendees; result.participants = attendees.filter(\.active).map(\.name)
        guard Set(attendees.map(\.id)).count == attendees.count,
              Set(result.participants).count == result.participants.count else { throw RecorderError.message("Use distinct names for each participant.") }
        if Set(attendees.filter { $0.attendance != .absent }.map(\.id)) != Set(callAttendees.filter { $0.attendance != .absent }.map(\.id)) {
            result.allowSingleParticipantInference = false
        }
        if let personID {
            guard !result.hasActiveGroups, attendees.filter(\.active).count == 1,
                  attendees.first(where: { $0.id == personID })?.active == true else { throw RecorderError.message("Confirm a single attendee and exclude any groups first.") }
            result.allowSingleParticipantInference = true
        }
        return result
    }
    public func automaticParticipant(for transcript: LibraryTranscript) -> String? {
        if let inferredParticipant { return inferredParticipant }
        let name = automaticParticipants?[transcript.runName] ?? transcript.document?.automaticParticipant
        return name.flatMap { participants.contains($0) ? $0 : nil }
    }
    public func participantName(_ name: String?, for transcript: LibraryTranscript) -> String? {
        guard let name else { return nil }
        if name.isEmpty { return "" }
        let current = participantOverrides?[transcript.runName]?[name] ?? name
        return participants.contains(current) ? current : ""
    }
    public func participantNames(for transcript: LibraryTranscript) -> [String: String] {
        guard let document = transcript.document else { return [:] }
        var names = Set(document.segments.compactMap(\.participant))
        if let reviewed = document.reviewedGroupNames { names.formUnion(reviewed.values) }
        return Dictionary(uniqueKeysWithValues: names.map { ($0, participantName($0, for: transcript) ?? "") })
    }
}

public enum CallDetailsStore {
    static func singleParticipant(for input: TranscriptionInput) -> String? {
        guard let track = input.tracks.first else { return nil }
        let audio = URL(fileURLWithPath: track.path)
        let directory = RecordingTrack.allCases.contains { $0.filename == audio.lastPathComponent }
        guard let details = try? load(for: directory ? input.outputDirectory : audio, isDirectory: directory) else { return nil }
        return details.inferredParticipant
    }
    public static func url(for recording: URL, isDirectory: Bool) -> URL {
        isDirectory ? recording.appendingPathComponent("CallDetails.json") : recording.appendingPathExtension("call.json")
    }
    public static func load(for recording: URL, isDirectory: Bool) throws -> CallDetails {
        let file = url(for: recording, isDirectory: isDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        guard PrivateFiles.isRegular(file) else { throw RecorderError.message("Call details must be stored in a regular file.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let details = try decoder.decode(CallDetails.self, from: Data(contentsOf: file))
        guard (1...4).contains(details.version) else { throw RecorderError.message("These call details use a newer format. They have not been changed.") }
        return details.normalized
    }
    static func writeInitial(_ details: CallDetails, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try PrivateFiles.atomicWrite(encoder.encode(details.normalized), to: url)
    }
    @discardableResult public static func save(_ details: CallDetails, for recording: LibraryRecording, participantRenames: [String: String] = [:]) throws -> CallDetails {
        try CallFileOperations.validateRecording(recording)
        // Do not silently replace an unreadable or newer details file.
        let previous = try load(for: recording.url, isDirectory: recording.isDirectory)
        var saved = details.normalized
        if saved.meeting == nil { saved.meeting = previous.meeting }
        if saved.allowSingleParticipantInference == nil { saved.allowSingleParticipantInference = previous.allowSingleParticipantInference }
        // The existing details editor edits names. Keep identity/attendance
        // links when those names change, and retain excluded people for Restore.
        if saved.attendees == nil, previous.attendees != nil {
            var people = previous.callAttendees
            for index in people.indices where people[index].kind == .person {
                if let name = participantRenames[people[index].name] { people[index].name = name; people[index].hasLocalName = true }
                if !saved.participants.contains(people[index].name) { people[index].attendance = .absent }
            }
            for name in saved.participants where !people.contains(where: { $0.name == name && $0.active }) {
                if let index = people.firstIndex(where: { $0.name == name && $0.kind == .person }) { people[index].attendance = .expected }
                else { people.append(.init(name: name)) }
            }
            saved.attendees = people
            if !Set(previous.participants.map { participantRenames[$0] ?? $0 }).isSubset(of: saved.participants) { saved.allowSingleParticipantInference = false }
        }
        guard participantRenames.allSatisfy({ previous.participants.contains($0.key) && saved.participants.contains($0.value) }) else {
            throw RecorderError.message("The participant list changed. Reopen call details and try again.")
        }
        func updatedName(_ name: String) -> String {
            guard !name.isEmpty else { return "" }
            let updated = participantRenames[name] ?? name
            return saved.participants.contains(updated) ? updated : ""
        }
        var assignments = previous.automaticParticipants ?? [:]
        var overrides = previous.participantOverrides ?? [:]
        // Preserve the previous one-person default when adding names, but let
        // renames/removals correct it. Never rewrite the original transcripts.
        let folder = recording.isDirectory ? recording.url : recording.url.deletingLastPathComponent()
        for transcript in RecordingLibraryScanner.transcripts(in: folder) {
            guard recording.isDirectory || (transcript.document?.recording == recording.sourceName && transcript.document?.sources[TranscriptSource.mixed.rawValue] == recording.url.lastPathComponent) else { continue }
            let key = transcript.runName
            assignments[key] = saved.inferredParticipant ?? updatedName(previous.automaticParticipant(for: transcript) ?? "")
            let names = previous.participantNames(for: transcript).mapValues(updatedName)
            if !names.isEmpty { overrides[key] = names }
        }
        saved.automaticParticipants = assignments.isEmpty ? nil : assignments
        saved.participantOverrides = overrides.isEmpty ? nil : overrides
        try writeInitial(saved, to: url(for: recording.url, isDirectory: recording.isDirectory))
        return saved
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
            let allowed = Set(RecordingTrack.allCases.map(\.filename) + ["Transcripts", "CallDetails.json", "Summary.json", ".Summary.json.lock", ".DS_Store"])
            guard children.allSatisfy({ allowed.contains($0.lastPathComponent) }) else {
                throw RecorderError.message("This folder also contains other files. Use Show in Finder to review and move it to Trash.")
            }
            return .init(urls: [recording.url])
        }
        var urls = [recording.url]
        let details = CallDetailsStore.url(for: recording.url, isDirectory: false)
        if FileManager.default.fileExists(atPath: details.path) { urls.append(details) }
        for summaryFile in [CallSummaryStore.url(for: recording.url, isDirectory: false), CallSummaryStore.lockURL(for: recording.url, isDirectory: false)] {
            if FileManager.default.fileExists(atPath: summaryFile.path) { urls.append(summaryFile) }
        }
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
    public static func saveSpeakerReview(_ review: SpeakerReview, version: LibraryTranscript, recording: LibraryRecording) throws -> URL {
        let (_, details) = try transcriptForEditing(version, recording)
        let updated = try review.applying(to: version, details: details)
        return try saveSpeakerChanges(updated, version: version, recording: recording, details: details)
    }

    public static func assignSpeakerGroup(_ group: String, to attendeeID: String, version: LibraryTranscript, recording: LibraryRecording) throws -> URL {
        let (_, details) = try transcriptForEditing(version, recording)
        let updated = try SpeakerReview.assigning(group: group, to: attendeeID, version: version, details: details)
        return try saveSpeakerChanges(updated, version: version, recording: recording, details: details)
    }

    private static func saveSpeakerChanges(_ updated: Transcript, version: LibraryTranscript, recording: LibraryRecording, details: CallDetails) throws -> URL {
        if updated.segments == version.document?.segments, updated.automaticParticipant == version.document?.automaticParticipant,
           updated.savedSpeakerNames == details.savedSpeakerNames(for: version) { return version.url }
        return try saveEditedVersion(updated, source: version, recording: recording, details: details)
    }

    private static func saveEditedVersion(_ updated: Transcript, source: LibraryTranscript, recording: LibraryRecording, details: CallDetails) throws -> URL {
        var edited = updated
        let directory = (try? PeopleDirectory.load(from: PeopleDirectory.fileURL)) ?? .init()
        let suggestions = source.currentSpeakerSuggestions(for: recording, directory: directory, details: details)
        edited.updateSuggestions(suggestions, attendees: details.callAttendees)
        return try edited.save(in: recording.isDirectory ? recording.url : recording.url.deletingLastPathComponent())
    }

    private static func transcriptForEditing(_ version: LibraryTranscript, _ recording: LibraryRecording) throws -> (Transcript, CallDetails) {
        try validateRecording(recording)
        _ = try transcriptDirectory(version, for: recording)
        guard let original = version.document else { throw RecorderError.message("This transcript cannot be edited because it could not be read.") }
        let current = try Transcript.read(from: version.url)
        guard current.segments == original.segments, current.createdAt == original.createdAt, current.automaticParticipant == original.automaticParticipant,
              current.reviewedGroupNames == original.reviewedGroupNames, current.speakerSuggestions == original.speakerSuggestions else {
            throw RecorderError.message("This transcript changed while you were editing it. Reopen the editor to review the latest version.")
        }
        let details = try CallDetailsStore.load(for: recording.url, isDirectory: recording.isDirectory)
        return (original, details)
    }

    public static func saveTranscriptEdits(_ text: [String], version: LibraryTranscript, recording: LibraryRecording, participants: [String?]? = nil) throws -> URL {
        let (original, details) = try transcriptForEditing(version, recording)
        let names = participants ?? original.paragraphs.map { details.participantName($0.participant, for: version) }
        guard names.allSatisfy({ $0 == nil || $0 == "" || details.participants.contains($0!) }) else {
            throw RecorderError.message("A participant changed while you were editing. Reopen the editor to review the latest names.")
        }
        let edited = try original.editingParagraphs(text, parentVersion: version.runName, participants: names,
                                                  automaticParticipant: details.automaticParticipant(for: version) ?? "", reviewedGroupNames: details.savedSpeakerNames(for: version))
        return try saveEditedVersion(edited, source: version, recording: recording, details: details)
    }
}
