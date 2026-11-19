import Foundation
import CryptoKit

public enum IdentityKind: String, Codable, CaseIterable, Sendable { case person, group, resource }
public enum Attendance: String, Codable, Sendable { case expected, attended, absent }

public struct KnownIdentity: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var emails: [String]
    public var kind: IdentityKind
    public var memberIDs: [String]
    public init(id: String = UUID().uuidString, name: String, emails: [String], kind: IdentityKind = .person, memberIDs: [String] = []) {
        self.id = id; self.name = name; self.emails = emails; self.kind = kind; self.memberIDs = memberIDs
    }
    public static func email(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

public struct PeopleDirectory: Codable, Equatable, Sendable {
    public static let fileURL = SessionStore.defaultRoot.deletingLastPathComponent().appendingPathComponent("People.json")
    public var version = 1
    public var people: [KnownIdentity] = []
    public var selfEmails: [String] = []
    public init() {}
    public func identity(email: String) -> KnownIdentity? {
        let email = KnownIdentity.email(email)
        return people.first { $0.emails.map(KnownIdentity.email).contains(email) }
    }
    public func identity(for attendee: CallAttendee) -> KnownIdentity? {
        if attendee.directoryLink == .callOnly { return nil }
        if case .person(let id) = attendee.directoryLink { return people.first { $0.id == id } }
        if let match = people.first(where: { $0.id == attendee.id }) { return match }
        return identity(email: attendee.email ?? attendee.name)
    }

    /// Call-local labels remain the assignment tokens. Only unambiguous directory identities supply display names.
    public func labels(for attendees: [CallAttendee]) -> [String: String] {
        let people = attendees.filter { $0.kind == .person }
        let labels = people.map { attendee -> String in
            if let label = attendee.localDisplayName { return label }
            guard attendee.hasLocalName != true, let person = identity(for: attendee), person.kind == .person else { return attendee.name }
            return person.name
        }
        let duplicates = Dictionary(grouping: labels, by: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        var result: [String: String] = [:]
        var occurrences: [String: Int] = [:]
        for (attendee, label) in zip(people, labels) {
            let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            occurrences[key, default: 0] += 1
            let qualifier = attendee.email ?? identity(for: attendee)?.emails.first ?? String(occurrences[key, default: 1])
            let display = duplicates[key, default: []].count > 1 ? "\(label) (\(qualifier))" : label
            if display != attendee.name { result[attendee.name] = display }
        }
        return result
    }

    public mutating func remember(email: String, name: String?, kind: IdentityKind = .person) -> KnownIdentity {
        if let known = identity(email: email) { return known }
        let email = KnownIdentity.email(email)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = KnownIdentity(name: name?.isEmpty == false ? name! : email, emails: [email], kind: kind)
        people.append(identity); return identity
    }
    public mutating func update(_ identity: KnownIdentity) throws {
        var identity = identity
        identity.name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        identity.emails = Array(Set(identity.emails.map(KnownIdentity.email).filter { !$0.isEmpty })).sorted()
        guard !identity.name.isEmpty, identity.kind == .person || !identity.emails.isEmpty,
              identity.emails.allSatisfy({ $0.contains("@") && !$0.contains(where: \.isWhitespace) }) else {
            throw RecorderError.message("Enter a name and valid email addresses.")
        }
        guard !people.contains(where: { $0.id != identity.id && !Set($0.emails).isDisjoint(with: identity.emails) }) else {
            throw RecorderError.message("An email address already belongs to another saved identity.")
        }
        identity.memberIDs = identity.kind == .group ? Array(Set(identity.memberIDs)).filter { id in
            people.contains { $0.id == id && $0.id != identity.id && $0.kind == .person }
        }.sorted() : []
        if let index = people.firstIndex(where: { $0.id == identity.id }) { people[index] = identity }
        else { people.append(identity) }
    }
    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard PrivateFiles.isRegular(url) else { throw RecorderError.message("The people directory must be a regular file.") }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw RecorderError.message("The people directory uses a newer format.") }
        return result
    }
    public func save(to url: URL) throws {
        _ = try Self.load(from: url)
        try PrivateFiles.directory(url.deletingLastPathComponent())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFiles.atomicWrite(encoder.encode(self), to: url)
    }
}

