import Darwin
import Foundation

/// A voice match recorded separately from human-reviewed assignments. The ID
/// follows attendance edits; the name is the label at transcription time.
public struct SpeakerSuggestion: Codable, Equatable, Sendable {
    public let attendeeID: String
    public let name: String

    func resolving(in attendees: [CallAttendee]) -> Self? {
        guard let person = attendees.first(where: { $0.id == attendeeID && $0.active }) else { return nil }
        return Self(attendeeID: person.id, name: person.name)
    }
}

public extension LibraryTranscript {
    /// Reuse the cached analysis for legacy transcripts and to reflect new or
    /// forgotten examples. Reading never starts diarization or writes a version.
    func currentSpeakerSuggestions(for recording: LibraryRecording, directory: PeopleDirectory, details: CallDetails? = nil,
                                   store: SpeakerAnalysisStore = .bundled) -> [String: SpeakerSuggestion] {
        let details = details ?? recording.details
        let attendees = details.callAttendees
        guard recording.detailsError == nil, details.automaticParticipant(for: self) == nil,
              attendees.contains(where: \.active),
              document?.segments.contains(where: { $0.speakerGroup != nil && $0.participant == nil }) == true,
              let profiles = try? VoiceProfiles.load(), !profiles.references.isEmpty,
              let call = try? VoiceProfiles.callID(for: recording) else { return [:] }
        if let audio = recording.tracks.first(where: { $0.source == .system }),
           let analysis = store.cachedAnalysis(for: audio.url) {
            return profiles.suggestions(for: analysis, among: attendees, excludingCall: call, in: directory)
        }
        // A saved transcript can outlive the system's disposable analysis cache.
        return (document?.speakerSuggestions ?? [:]).filter { _, match in
            guard let person = attendees.first(where: { $0.id == match.attendeeID && $0.active }) else { return false }
            return profiles.previousExamples(for: person, excludingCall: call, in: directory).clips > 0
        }
    }
}

public struct VoiceReference: Codable, Identifiable, Sendable {
    public let person: String
    public let displayName: String
    public let call: String
    public let start: Double
    public let end: Double
    public var id: String { "\(call):\(start.bitPattern):\(end.bitPattern)" }
    let vector: [Float]

    fileprivate func matches(_ clip: VoiceClip, call: String) -> Bool {
        self.call == call && abs(start - clip.interval.start) < 0.05 && abs(end - clip.interval.end) < 0.05
    }
}

public struct VoiceProfiles: Codable, Sendable {
    private var model = SpeakerAnalysis.modelID
    public private(set) var references: [VoiceReference] = []
    public init() {}

    public static func callID(for recording: LibraryRecording) throws -> String { try AgentJSON.identity(recording.url) }

    public static let changed = Notification.Name("AfterwordVoiceProfilesChanged")

    public static func key(for person: CallAttendee, in directory: PeopleDirectory = .init()) -> String {
        if let identity = directory.identity(for: person), identity.kind == .person { return "person:" + identity.id }
        if let email = person.email, !email.isEmpty { return "email:" + KnownIdentity.email(email) }
        return resolvedKey("name:" + KnownIdentity.email(person.name), in: directory)
    }

    /// Resolve earlier email-keyed samples through the person's aliases.
    public static func resolvedKey(_ key: String, in directory: PeopleDirectory) -> String {
        guard key.hasPrefix("email:") || key.hasPrefix("name:") else { return key }
        let value = String(key.dropFirst(key.hasPrefix("email:") ? 6 : 5))
        if let identity = directory.identity(email: value), identity.kind == .person { return "person:" + identity.id }
        if value.contains("@"), !value.contains(where: \.isWhitespace) { return "email:" + KnownIdentity.email(value) }
        return key
    }

    public func names(in directory: PeopleDirectory) -> [String: String] {
        var names: [String: String] = [:]
        for sample in references {
            let key = Self.resolvedKey(sample.person, in: directory)
            names[key] = sample.displayName
        }
        for person in directory.people where names["person:" + person.id] != nil { names["person:" + person.id] = person.name }
        return names
    }
    public var people: [String: String] { names(in: .init()) }

    public func reference(for clip: VoiceClip, call: String) -> VoiceReference? {
        references.first { $0.matches(clip, call: call) }
    }

    public func count(for person: CallAttendee, in directory: PeopleDirectory = .init()) -> Int {
        let key = Self.key(for: person, in: directory)
        return references.filter { Self.resolvedKey($0.person, in: directory) == key }.count
    }

    public func previousExamples(for person: CallAttendee, excludingCall call: String, in directory: PeopleDirectory = .init()) -> (clips: Int, calls: Int) {
        let key = Self.key(for: person, in: directory)
        let matching = references.filter { Self.resolvedKey($0.person, in: directory) == key && $0.call != call }
        return (matching.count, Set(matching.map(\.call)).count)
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256 else { return nil }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }

    public mutating func remember(_ clip: VoiceClip, as person: CallAttendee, call: String, directory: PeopleDirectory = .init()) throws {
        guard person.active, let vector = Self.normalized(clip.vector), clip.interval.start.isFinite,
              clip.interval.end.isFinite, clip.interval.end - clip.interval.start >= 2.5 else {
            throw RecorderError.message("Choose a clean voice clip and an active participant.")
        }
        let key = Self.key(for: person, in: directory)
        // Re-confirming or correcting the same clip replaces its old identity.
        references.removeAll { $0.matches(clip, call: call) }
        let displayName = directory.identity(for: person)?.name ?? person.name
        references.append(.init(person: key, displayName: displayName, call: call, start: clip.interval.start, end: clip.interval.end, vector: vector))
        if references.filter({ Self.resolvedKey($0.person, in: directory) == key && $0.call == call }).count > 6,
           let oldest = references.firstIndex(where: { Self.resolvedKey($0.person, in: directory) == key && $0.call == call }) { references.remove(at: oldest) }
        if references.filter({ Self.resolvedKey($0.person, in: directory) == key }).count > 48,
           let oldest = references.firstIndex(where: { Self.resolvedKey($0.person, in: directory) == key }) { references.remove(at: oldest) }
    }

