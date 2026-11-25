import Foundation

/// The current transcript contributes one entry per named remote passage. Saved training examples have their own lifetime.
public struct PersonVoiceLibrary {
    public struct Owner: Identifiable {
        public let id: String
        public let name: String
        public let attendee: CallAttendee?
    }

    public struct Item: Identifiable, Sendable {
        public enum Source: Sendable {
            case sample(VoiceReference)
            case passage(LibraryTranscript, TranscriptParagraph)
        }
        public let id: String
        public let owner: String
        public let recording: LibraryRecording?
        public let source: Source
        public let start: Double
        public let end: Double
        public let rememberedSample: VoiceReference?
        fileprivate let callID: String?
        public var audio: URL? { recording?.tracks.first { $0.source == .system }?.url }

        public func rememberPassage(in directory: PeopleDirectory) async throws {
            let operation = LocalWorkerOperation()
            try await operation.perform {
                try rememberPassage(in: directory, store: .bundled, profilesDirectory: VoiceProfiles.directory, operation: operation)
            }
        }

        func rememberPassage(in directory: PeopleDirectory, store: SpeakerAnalysisStore, profilesDirectory: URL,
                             operation: LocalWorkerOperation) throws {
            guard case let .passage(version, paragraph) = source, let recording, let audio, let callID else {
                throw RecorderError.message("The system audio for this passage is unavailable.")
            }
            // Reassigning a remembered passage can reuse its original embedding.
            let clip = try rememberedSample == nil ? store.voiceClip(for: audio, from: start, to: end, operation: operation) : nil
            guard try VoiceProfiles.callID(for: recording) == callID,
                  let latest = RecordingLibraryScanner.transcripts(in: recording.url).first, latest.id == version.id,
                  latest.document?.paragraphs.first(where: { $0.id == paragraph.id })?.segments == paragraph.segments else {
                throw RecorderError.message("The transcript changed. Review the latest passages and try again.")
            }
            let details = try CallDetailsStore.load(for: recording.url, isDirectory: recording.isDirectory)
            let name = details.participantName(paragraph.participant, for: latest) ?? details.automaticParticipant(for: latest)
            let originalName = recording.details.participantName(paragraph.participant, for: version) ?? recording.automaticParticipant(for: version)
            guard let person = details.callAttendees.first(where: { $0.active && $0.name == name }),
                  recording.details.callAttendees.contains(where: { $0.id == person.id && $0.name == originalName }),
                  VoiceProfiles.key(for: person, in: directory) == owner else {
                throw RecorderError.message("The speaker changed. Review the passage before saving it.")
            }
            _ = try operation.publish {
                try VoiceProfiles.update(in: profilesDirectory) { profiles in
                    if let rememberedSample {
                        try profiles.change(rememberedSample, to: person, in: directory)
                    } else if let clip {
                        if let existing = profiles.reference(for: clip, call: callID) {
                            guard VoiceProfiles.resolvedKey(existing.person, in: directory) == owner else {
                                throw RecorderError.message("This sample was assigned to another person. Review the current list and try again.")
                            }
                            return
                        }
                        try profiles.remember(clip, as: person, call: callID, directory: directory)
                    }
                }
            }
        }
    }
    public let owners: [Owner]
    public let items: [Item]

    public init(recordings: [LibraryRecording] = [], profiles: VoiceProfiles = .init(), directory: PeopleDirectory = .init()) {
        var owners: [String: Owner] = [:]
        var calls: [String: LibraryRecording] = [:]
        var entries: [Item] = []
        let samplesByCall = Dictionary(grouping: profiles.references, by: \.call)
        for recording in recordings {
            let callID = try? VoiceProfiles.callID(for: recording)
            if let callID { calls[callID] = recording }
            let samples = callID.flatMap { samplesByCall[$0] } ?? []
            var keys: [String: String] = [:]
            for person in recording.details.callAttendees where person.active {
                let key = VoiceProfiles.key(for: person, in: directory)
                owners[key] = .init(id: key, name: recording.displayName(person.name), attendee: person)
                keys[person.name] = key
            }
            guard let version = recording.latestTranscript, let document = version.document else { continue }
            let automatic = recording.automaticParticipant(for: version)
            for paragraph in document.paragraphs where paragraph.source == .system {
                let name = recording.details.participantName(paragraph.participant, for: version) ?? automatic
                guard let name, let key = keys[name] else { continue }
                entries.append(.init(id: "passage:\(version.id):\(paragraph.id)", owner: key, recording: recording,
                                     source: .passage(version, paragraph), start: paragraph.start, end: paragraph.end,
                                     rememberedSample: samples.first { $0.matches(start: paragraph.start, end: paragraph.end) }, callID: callID))
            }
        }
        let profileNames = profiles.names(in: directory)
        for sample in profiles.references {
            let key = VoiceProfiles.resolvedKey(sample.person, in: directory)
            if owners[key] == nil { owners[key] = .init(id: key, name: profileNames[key] ?? sample.displayName, attendee: nil) }
            entries.append(.init(id: "sample:" + sample.id, owner: key, recording: calls[sample.call],
                                 source: .sample(sample), start: sample.start, end: sample.end, rememberedSample: sample, callID: sample.call))
        }
        for person in directory.people where person.kind == .person && !person.emails.contains(where: directory.selfEmails.contains) {
            let key = "person:" + person.id
            owners[key] = .init(id: key, name: person.name, attendee: .init(id: person.id, name: person.name, email: person.emails.first))
        }
        self.owners = owners.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        items = entries.sorted {
            let left = $0.recording?.date ?? .distantPast, right = $1.recording?.date ?? .distantPast
            if left != right { return left > right }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
}