public struct CallAttendee: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var email: String?
    public var kind: IdentityKind
    public var attendance: Attendance
    public enum DirectoryLink: Codable, Equatable, Sendable { case person(String), callOnly }
    public var directoryLink: DirectoryLink?
    public var localDisplayName: String?
    public var hasLocalName: Bool?
    public var groupIDs: [String]
    public init(id: String = UUID().uuidString, name: String, email: String? = nil, kind: IdentityKind = .person,
                attendance: Attendance = .expected, groupIDs: [String] = []) {
        self.id = id; self.name = name; self.email = email; self.kind = kind; self.attendance = attendance; self.groupIDs = groupIDs
    }
    public var active: Bool { attendance != .absent && kind == .person }
}

/// Edits are staged until the attendance sheet is saved. A row's original name
/// is the key used by existing transcripts, even after a directory link changes.
public struct AttendanceRoster: Sendable {
    public var attendees: [CallAttendee]
    public private(set) var newPeople: [KnownIdentity] = []
    public private(set) var renames: [String: String] = [:]
    public init(_ attendees: [CallAttendee]) { self.attendees = attendees }

    public func directory(includingPendingIn directory: PeopleDirectory) throws -> PeopleDirectory {
        var result = directory
        for person in newPeople where attendees.contains(where: { $0.directoryLink == .person(person.id) }) {
            try result.update(person)
        }
        return result
    }

