import AppKit
import AVFoundation
import Combine
import Lookback
import SwiftUI
@testable import RecorderCore

/// Run with Scripts/check-library.sh Tests/MainThreadBenchmark.swift --release [calls] [trials].
/// Append --recording-scroll to exercise a hidden activity list under 10 Hz recorder updates.
/// All recordings, sessions, contacts and issues are generated in a private temporary directory.
@main struct MainThreadBenchmark {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw RecorderError.message(message) }
    }
    static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    struct Sample { var time: Double; var gap: Double }
    /// Longest interval between opportunities to service the main queue during this operation.
    /// Include both endpoints so a fully synchronous operation is measured too.
    @MainActor static func timed(_ body: () async throws -> Void) async rethrows -> Sample {
        var last = now(), gap = 0.0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        func tick() { let t = now(); gap = max(gap, t - last); last = t }
        timer.setEventHandler { tick() }
        timer.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        timer.resume()
        let start = now()
        last = start
        defer { timer.cancel() }
        try await body()
        tick()
        return Sample(time: last - start, gap: gap)
    }
    static func report(_ label: String, _ samples: [Sample]) {
        func values(_ key: KeyPath<Sample, Double>) -> String {
            let xs = samples.map { $0[keyPath: key] }.sorted()
            func p(_ q: Double) -> Double { xs[Int(ceil(q * Double(xs.count))) - 1] }
            return String(format: "%.3f %.3f", p(0.5), p(0.95))
        }
        print("MEASURE \(label) wall_ms_p50_p95 \(values(\.time)) main_gap_ms_p50_p95 \(values(\.gap))")
    }

    static func seed(_ root: URL, calls: Int) throws {
        let fm = FileManager.default, callsRoot = root.appendingPathComponent("Calls")
        let source = root.appendingPathComponent("silence.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let audio = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96000])
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buf.frameLength = buf.frameCapacity
            for ch in 0..<2 { buf.floatChannelData![ch].initialize(repeating: 0, count: 48000) }
            for _ in 0..<60 { try audio.write(from: buf) }
        }
        for i in 0..<calls {
            let folder = callsRoot.appendingPathComponent("Call-" + String(format: "%05d", i))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.linkItem(at: source, to: folder.appendingPathComponent("Mixed.m4a"))
            try CallDetailsStore.writeInitial(.init(title: "Fixture review \(i)"), to: folder.appendingPathComponent("CallDetails.json"))
            if i.isMultiple(of: 2) {
                let input = try TranscriptionInput.resolve(folder)
                let transcript = try Transcript(input: input, model: SpeechModel.catalog[0], engine: "fixture", language: "en",
                    segments: [.init(source: .mixed, start: 0, end: 3, text: "Fixture review for iteration \(i)", timing: "word")])
                _ = try transcript.save(beside: input)
            }
        }
        let projects = root.appendingPathComponent("Projects"), project = projects.appendingPathComponent("example")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        for i in 0..<(2 * calls) {
            let file = project.appendingPathComponent(String(format: "00000000-0000-0000-0000-%012d.jsonl", i))
            let line = #"{"type":"user","uuid":"first","cwd":"/fixture","message":{"content":"Fixture review number \#(i)"}}"#
            try Data((line + "\n").utf8).write(to: file)
        }
        let coding = try CodingArchive(directory: root.appendingPathComponent("CodingSessions"))
        try coding.setEnabled(true); try coding.addProject("/fixture")
        try coding.synchronize(reader: ClaudeCodeReader(projectsDirectory: projects))
        try coding.setEnabled(false)
        try require(try coding.sessions().count == 2 * calls, "Generated session count")
        var people = PeopleDirectory()
        people.people = (0..<(calls * 4)).map { KnownIdentity(name: "Guest \($0)", emails: ["guest\($0)@example.test"]) }
        try people.save(to: root.appendingPathComponent("People.json"))
    }
    static func fillGitHub(_ root: URL, count: Int) throws {
        let db = try GitHubArchive(directory: root.appendingPathComponent("GitHub"))
        try db.connect(.init(id: "fixture", login: "fixture"))
        try db.select(.init(id: "repo", name: "example/demo"))
        let repo = try db.selections()[0]
        try db.begin(repo, now: Date())
        guard let work = try db.next(repo) else { throw RecorderError.message("Missing fixture queue") }
        var page = GitHubPage()
        for i in 1...count {
            let url = "https://example.test/pr/\(i)"
            let item = GitHubItem(id: "item-\(i)", repositoryID: "repo", type: "pr", title: "Fixture review \(i)",
                                  author: "fixture", state: "OPEN", url: url, number: i)
            let citation = GitHubPassage(id: "p-\(i)", actorID: "fixture", text: "Fixture review", url: url,
                kind: .review, date: Date(timeIntervalSince1970: Double(1700000000 + i)), edited: nil, verdict: nil, path: nil, line: nil)
            page.entries.append((item, citation))
        }
        try db.commit(page, work: work, repo: repo)
    }

    // The same OS lock used by summary and call-detail writes. Delay only in the explicit contention case.
    static func holdCallLock(_ recording: LibraryRecording) throws {
        let url = CallSummaryStore.lockURL(for: recording.url, isDirectory: recording.isDirectory)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw RecorderError.message("Could not open fixture lock") }
        guard flock(fd, LOCK_EX) == 0 else { close(fd); throw RecorderError.message("Could not acquire fixture lock") }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            flock(fd, LOCK_UN); close(fd)
        }
    }

    // The pre-experiment ranking contract, evaluated on the visible source arrays.
    @MainActor static func checkOrder(_ library: RecordingLibraryModel) throws {
        let calls = library.visibleRecordings.map {
            ActivityMatch(id: $0.id, source: .call, title: $0.name, evidence: library.searchHits[$0.id]?.snippet ?? "", date: $0.date)
        }
        let coding = library.visibleCoding.map {
            let hit = library.codingHits[$0.id]
            return ActivityMatch(id: $0.id, source: .coding, title: $0.title, evidence: hit?.text ?? "", date: hit?.timestamp ?? $0.updated)
        }
        let github = library.visibleGitHub.map {
            ActivityMatch(id: "github:" + $0.id, source: .github, title: $0.item.title, evidence: $0.citations.first?.text ?? "",
                          date: $0.date, qualified: GitHubReference(library.resultQuery) != nil)
        }
        let expected = ActivityMatch.ordered([calls, coding, github], query: library.resultQuery).map(\.id)
        try require(library.activity.map(\.id) == expected, "Cross-source result ordering changed")
    }

    @MainActor static func measureRecordingScroll(library: RecordingLibraryModel, recorder: RecordingCoordinator, trials: Int) async throws {
        let playback = RecordingPlayback(recorder: recorder)
        defer { playback.shutdown() }
        let host = NSHostingView(rootView: RecordingLibraryView(library: library, recorder: recorder, playback: playback, showControls: {}))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1180, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        func findList(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.numberOfRows >= library.activity.count { return table }
            return view.subviews.lazy.compactMap { findList(in: $0) }.first
        }
        guard let table = findList(in: host), let scroll = table.enclosingScrollView else {
            throw RecorderError.message("Activity list did not render")
        }
        let clip = scroll.contentView
        for trial in 1...trials {
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
            var moved = false
            let start = now(), cpu = clock()
            var previous = start, gaps: [Double] = []
            let wheel = DispatchSource.makeTimerSource(queue: .main)
            let meters = DispatchSource.makeTimerSource(queue: .main)
            defer { wheel.cancel(); meters.cancel() }
            // Deliver scroll steps to the fixture's clip view without posting system input.
            wheel.setEventHandler {
                let time = now()
                gaps.append(time - previous)
                previous = time
                let offset = CGFloat(gaps.count % 60) * 2
                clip.scroll(to: CGPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(clip)
                if clip.bounds.origin.y > 0 { moved = true }
            }
            var ticks = 0
            meters.setEventHandler {
                ticks += 1
                var sample = PipelineSnapshot()
                sample.frames = Int64((now() - start) * 48)
                sample.systemPeak = Float(ticks % 10) / 10
                recorder.receive(.levels(sample))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            wheel.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            meters.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            wheel.resume(); meters.resume()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let end = now()
            let usage = Double(clock() - cpu) / Double(CLOCKS_PER_SEC) / ((end - start) / 1000) * 100
            try require(moved && ticks > 0, "Timed scroll or recorder updates did not advance")
            gaps.append(end - previous)
            gaps.sort()
            let p95 = gaps[Int(ceil(0.95 * Double(gaps.count))) - 1]
            print(String(format: "SCROLL rows=%d trial=%d CPU=%.1f%% gap_p95=%.1fms gap_max=%.1fms ticks=%d",
                         library.activity.count, trial, usage, p95, gaps.last!, ticks))
        }
        try require(!NSApp.isActive && !window.isVisible, "Scroll fixture became visible")
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments.dropFirst().compactMap(Int.init)
        let n = args.first ?? 100, trials = args.dropFirst().first ?? 21
        try require(n >= 4 && trials >= 2, "Expected at least 4 calls and 2 trials")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { try? fm.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        try await Task.detached { try seed(root, calls: n) }.value
        UserDefaults.standard.set(root.appendingPathComponent("Calls").path, forKey: "destination")
        UserDefaults.standard.set(false, forKey: "KeyboardShortcuts_toggleCallRecording")
        let recorder = RecordingCoordinator(peopleURL: root.appendingPathComponent("People.json"), recoveryRoot: root.appendingPathComponent("Sessions"))
        recorder.shortcut.shutdown()
        defer { recorder.transcription.shutdown() }
        let library = RecordingLibraryModel(recorder: recorder, embeddingDirectory: root.appendingPathComponent("Embeddings"))
        defer { library.shutdown() }
        // Only the local archive is used. Stop the GitHub network coordinator before the fixture account exists.
        library.github.stop()
        while library.coding.busy || library.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        try fillGitHub(root, count: 4 * n)
        await library.refresh()?.value
        for _ in 0..<2000 {
            if library.coding.sessions.count == 2 * n { break }
            if let last = library.coding.sessions.last { library.loadOlderCoding(after: last.id) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(library.activity.count == 7 * n, "Expected \(7*n) rows, found \(library.activity.count)")
        try checkOrder(library)
        if CommandLine.arguments.contains("--recording-scroll") {
            try await measureRecordingScroll(library: library, recorder: recorder, trials: trials)
            return
        }
        // Measure the attendance transaction independently: publishing to the library's own calendar
        // schedules another full scan, which otherwise overlaps the following search sample.
        let attendanceCalendar = CalendarCoordinator(recorder: recorder, directoryURL: root.appendingPathComponent("People.json"), hasAccess: { false })
        defer { attendanceCalendar.shutdown() }
        let reference = library.activity.map(\.id)
        var samples: [String: [Sample]] = [:]
        let call = library.recordings[0], otherCall = library.recordings[1]
        let playback = RecordingPlayback(states: CurrentValueSubject<RecordingState, Never>(.idle).eraseToAnyPublisher())
        defer { playback.shutdown() }
        print("READY \(7*n) rows")
        for trial in -2..<trials {
            func save(_ key: String, _ value: Sample) { if trial >= 0 { samples[key, default: []].append(value) } }
            save("refresh", await timed { await library.refresh()?.value })
            try require(library.activity.map(\.id) == reference, "Refresh changed browse order")
            save("with-transcripts", await timed { library.filter = .transcribed })
            try require(library.activity.count == (n+1)/2 && library.visibleRecordings.allSatisfy(\.hasTranscript), "Sidebar filter")
            save("all-activity", await timed { library.filter = .activity })
            try require(library.activity.map(\.id) == reference, "Browse order or membership changed")
            library.search = "fixture"
            for _ in 0..<4000 where library.searching { try await Task.sleep(for: .milliseconds(2)) }
            try require(library.resultQuery == "fixture", "Debounced search timed out")
            save("search", await timed { await library.updateSearch(debounce: false)?.value })
            try require(library.visibleGitHub.count == 4*n && !library.visibleRecordings.isEmpty && !library.visibleCoding.isEmpty, "Search membership")
            try checkOrder(library)
            // A sidebar change with an active query reranks the matching rows on the baseline.
            save("search-sidebar", await timed { library.filter = .github })
            try require(library.activity.count == 4*n && library.visibleRecordings.isEmpty, "Scoped query")
            try checkOrder(library)
            library.filter = .activity
            save("clear", await timed { library.search = "" })
            try require(library.activity.map(\.id) == reference, "Clear search")
            playback.clear()
            for (label, selected) in [("playback", call), ("playback-switch", otherCall)] {
                save(label, try await timed {
                    playback.select(selected)
                    for _ in 0..<8000 {
                        if playback.ready || playback.error != nil { break }
                        try await Task.sleep(nanoseconds: 250_000)
                    }
                })
                try require(playback.ready && playback.duration >= 59 && playback.recordingID == selected.id, "Playback readiness")
            }
            // Isolate the filesystem transaction from the independent subsequent library scan.
            for contended in [false, true] {
                let label = contended ? "attendance-contended" : "attendance"
                let folder = root.appendingPathComponent("Attendance-\(label)-\(trial)")
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let fresh = LibraryRecording(url: folder, sourceName: "Attendance", isDirectory: true, details: .init(),
                    detailsError: nil, date: Date(), duration: nil, tracks: [], transcripts: [])
                var roster = AttendanceRoster([])
                try roster.add(name: "Late guest \(label) \(trial)", email: "", remember: true, in: attendanceCalendar.directory)
                let change = try CallDetailsStore.prepareAttendance(roster, for: fresh, confirmOnly: nil)
                if contended { try holdCallLock(fresh) }
                save(label, try await timed {
                    try await attendanceCalendar.saveAttendanceWithNewPeople(roster, change: change, for: fresh)
                })
                let details = try CallDetailsStore.load(for: folder, isDirectory: true)
                try require(details.participants.count == 1 && attendanceCalendar.directory.identity(for: details.callAttendees[0]) != nil, "Lost contact or link")
            }
        }
        library.search = "fixture"; let superseded = library.updateSearch(debounce: false)
        library.search = "absenttoken"; await library.updateSearch(debounce: false)?.value
        await superseded?.value
        for _ in 0..<4000 {
            if !library.searching && !library.refreshing { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try require(library.resultQuery == "absenttoken" && library.activity.isEmpty, "Superseded query published stale results: \(library.resultQuery), \(library.activity.count) rows")
        library.search = ""
        library.filter = .personal
        try require(library.activity.isEmpty, "Work rows visible during personal-scope transition")
        await library.refresh()?.value
        try require(library.activity.isEmpty, "Work rows in personal scope")
        library.filter = .activity
        await library.refresh()?.value
        try checkOrder(library)
        try require(library.activity.map(\.id) == reference, "Scope round trip changed work results")
        for key in samples.keys.sorted() { report(key, samples[key]!) }
        try require(!NSApp.isActive && !NSApp.windows.contains(where: \.isVisible), "Foreground fixture")
        print("PASS \(7*n) mixed rows, \(trials) measured trials after 2 warmups")
    }
}
