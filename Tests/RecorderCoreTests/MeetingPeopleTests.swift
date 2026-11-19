#if canImport(XCTest)
import XCTest
#endif
@testable import RecorderCore
import Foundation

final class MeetingPeopleTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func meeting(_ guests: [MeetingGuest] = [], id: String = "meeting", offset: Double = 0, own: Bool = false, available: Bool = true) -> CalendarMeeting {
        .init(reference: .init(occurrenceID: id, title: "Planning", start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 1800),
                               calendar: own ? "Mine" : "Shared", joinURL: URL(string: "https://meet.google.com/abc-defg-hij")!),
              guests: guests, guestListAvailable: available, isOwnInvite: own)
    }
    func testPeopleRememberAliasesAndPreferredNamesWithoutMergingDistinctAddresses() throws {
        var directory = PeopleDirectory()
        var avery = directory.remember(email: " Avery@Example.com ", name: "avery@example.com")
        avery.name = "Avery Willow"; avery.emails.append("avery+work@example.com")
        try directory.update(avery)
        let found = directory.remember(email: "AVERY+WORK@example.com", name: "A different calendar name")
        XCTAssertEqual(found.id, avery.id); XCTAssertEqual(found.name, "Avery Willow")
        let other = directory.remember(email: "a.very@example.com", name: "Avery Willow")
        XCTAssertTrue(other.id != avery.id)
        XCTAssertThrowsError(try directory.update(.init(name: "Duplicate", emails: ["avery@example.com"])))
    }
    func testAttendeePickerFiltersPeopleAndRestoresCalendarGuestsByAlias() throws {
        var people = PeopleDirectory()
        people.selfEmails = ["me@example.com"]
        let guest = KnownIdentity(name: "Avery", emails: ["avery@example.com", "alias@example.com"])
        try people.update(guest)
        _ = people.remember(email: "room@example.com", name: "Room", kind: .resource)
        _ = people.remember(email: "all@example.com", name: "Team", kind: .group)
        _ = people.remember(email: "me@example.com", name: "Self")
        XCTAssertEqual(AttendanceRoster.choices(matching: "ALIAS", in: people).map(\.id), [guest.id])
        XCTAssertEqual(AttendanceRoster.choices(matching: "", in: people).map(\.id), [guest.id])
        var roster = AttendanceRoster([.init(id: guest.id, name: guest.name, attendance: .absent, groupIDs: ["team"])])
        try roster.select(guest, from: people)
        try roster.select(guest, from: people)
        XCTAssertEqual(roster.attendees.count, 1)
        XCTAssertEqual(roster.attendees[0].attendance, .attended)
        XCTAssertEqual(roster.attendees[0].groupIDs, ["team"])
        XCTAssertThrowsError(try roster.add(name: "Duplicate", email: "ALIAS@example.com", remember: true, in: people))
    }

    func testNameOnlyAndCallOnlyGuestsRemainDistinctAndLinkByChoice() throws {
        var people = PeopleDirectory()
        var roster = AttendanceRoster([])
        try roster.add(name: "Lee", email: "guest@example.com", remember: false, in: people)
        try roster.add(name: "Lee", email: "", remember: true, in: people)
        XCTAssertTrue(people.people.isEmpty)
        people = try roster.directory(includingPendingIn: people)
        XCTAssertEqual(people.people.count, 1)
        let savedPerson = people.people[0]
        XCTAssertTrue(savedPerson.emails.isEmpty)
        let local = roster.attendees[0]
        let later = people.remember(email: "guest@example.com", name: "Lee Rivera")
        XCTAssertNil(people.identity(for: local))
        XCTAssertNotEqual(local.name, roster.attendees[1].name)
        try roster.select(later, from: people)
        XCTAssertEqual(roster.attendees.count, 2)
        XCTAssertEqual(roster.attendees[0].id, local.id)
        XCTAssertEqual(roster.attendees[0].name, local.name)
        XCTAssertEqual(people.labels(for: roster.attendees)[local.name], "Lee Rivera")
        try roster.select(savedPerson, from: people, linking: local.id)
        XCTAssertEqual(roster.attendees.count, 1)
        XCTAssertEqual(roster.renames[local.name], roster.attendees[0].name)
        XCTAssertThrowsError(try people.update(.init(name: "Group", emails: [], kind: .group)))
    }

    func testOneToOneExcludesSelfAndUsesSavedName() throws {
        var directory = PeopleDirectory()
        let avery = directory.remember(email: "avery@example.com", name: "Avery")
        let call = meeting([.init(email: "casey@example.com", isSelf: true), .init(email: "avery@example.com", name: "Raw address")])
        let details = call.callDetails(directory: &directory)
        XCTAssertEqual(details.participants, ["Avery"]); XCTAssertEqual(details.inferredParticipant, "Avery")
        XCTAssertEqual(details.callAttendees.first?.id, avery.id)
        XCTAssertEqual(directory.selfEmails, ["casey@example.com"])
        XCTAssertEqual(directory.people.count, 1)
        XCTAssertEqual(details.meeting?.occurrenceID, call.id)
    }
    func testSelfAliasesAndResourcesAreNeverSpeakersAndUnknownGuestListDoesNotInfer() throws {
        var directory = PeopleDirectory(); directory.selfEmails = ["casey@example.com", "alias@example.com"]
        let call = meeting([.init(email: "alias@example.com"), .init(email: "room@example.com", kind: .resource), .init(email: "avery@example.com", name: "Avery")], available: false)
        let details = call.callDetails(directory: &directory)
        XCTAssertEqual(details.participants, ["Avery"]); XCTAssertNil(details.inferredParticipant)
        XCTAssertEqual(details.callAttendees.count, 1)
    }
    func testUserGroupClassificationSurvivesPersonTypedCalendarGuestsAndBlocksInference() throws {
        var directory = PeopleDirectory()
        var group = directory.remember(email: "studio@example.com", name: "Studio")
        group.kind = .group; try directory.update(group)
        let details = meeting([.init(email: "studio@example.com", kind: .person), .init(email: "avery@example.com", name: "Avery")]).callDetails(directory: &directory)
        XCTAssertEqual(details.participants, ["Avery"]); XCTAssertNil(details.inferredParticipant)
        XCTAssertTrue(details.hasActiveGroups)
        XCTAssertEqual(directory.identity(email: "studio@example.com")?.kind, .group)
        XCTAssertTrue(directory.identity(email: "studio@example.com")!.memberIDs.isEmpty)
    }
    func testGroupRosterDeduplicatesDirectGuestsHonorsDeclinesAndExcludesSelf() throws {
        var directory = PeopleDirectory(); directory.selfEmails = ["casey@example.com"]
        let avery = directory.remember(email: "avery@example.com", name: "Avery")
        let sam = directory.remember(email: "sam@example.com", name: "Sam")
        let casey = directory.remember(email: "casey@example.com", name: "Casey")
        var group = directory.remember(email: "team@example.com", name: "Team", kind: .group)
        group.memberIDs = [avery.id, sam.id, casey.id]; try directory.update(group)
        let details = meeting([.init(email: "team@example.com"), .init(email: "avery@example.com", declined: true)]).callDetails(directory: &directory)
        XCTAssertEqual(details.participants, ["Sam"]); XCTAssertNil(details.inferredParticipant)
        XCTAssertEqual(details.callAttendees.filter { $0.id == avery.id }.count, 1)
        XCTAssertEqual(details.callAttendees.first { $0.id == avery.id }?.attendance, .absent)
        XCTAssertEqual(details.callAttendees.first { $0.id == sam.id }?.groupIDs, [group.id])
        XCTAssertFalse(details.callAttendees.contains { $0.id == casey.id })
    }
    func testDuplicateNamesHaveDistinctPerCallLabelsWithoutChangingDirectory() throws {
        var directory = PeopleDirectory()
        let details = meeting([.init(email: "a@example.com", name: "Alex"), .init(email: "b@example.com", name: "alex")]).callDetails(directory: &directory)
        XCTAssertEqual(Set(details.participants).count, 2)
        XCTAssertTrue(details.participants.allSatisfy { $0.contains("@example.com") })
        XCTAssertEqual(directory.people.map(\.name), ["Alex", "alex"])
    }
    func testAttendanceNeedsExplicitConfirmationBeforeInferringRemainingPerson() throws {
        let avery = CallAttendee(name: "Avery"), sam = CallAttendee(name: "Sam")
        let original = CallDetails(participants: ["Avery", "Sam"], attendees: [avery, sam], allowSingleParticipantInference: true)
        var rows = original.callAttendees; rows[1].attendance = .absent
        let updated = try original.updatingAttendance(rows)
        XCTAssertEqual(updated.participants, ["Avery"]); XCTAssertNil(updated.inferredParticipant)
        XCTAssertEqual(updated.callAttendees[1].id, sam.id)
        let confirmed = try updated.updatingAttendance(rows, confirmOnly: avery.id)
        XCTAssertEqual(confirmed.inferredParticipant, "Avery")
        rows[1].attendance = .expected
        XCTAssertNil(try confirmed.updatingAttendance(rows).inferredParticipant)
    }
    func testGroupsMustBeReviewedBeforeOnlyAttendeeConfirmationAndAttendedStatusKeepsInference() throws {
        let avery = CallAttendee(name: "Avery"), group = CallAttendee(name: "Team", kind: .group)
        let details = CallDetails(participants: ["Avery"], attendees: [avery, group], allowSingleParticipantInference: false)
        XCTAssertThrowsError(try details.updatingAttendance([avery, group], confirmOnly: avery.id))
        var one = CallDetails(participants: ["Avery"], attendees: [avery], allowSingleParticipantInference: true)
        var rows = one.callAttendees; rows[0].attendance = .attended
        one = try one.updatingAttendance(rows)
        XCTAssertEqual(one.inferredParticipant, "Avery")
    }
    func testOccurrenceIdentityDeduplicatesSharedCopiesButSeparatesRecurringDates() throws {
        let first = CalendarMeeting.occurrenceID(externalID: "external", localID: "localA", occurrence: start)
        let shared = CalendarMeeting.occurrenceID(externalID: "external", localID: "localB", occurrence: start)
        let next = CalendarMeeting.occurrenceID(externalID: "external", localID: "localA", occurrence: start.addingTimeInterval(86400))
        XCTAssertEqual(first, shared); XCTAssertTrue(first != next)
        let mine = meeting([.init(email: "casey@example.com", isSelf: true)], id: first, own: true)
        let other = meeting([.init(email: "casey@example.com"), .init(email: "extra@example.com")], id: shared)
        XCTAssertEqual(CalendarMeeting.deduplicated([other, mine]), [mine])
    }
    func testMeetingURLsRequireRealProviderHostsAndMeetingPaths() throws {
        for text in ["https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/123456?pwd=test", "https://teams.microsoft.com/l/meetup-join/19%3ameeting/0?context=test", "https://teams.live.com/meet/123"] {
            XCTAssertTrue(MeetingLinks.find(in: ["Join: " + text]) != nil)
        }
        for text in ["https://meet.google.com.evil.test/abc-defg-hij", "https://notzoom.us/j/123", "https://zoom.us/pricing", "http://zoom.us/j/123", "https://user@zoom.us/j/123", "https://teams.microsoft.com/help"] {
            XCTAssertNil(MeetingLinks.find(in: [text]))
        }
        let wrapped = "https://nam.safelinks.protection.outlook.com/?url=https%3A%2F%2Fzoom.us%2Fj%2F123&data=test"
        XCTAssertEqual(MeetingLinks.find(in: [nil, wrapped])?.host, "zoom.us")
    }
    func testRemindersOncePerScheduledOccurrenceWithSnoozeAndReschedule() throws {
        let call = meeting(); var ledger = MeetingReminderLedger()
        XCTAssertNil(ledger.due([call], now: start.addingTimeInterval(-61), lead: 60, recording: false))
        XCTAssertNil(ledger.due([call], now: start.addingTimeInterval(-60), lead: 60, recording: true))
        XCTAssertEqual(ledger.due([call], now: start.addingTimeInterval(-60), lead: 60, recording: false), call)
        ledger.markShown(call, now: start.addingTimeInterval(-60))
        XCTAssertNil(ledger.due([call], now: start, lead: 60, recording: false))
        ledger.snooze(call, until: start.addingTimeInterval(60))
        XCTAssertNil(ledger.due([call], now: start, lead: 60, recording: false))
        XCTAssertEqual(ledger.due([call], now: start.addingTimeInterval(60), lead: 60, recording: false), call)
        ledger.markShown(call, now: start.addingTimeInterval(60))
        let moved = meeting(offset: 3600)
        XCTAssertEqual(ledger.due([moved], now: start.addingTimeInterval(3540), lead: 60, recording: false), moved)
        let restored = try JSONDecoder().decode(MeetingReminderLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.shown, ledger.shown)
    }
    func testWakeSkipsStaleAndEndedMeetings() throws {
        var ledger = MeetingReminderLedger(); let call = meeting()
        XCTAssertNil(ledger.due([call], now: start.addingTimeInterval(301), lead: 60, recording: false))
        ledger.snooze(call, until: start.addingTimeInterval(300))
        XCTAssertNil(ledger.due([call], now: start.addingTimeInterval(1801), lead: 60, recording: false))
    }
    func testDirectoryRoundTripIsPrivateAndUnreadableFileIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("People.json")
        var directory = PeopleDirectory(); directory.selfEmails = ["casey@example.com"]
        _ = directory.remember(email: "avery@example.com", name: "Avery")
        try directory.save(to: file)
        XCTAssertEqual(try PeopleDirectory.load(from: file), directory)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let broken = Data("not JSON".utf8); try broken.write(to: file)
        XCTAssertThrowsError(try directory.save(to: file))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
}
