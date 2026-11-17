import Foundation

/// The current transcript contributes one entry per named remote passage. Saved training examples have their own lifetime.
public struct PersonVoiceLibrary {
    public struct Owner: Identifiable {
        public let id: String
        public let name: String
        public let attendee: CallAttendee?
    }

    public struct Item: Identifiable {
        public enum Source {
            case sample(VoiceReference)
            case passage(LibraryTranscript, TranscriptParagraph)
        }
        public let id: String
        public let owner: String
        public let recording: LibraryRecording?
        public let source: Source
        public let start: Double
        public let end: Double
        public var audio: URL? { recording?.tracks.first { $0.source == .system }?.url }
    }
    public let owners: [Owner]
    public let items: [Item]

    public init(recordings: [LibraryRecording] = [], profiles: VoiceProfiles = .init(), directory: PeopleDirectory = .init()) {
        var owners: [String: Owner] = [:]
        var calls: [String: LibraryRecording] = [:]
        var entries: [Item] = []
        for recording in recordings {
            if let id = try? VoiceProfiles.callID(for: recording) { calls[id] = recording }
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
                                     source: .passage(version, paragraph), start: paragraph.start, end: paragraph.end))
            }
        }
        let profileNames = profiles.names(in: directory)
        for sample in profiles.references {
            let key = VoiceProfiles.resolvedKey(sample.person, in: directory)
            if owners[key] == nil { owners[key] = .init(id: key, name: profileNames[key] ?? sample.displayName, attendee: nil) }
            entries.append(.init(id: "sample:" + sample.id, owner: key, recording: calls[sample.call],
                                 source: .sample(sample), start: sample.start, end: sample.end))
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
