import Foundation

extension Transcript {
    var savedSpeakerNames: [String: String] {
        if let reviewedGroupNames { return reviewedGroupNames }
        // Older versions recorded bulk assignments only on the affected segments.
        var names: [String: Set<String>] = [:]
        for segment in segments where segment.source == .system && segment.groupAssignment == true {
            if let group = segment.speakerGroup, let name = segment.participant, !name.isEmpty {
                names[group, default: []].insert(name)
            }
        }
        return names.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}

extension CallDetails {
    public func savedSpeakerNames(for version: LibraryTranscript) -> [String: String] {
        guard let transcript = version.document else { return [:] }
        return transcript.savedSpeakerNames.compactMapValues {
            guard let name = participantName($0, for: version), !name.isEmpty else { return nil }
            return name
        }
    }

    /// Match against current attendance so renames follow the person and a
    /// new attendee with a recycled name never inherits the old suggestion.
    public func pendingSpeakerNames(_ suggestions: [String: SpeakerSuggestion], for version: LibraryTranscript) -> [String: String] {
        guard automaticParticipant(for: version) == nil else { return [:] }
        let reviewed = savedSpeakerNames(for: version)
        let attendees = callAttendees
        return suggestions.filter { reviewed[$0.key] == nil }.compactMapValues { $0.resolving(in: attendees)?.name }
    }
}

public struct SpeakerReview: Sendable {
    public let analysis: SpeakerAnalysis
    public let names: [String: String]

    public init(analysis: SpeakerAnalysis, names: [String: String]) {
        self.analysis = analysis
        self.names = names
    }

    func applying(to version: LibraryTranscript, details: CallDetails) throws -> Transcript {
        guard let transcript = version.document, analysis.model == SpeakerAnalysis.modelID,
              names.values.allSatisfy(details.participants.contains) else {
            throw RecorderError.message("The participants or speaker model changed. Reopen speaker review.")
        }
        let segments = groupedSegments(transcript.segments) { details.participantName($0, for: version) }
        let reviewed = details.savedSpeakerNames(for: version).merging(names) { _, chosen in chosen }
        return Transcript(original: transcript, segments: segments, parentVersion: version.runName,
                          automaticParticipant: details.automaticParticipant(for: version), reviewedGroupNames: reviewed)
    }

    /// The reader already has diarized segments. A single group edit should
    /// keep their boundaries and preserve any explicit per-passage override.
    static func assigning(group: String, to attendeeID: String, version: LibraryTranscript, details: CallDetails) throws -> Transcript {
        guard let transcript = version.document,
              transcript.segments.contains(where: { $0.source == .system && $0.speakerGroup == group }),
              let person = details.callAttendees.first(where: { $0.id == attendeeID && $0.active }) else {
            throw RecorderError.message("The speaker or attendance changed. Reopen the transcript and try again.")
        }
        let segments = transcript.segments.map { segment in
            guard segment.source == .system else { return segment }
            var name = details.participantName(segment.participant, for: version)
            var bulk = segment.groupAssignment
            if segment.speakerGroup == group, name == nil || bulk == true {
                name = person.name
                bulk = true
            }
            return TranscriptSegment(source: segment.source, start: segment.start, end: segment.end, text: segment.text,
                                     timing: segment.timing, participant: name, speakerGroup: segment.speakerGroup,
                                     words: segment.words, groupAssignment: bulk)
        }
        var reviewed = details.savedSpeakerNames(for: version)
        reviewed[group] = person.name
        return Transcript(original: transcript, segments: segments, parentVersion: version.runName,
                          automaticParticipant: details.automaticParticipant(for: version), reviewedGroupNames: reviewed)
    }

    func groupedSegments(_ input: [TranscriptSegment], participantName: (String?) -> String? = { $0 }) -> [TranscriptSegment] {
        let timeline = SpeakerTimeline(analysis.intervals)
        return input.flatMap { segment -> [TranscriptSegment] in
            guard segment.source == .system else { return [segment] }
            let existing = participantName(segment.participant)
            func assignment(_ group: String?) -> (name: String?, bulk: Bool?) {
                if segment.groupAssignment != true, let existing { return (existing, nil) }
                if let group, let name = names[group] { return (name, true) }
                return (existing, segment.groupAssignment)
            }
            func labeled(_ text: String, _ start: Double, _ end: Double, _ words: [TranscriptWord]?) -> TranscriptSegment {
                let group = timeline.speaker(from: start, to: end)
                let assigned = assignment(group)
                return .init(source: .system, start: start, end: end, text: text, timing: segment.timing,
                             participant: assigned.name, speakerGroup: group, words: words, groupAssignment: assigned.bulk)
            }
            // A legacy or edited phrase may span two voices. Only split at actual word times.
            guard let words = segment.words, !words.isEmpty,
                  words.map(\.text).joined(separator: " ") == segment.text,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= segment.start && $0.end <= segment.end && $0.start <= $0.end }) else {
                return [labeled(segment.text, segment.start, segment.end, segment.words)]
            }
            var runs: [[TranscriptWord]] = []
            var previous: String?
            for word in words {
                let group = timeline.speaker(from: word.start, to: word.end)
                if !runs.isEmpty, previous == group { runs[runs.count - 1].append(word) }
                else { runs.append([word]) }
                previous = group
            }
            return runs.map { run in
                let group = timeline.speaker(from: run[0].start, to: run[0].end)
                let assigned = assignment(group)
                return .init(source: .system, start: run[0].start, end: run.map(\.end).max()!, text: run.map(\.text).joined(separator: " "),
                             timing: segment.timing, participant: assigned.name, speakerGroup: group, words: run, groupAssignment: assigned.bulk)
            }
        }.enumerated().sorted { a, b in a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start }.map(\.element)
    }
}