    public mutating func change(_ sample: VoiceReference, to person: CallAttendee?, in directory: PeopleDirectory) throws {
        guard let index = references.firstIndex(where: { $0.id == sample.id && $0.person == sample.person }) else {
            throw RecorderError.message("This clip has changed. Review the current list and try again.")
        }
        if let person {
            guard person.active else { throw RecorderError.message("Choose a person for this clip.") }
            let original = references[index]
            let key = Self.key(for: person, in: directory)
            let others = references.filter { $0.id != original.id && Self.resolvedKey($0.person, in: directory) == key }
            guard others.count < 48, others.filter({ $0.call == original.call }).count < 6 else {
                throw RecorderError.message("That person already has the maximum number of samples. Forget one of their samples from this call or profile first.")
            }
            references[index] = .init(person: key, displayName: directory.identity(for: person)?.name ?? person.name,
                call: original.call, start: original.start, end: original.end, vector: original.vector)
        } else { references.remove(at: index) }
    }

    public mutating func forget(_ key: String, in directory: PeopleDirectory = .init()) { references.removeAll { Self.resolvedKey($0.person, in: directory) == key } }

    public func suggestion(for clips: [VoiceClip], among attendees: [CallAttendee], excludingCall call: String, in directory: PeopleDirectory = .init()) -> CallAttendee? {
        let available = attendees.filter(\.active)
        let byPerson = Dictionary(grouping: references.filter { $0.call != call }, by: { Self.resolvedKey($0.person, in: directory) })
        // Give each meeting equal weight even if one has many confirmed clips.
        let candidates = available.compactMap { person -> (CallAttendee, [[Float]])? in
            guard let refs = byPerson[Self.key(for: person, in: directory)] else { return nil }
            let calls = Dictionary(grouping: refs, by: \.call).values.compactMap { samples -> [Float]? in
                var sum = [Float](repeating: 0, count: 256)
                for sample in samples where sample.vector.count == sum.count {
                    for index in sum.indices { sum[index] += sample.vector[index] }
                }
                return Self.normalized(sum)
            }
            return calls.isEmpty ? nil : (person, calls)
        }
        guard clips.count >= 2, !candidates.isEmpty else { return nil }
        var votes: [String: Int] = [:]
        var mismatches: Set<String> = []
        for clip in clips {
            guard let vector = Self.normalized(clip.vector) else { continue }
            let scores = candidates.map { person, calls in
                let similarities = calls.map { ref in zip(ref, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
                return (person.id, similarities.reduce(0, +) / Float(similarities.count))
            }.sorted { $0.1 > $1.1 }
            // A clear mismatch can reveal an unregistered second voice in a merged cluster.
            for (id, similarity) in scores where similarity < 0.35 { mismatches.insert(id) }
            let best = scores[0]
            // Conservative cosine and runner-up thresholds. Scores are not probabilities.
            if best.1 >= 0.58, scores.count == 1 || best.1 - scores[1].1 >= 0.10 { votes[best.0, default: 0] += 1 }
        }
        // Conflicting strong votes suggest a merged cluster. Abstain on the whole group.
        guard votes.count == 1, let winner = votes.first, !mismatches.contains(winner.key), winner.value >= max(2, (2 * clips.count + 2) / 3) else { return nil }
        return available.first { $0.id == winner.key }
    }

    public func suggestions(for analysis: SpeakerAnalysis, among attendees: [CallAttendee], excludingCall call: String,
                            in directory: PeopleDirectory) -> [String: SpeakerSuggestion] {
        guard analysis.model == SpeakerAnalysis.modelID, !references.isEmpty else { return [:] }
        return Dictionary(grouping: analysis.clips, by: { $0.interval.speaker }).compactMapValues { clips in
            suggestion(for: clips, among: attendees, excludingCall: call, in: directory).map {
                SpeakerSuggestion(attendeeID: $0.id, name: $0.name)
            }
        }
    }

    public static let directory = ModelStore.defaultRoot.deletingLastPathComponent().appendingPathComponent("Voices", isDirectory: true)

    public static func load(in directory: URL = directory) throws -> VoiceProfiles {
        let url = directory.appendingPathComponent(SpeakerAnalysis.modelID + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard PrivateFiles.isRegular(url) else { throw RecorderError.message("The saved voice profiles could not be read.") }
        let store = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard store.model == SpeakerAnalysis.modelID else { throw RecorderError.message("The saved voice profiles use another model.") }
        return store
    }

    @discardableResult public static func update(in directory: URL = directory, _ edit: (inout VoiceProfiles) throws -> Void) throws -> VoiceProfiles {
        try PrivateFiles.directory(directory)
        let lock = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        var store = try load(in: directory)
        try edit(&store)
        try PrivateFiles.atomicWrite(JSONEncoder().encode(store), to: directory.appendingPathComponent(SpeakerAnalysis.modelID + ".json"))
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: directory) }
        return store
    }
}