    public static func choices(matching query: String, in directory: PeopleDirectory) -> [KnownIdentity] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.people.filter { person in
            person.kind == .person && Set(person.emails).isDisjoint(with: directory.selfEmails)
                && (query.isEmpty || ([person.name] + person.emails).contains { $0.localizedStandardContains(query) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public mutating func select(_ person: KnownIdentity, from directory: PeopleDirectory, linking rowID: String? = nil) throws {
        guard person.kind == .person, Set(person.emails).isDisjoint(with: directory.selfEmails) else {
            throw RecorderError.message("Choose an individual attendee other than yourself.")
        }
        let linked = attendees.firstIndex { $0.kind == .person && directory.identity(for: $0)?.id == person.id }
            ?? attendees.firstIndex { row in
                row.kind == .person && row.email.map { person.emails.contains(KnownIdentity.email($0)) } == true
            }
        let source = rowID.flatMap { id in attendees.firstIndex { $0.id == id && $0.kind == .person } }
        if rowID != nil && source == nil { throw RecorderError.message("This attendee is no longer on the call.") }
        if let index = linked ?? source {
            attendees[index].directoryLink = .person(person.id)
            attendees[index].email = person.emails.first
            attendees[index].hasLocalName = nil
            attendees[index].localDisplayName = nil
            attendees[index].attendance = .attended
            if let source, source != index {
                let removed = attendees[source], kept = attendees[index].name
                renames = renames.mapValues { $0 == removed.name ? kept : $0 }
                renames[removed.name] = kept
                attendees[index].groupIDs = Array(Set(attendees[index].groupIDs + removed.groupIDs)).sorted()
                attendees.remove(at: source)
            }
        } else {
            let id = attendees.contains { $0.id == person.id } ? UUID().uuidString : person.id
            var row = CallAttendee(id: id, name: availableName(person.name, email: person.emails.first),
                                   email: person.emails.first, attendance: .attended)
            row.directoryLink = .person(person.id)
            attendees.append(row)
        }
    }

    public mutating func add(name: String, email: String, remember: Bool, in directory: PeopleDirectory, linking rowID: String? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), email = KnownIdentity.email(email)
        guard !name.isEmpty else { throw RecorderError.message("Enter the attendee’s name.") }
        guard email.isEmpty || !directory.selfEmails.contains(email) else { throw RecorderError.message("That address belongs to you.") }
        let person = KnownIdentity(name: name, emails: email.isEmpty ? [] : [email])
        var checked = directory
        try checked.update(person)
        if remember {
            try select(person, from: checked, linking: rowID)
            newPeople.append(person)
        } else if let rowID {
            guard let index = attendees.firstIndex(where: { $0.id == rowID && $0.kind == .person }) else {
                throw RecorderError.message("This attendee is no longer on the call.")
            }
            if !email.isEmpty && attendees.contains(where: { $0.id != rowID && $0.email.map(KnownIdentity.email) == email }) {
                throw RecorderError.message("Another attendee on this call already uses that address.")
            }
            attendees[index].localDisplayName = name
            attendees[index].email = person.emails.first
            attendees[index].directoryLink = .callOnly
        } else if let index = attendees.firstIndex(where: { attendee in
            attendee.kind == .person && directory.identity(for: attendee) == nil
                && (email.isEmpty ? (attendee.localDisplayName ?? attendee.name).localizedCaseInsensitiveCompare(name) == .orderedSame
                    && attendee.email == nil : attendee.email.map(KnownIdentity.email) == email)
        }) {
            attendees[index].attendance = .attended
        } else {
            var row = CallAttendee(name: availableName(name, email: person.emails.first), email: person.emails.first, attendance: .attended)
            row.directoryLink = .callOnly
            attendees.append(row)
        }
    }

    private func availableName(_ name: String, email: String?) -> String {
        func taken(_ candidate: String) -> Bool {
            attendees.contains { $0.name.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if !taken(name) { return name }
        if let email, !taken("\(name) (\(email))") { return "\(name) (\(email))" }
        var number = 2
        while taken("\(name) (\(number))") { number += 1 }
        return "\(name) (\(number))"
    }
}

public struct MeetingGuest: Equatable, Sendable {
    public var email: String
    public var name: String?
    public var kind: IdentityKind
    public var isSelf: Bool
    public var declined: Bool
    public init(email: String, name: String? = nil, kind: IdentityKind = .person, isSelf: Bool = false, declined: Bool = false) {
        self.email = KnownIdentity.email(email); self.name = name; self.kind = kind; self.isSelf = isSelf; self.declined = declined
    }
}

public struct MeetingReference: Codable, Equatable, Sendable {
    public var occurrenceID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendar: String
    public var joinURL: URL
    public init(occurrenceID: String, title: String, start: Date, end: Date, calendar: String, joinURL: URL) {
        self.occurrenceID = occurrenceID; self.title = title; self.start = start; self.end = end; self.calendar = calendar; self.joinURL = joinURL
    }
}

public struct CalendarMeeting: Identifiable, Equatable, Sendable {
    public let reference: MeetingReference
    public let guests: [MeetingGuest]
    public let guestListAvailable: Bool
    public let isOwnInvite: Bool
    public var id: String { reference.occurrenceID }
    public var reminderKey: String { id + ":" + String(reference.start.timeIntervalSince1970) }
    public init(reference: MeetingReference, guests: [MeetingGuest], guestListAvailable: Bool = true, isOwnInvite: Bool = false) {
        self.reference = reference; self.guests = guests; self.guestListAvailable = guestListAvailable; self.isOwnInvite = isOwnInvite
    }
    public func callDetails(directory: inout PeopleDirectory) -> CallDetails {
        for guest in guests where guest.isSelf {
            if !directory.selfEmails.contains(guest.email) { directory.selfEmails.append(guest.email) }
        }
        var attendees: [CallAttendee] = [], seen = Set<String>()
        func append(_ identity: KnownIdentity, attendance: Attendance, groups: [String] = []) {
            guard !identity.emails.contains(where: { directory.selfEmails.contains($0) }), identity.kind != .resource else { return }
            if let index = attendees.firstIndex(where: { $0.id == identity.id }) {
                attendees[index].groupIDs = Array(Set(attendees[index].groupIDs + groups))
                return
            }
            guard seen.insert(identity.id).inserted else { return }
            attendees.append(.init(id: identity.id, name: identity.name, email: identity.emails.first, kind: identity.kind, attendance: attendance, groupIDs: groups))
        }
        // Explicit guests take precedence over roster suggestions (including declines).
        for guest in guests where !guest.isSelf && !directory.selfEmails.contains(guest.email) {
            let identity = directory.remember(email: guest.email, name: guest.name, kind: guest.kind)
            append(identity, attendance: guest.declined ? .absent : .expected)
        }
        let groups = attendees.filter { $0.kind == .group && $0.attendance != .absent }
        for group in groups {
            for id in directory.people.first(where: { $0.id == group.id })?.memberIDs ?? [] {
                if let member = directory.people.first(where: { $0.id == id && $0.kind == .person }) { append(member, attendance: .expected, groups: [group.id]) }
            }
        }
        // Names are presentation snapshots. Distinguish people with the same name.
        let duplicates = Dictionary(grouping: attendees.filter { $0.kind == .person }, by: { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        for index in attendees.indices where attendees[index].kind == .person {
            let key = attendees[index].name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if (duplicates[key]?.count ?? 0) > 1 { attendees[index].name += " (\(attendees[index].email ?? attendees[index].id))" }
        }
        return CallDetails(title: reference.title, participants: attendees.filter(\.active).map(\.name), attendees: attendees,
                           allowSingleParticipantInference: guestListAvailable && groups.isEmpty, meeting: reference)
    }
    public static func occurrenceID(externalID: String?, localID: String, occurrence: Date) -> String {
        let value = (externalID?.isEmpty == false ? externalID! : localID) + "|" + String(occurrence.timeIntervalSince1970)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func deduplicated(_ meetings: [Self]) -> [Self] {
        Dictionary(grouping: meetings, by: \.id).values.compactMap { copies in
            copies.sorted { a, b in
                if a.isOwnInvite != b.isOwnInvite { return a.isOwnInvite }
                if a.guests.count != b.guests.count { return a.guests.count > b.guests.count }
                return a.reference.calendar < b.reference.calendar
            }.first
        }.sorted { $0.reference.start == $1.reference.start ? $0.id < $1.id : $0.reference.start < $1.reference.start }
    }
}

public enum MeetingLinks {
    public static func provider(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        if host == "meet.google.com", url.path.range(of: "^/(?:[a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/[A-Za-z0-9_-]+)$", options: .regularExpression) != nil { return "Google Meet" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoomgov.com" || host.hasSuffix(".zoomgov.com") {
            if url.path.range(of: "^/(?:j/[0-9]+|my/[A-Za-z0-9._-]+|w/[0-9]+)(?:/|$)", options: .regularExpression) != nil { return "Zoom" }
        }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host),
           url.path.hasPrefix("/l/meetup-join/") || url.path.hasPrefix("/meet/") { return "Microsoft Teams" }
        return nil
    }
    public static func find(in fields: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in fields.compactMap({ $0 }) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url else { continue }
                if provider(url) != nil { return url }
                // Decode common Microsoft link wrappers locally; never fetch redirects.
                if url.host?.lowercased().hasSuffix(".safelinks.protection.outlook.com") == true,
                   let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                   let unwrapped = URL(string: value), provider(unwrapped) != nil { return unwrapped }
            }
        }
        return nil
    }
}

public struct MeetingReminderLedger: Codable, Sendable {
    public var shown: [String: Date] = [:]
    public var snoozed: [String: Date] = [:]
    public init() {}
    public mutating func due(_ meetings: [CalendarMeeting], now: Date, lead: TimeInterval, recording: Bool) -> CalendarMeeting? {
        shown = shown.filter { $0.value > now.addingTimeInterval(-7 * 86400) }
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-3600) }
        guard !recording else { return nil }
        return meetings.first { meeting in
            let start = meeting.reference.start
            guard meeting.reference.end > now, start > now.addingTimeInterval(-5 * 60) else { return false }
            if let until = snoozed[meeting.reminderKey] { return until <= now }
            return shown[meeting.reminderKey] == nil && start.addingTimeInterval(-lead) <= now
        }
    }
    public mutating func markShown(_ meeting: CalendarMeeting, now: Date) { shown[meeting.reminderKey] = now; snoozed[meeting.reminderKey] = nil }
    public mutating func snooze(_ meeting: CalendarMeeting, until: Date) { snoozed[meeting.reminderKey] = until }
}
