import SwiftUI
import AppKit
import RecorderCore

private enum LibraryFocus: Hashable { case callList, title(String) }

private struct LibrarySearchField: ViewModifier {
    @ObservedObject var presentation: LibrarySearchPresentation
    let setQuery: (String) -> Void

    func body(content: Content) -> some View {
        content.searchable(text: Binding(get: { presentation.text }, set: setQuery),
                           placement: .toolbar, prompt: "Search library")
    }
}

struct LibraryIndexProgress: View {
    @ObservedObject var presentation: LibrarySearchPresentation
    var showBar = false
    var body: some View {
        if let status = presentation.status, status.enabled {
            if showBar {
                Text(status.message).font(.callout)
                if status.total > 0 { ProgressView(value: Double(status.indexed), total: Double(status.total)) }
            } else {
                Text(status.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.top, 8)
            }
        } else if showBar { Text("Keyword search").font(.callout) }
    }
}

private extension CodingProvider {
    static let iconBundle: Bundle = {
        #if SWIFT_PACKAGE
        if let url = Bundle.main.url(forResource: "Afterword_Afterword", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
        #else
        return .main
        #endif
    }()

    static let images: [Self: NSImage] = [
        Self.codex: "Codex", .claudeCode: "ClaudeCode"
    ].compactMapValues { name in
        iconBundle.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    @ViewBuilder var icon: some View {
        if let image = Self.images[self] {
            Image(nsImage: image).renderingMode(.original).resizable().scaledToFit().frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal")
        }
    }
}

private extension LibraryFilter {
    @ViewBuilder var icon: some View {
        switch self {
        case .codex: CodingProvider.codex.icon
        case .claudeCode: CodingProvider.claudeCode.icon
        case .activity: Image(systemName: "rectangle.stack")
        case .github: Image(systemName: "arrow.triangle.branch")
        case .coding: Image(systemName: "terminal")
        case .recordings: Image(systemName: "waveform")
        case .transcribed: Image(systemName: "text.bubble")
        case .untranscribed: Image(systemName: "text.badge.plus")
        case .personal: Image(systemName: "person.crop.circle")
        case .needsSummary: Image(systemName: "square.and.pencil")
        }
    }
}

struct RecordingFolderPicker: View {
    @Binding var destination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let destination {
                Text((destination.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2).truncationMode(.middle).help(destination.path)
            }
            Button(destination == nil ? "Choose where to save recordings…" : "Change folder…") {
                if let folder = RecordingCoordinator.pickDestination(current: destination) { destination = folder }
            }
        }
    }
}

struct SourceToggles: View {
    @Binding var selection: Set<ActivitySource>
    @Binding var destination: URL?
    var recordingLocked = false

    var body: some View {
        ForEach(ActivitySource.allCases, id: \.self) { source in
            Toggle(isOn: Binding(get: { selection.contains(source) }, set: { enabled in
                var next = selection
                if enabled { next.insert(source) } else { next.remove(source) }
                selection = next
            })) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.libraryFilter.rawValue)
                        Group {
                            switch source {
                            case .recordings: Text("Record calls and transcribe them locally.")
                            case .coding: Text("Import Claude Code and Codex sessions.")
                            case .github: Text("Import your issues, pull requests, and reviews.")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { source.libraryFilter.icon }
            }
            if source == .recordings && selection.contains(.recordings) {
                RecordingFolderPicker(destination: $destination).disabled(recordingLocked)
                if destination == nil {
                    Text("You can also choose a folder when you start your first recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LibrarySourceChooser: View {
    @ObservedObject var library: RecordingLibraryModel
    @State private var selection: Set<ActivitySource> = []
    @State var destination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose your sources").font(.title.bold())
            Text("What would you like to see in Afterword? You can change this in Settings.")
                .foregroundStyle(.secondary)
            SourceToggles(selection: $selection, destination: $destination)
            if let error = library.sourceError { Text(error).foregroundStyle(.red) }
            Button("Open library") { library.setSources(selection, recordingDestination: destination) }
                .keyboardShortcut(.defaultAction).disabled(selection.isEmpty)
        }.frame(maxWidth: 360, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibrarySidebar: View {
    @Binding var selection: LibraryDestination
    let sources: Set<ActivitySource>
    @ObservedObject var coding: CodingCoordinator
    let openWindow: (LibraryCalendarPage) -> Void
    @State private var expanded: Set<LibraryFilter> = [.activity, .coding, .recordings]

    private var root: LibraryFilter {
        if sources.count == 1, let source = sources.first { return source.libraryFilter }
        return .activity
    }

    var body: some View {
        List(selection: $selection) {
            LibrarySidebarRow(filter: root, sources: sources, providers: coding.providers, selection: $selection, expanded: $expanded)
            if sources.contains(.recordings) {
                ForEach(LibraryCalendarPage.allCases, id: \.self) { page in
                    Label(page.rawValue, systemImage: page.symbol)
                        .tag(LibraryDestination.calendar(page))
                }
            }
        }.listStyle(.sidebar)
            .contextMenu(forSelectionType: LibraryDestination.self) { selection in
                if case .calendar(let page) = selection.first {
                    Button("Open in New Window") { openWindow(page) }
                }
            }
    }
}

private struct LibrarySidebarRow: View {
    let filter: LibraryFilter
    let sources: Set<ActivitySource>
    let providers: Set<CodingProvider>
    @Binding var selection: LibraryDestination
    @Binding var expanded: Set<LibraryFilter>

    var body: some View {
        let children = filter.children(sources: sources, providers: providers)
        let label = Label { Text(filter.rawValue) } icon: { filter.icon }
        if children.isEmpty {
            label.tag(LibraryDestination.activity(filter))
        } else {
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(filter) }, set: { open in
                if open {
                    expanded.insert(filter)
                } else {
                    if case .activity(let current) = selection, filter == .activity || children.contains(current) {
                        selection = .activity(filter)
                    }
                    expanded.remove(filter)
                }
            })) {
                ForEach(children) { child in
                    LibrarySidebarRow(filter: child, sources: sources, providers: providers, selection: $selection, expanded: $expanded)
                }
            } label: { label }.tag(LibraryDestination.activity(filter))
        }
    }
}

private struct SidebarActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 18)
            configuration.title
        }
    }
}

private struct RecordingToolbarButton: View {
    @ObservedObject var recorder: RecordingCoordinator
    @ObservedObject var clock: RecordingClock
    let showControls: () -> Void

    var body: some View {
        let label: (title: String, icon: String, help: String)
        switch recorder.state {
        case .preparing: label = ("Cancel", "xmark", "Cancel recording preparation")
        case .previewing: label = ("End test", "stop.fill", "End audio test")
        case .recording: label = ("Stop", "stop.fill", "Stop recording and save")
        case .finalizing: label = ("Saving…", "clock", "Saving recording")
        case .idle, .needsPermission, .error, .recoverable: label = ("Record", "record.circle", "Start recording")
        }
        return Button {
            if !recorder.noticesAccepted && !recorder.locked { showControls() }
            else { recorder.toggleRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: label.icon)
                    .foregroundStyle(recorder.state == .recording ? Color.red : .primary)
                Text(label.title)
                if recorder.capturing { Text(clock.text).monospacedDigit() }
            }.frame(minWidth: 66).fixedSize()
        }
        .accessibilityLabel(label.help)
        .accessibilityValue(recorder.capturing ? clock.text : "")
        .help(label.help)
        .disabled(recorder.state == .finalizing || (!recorder.locked && (recorder.resolved == nil || recorder.selectedChannel < 0)))
    }
}

struct RecordingLibraryView: View {
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var recorder: RecordingCoordinator
    let playback: RecordingPlayback
    let showControls: () -> Void
    @State private var detailsEditor: LibraryRecording?
    @State private var trashTarget: TrashTarget?
    @State private var managementError: String?
    @State private var discardTranscriptEdits: LibraryRecording?
    @State private var discardSummaryEdits: LibraryRecording?
    @Environment(\.openSettings) private var openSettings
    @FocusState private var focus: LibraryFocus?

    private func recordingRow(_ recording: LibraryRecording) -> some View {
        RecordingRow(recording: recording, library: library, focus: $focus).tag(recording.id)
            .contextMenu {
                Button("Rename") { library.beginRenaming(recording) }.disabled(library.managing || library.renamingID != nil)
                Button("Edit details…") { detailsEditor = recording }.disabled(library.managing || library.renamingID != nil)
                Button(recording.details.scope == .work ? "Mark as Personal" : "Move to Work") {
                    Task {
                        do { try await library.setScope(recording.details.scope == .work ? .personal : .work, for: recording) }
                        catch { managementError = error.localizedDescription }
                    }
                }.disabled(library.managing || recording.detailsError != nil || library.renamingID != nil)
                Button("Show in Finder") { recorder.reveal(recording.url) }
                Divider()
                Button("Move to Trash…", role: .destructive) { trashTarget = .init(recording: recording) }
                    .disabled(library.managing || recorder.locked || recorder.transcription.busy || library.transcriptDrafts[recording.id] != nil || library.summaryDrafts[recording.id] != nil || library.renamingID == recording.id)
            }
    }

    private func codingRow(_ session: CodingSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label { Text(session.title) } icon: {
                if let provider = CodingProvider(rawValue: session.source) { provider.icon }
                else { Image(systemName: "terminal") }
            }.font(.headline).lineLimit(2)
            Text([session.providerName, URL(fileURLWithPath: session.project).lastPathComponent, session.updated.formatted()].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let hit = library.codingHits[session.id] {
                Text(hit.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.tag(session.id)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            LibrarySidebar(selection: $library.destination, sources: library.sources, coding: library.coding,
                           openWindow: recorder.calendar.openWindow)
            VStack(alignment: .leading, spacing: 8) {
                if library.sources.contains(.recordings) {
                    TranscriptionActivity(transcription: recorder.transcription)
                    Menu {
                        Button("Add recordings folder…") { library.addFolder() }
                        Divider()
                        ForEach(library.roots, id: \.path) { folder in
                            Menu(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
                                Button("Show in Finder") { recorder.reveal(folder) }
                                Button("Remove from library") { library.removeFolder(folder) }
                                    .disabled(folder == recorder.destination?.resolvingSymlinksInPath().standardizedFileURL)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Label("Recording folders", systemImage: "folder")
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                }
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.labelStyle(SidebarActionLabelStyle())
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
        }.navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 300)
    }

    private var activityList: some View {
        VStack(spacing: 0) {
            if library.activity.isEmpty {
                ContentUnavailableView {
                    if library.search.isEmpty {
                        Label { Text(library.filter.emptyTitle) } icon: { library.filter.icon }
                    } else {
                        Label("No results", systemImage: "magnifyingglass")
                    }
                } description: {
                    if !library.search.isEmpty {
                        Text("Try another phrase or a different library filter.")
                    } else if library.filter == .github {
                        Button("Configure GitHub…") { library.settingsTab = "github"; openSettings() }
                    } else if !library.filter.showsRecordings {
                        Button("Choose coding projects…") { library.settingsTab = "coding"; openSettings() }
                    } else if library.filter == .recordings {
                        Text("Record a call or add a folder of existing recordings.")
                    }
                }
            } else {
                List(selection: $library.selection) {
                    ForEach(library.activity) { row in
                        switch row {
                        case .call(let recording): recordingRow(recording)
                        case .coding(let session):
                            codingRow(session)
                                .task(id: library.hasMoreCoding && session.id == library.coding.sessions.last?.id) {
                                    library.loadOlderCoding(after: session.id)
                                }
                        case .github(let hit):
                            VStack(alignment: .leading, spacing: 5) {
                                Label(hit.item.title, systemImage: "arrow.triangle.branch").font(.headline).lineLimit(2)
                                Text("\(hit.repository)#\(hit.item.number) · \(hit.date.formatted())").font(.caption)
                                    .foregroundStyle(.secondary)
                                if let passage = hit.citations.first {
                                    Text([passage.kind.label, passage.text].filter { !$0.isEmpty }.joined(separator: " · ")).font(
                                        .caption
                                    ).lineLimit(2)
                                }
                            }.tag(row.id)
                        }
                    }
                }.listStyle(.inset).focused($focus, equals: .callList)
                    .accessibilityIdentifier("recording-list")
            }
            Divider()
            LibraryIndexProgress(presentation: library.searchPresentation)
            HStack {
                if library.sources.contains(.recordings) && library.filter.showsRecordings {
                    Text("\(library.visibleRecordings.count) recording\(library.visibleRecordings.count == 1 ? "" : "s")")
                }
                if !library.visibleCoding.isEmpty || (library.filter.showsCoding && !library.filter.showsRecordings) {
                    Text("\(library.visibleCoding.count) coding session\(library.visibleCoding.count == 1 ? "" : "s")\(library.hasMoreCoding ? " loaded" : "")")
                }
                if library.filter == .github || !library.visibleGitHub.isEmpty {
                    Text("\(library.visibleGitHub.count) GitHub items")
                }
                Spacer()
                if library.refreshing || library.searching { ProgressView().controlSize(.mini) }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }

    @ViewBuilder private var activityDetail: some View {
        if let item = library.selectedGitHub {
            GitHubItemView(hit: item, directory: library.github.directory, revision: library.github.snapshot.revision).id(item.id)
        } else if let session = library.selectedCoding {
            CodingSessionDetail(session: session, directory: library.coding.directory, hit: library.codingHits[session.id]).id(session.id)
            .environment(\.githubLibraryLinks, .init(items: library.githubReferences, open: library.openGitHub))
        } else if let recording = library.selectedRecording {
            RecordingDetail(recording: recording, query: library.resultQuery, library: library, recorder: recorder, transcription: recorder.transcription, playback: playback,
                            editDetails: { detailsEditor = recording }, trash: { trashTarget = .init(recording: recording, version: $0) }, cancelEditing: cancelInlineEditing)
                .id(recording.id)
            .environment(\.githubLibraryLinks, .init(items: library.githubReferences, open: library.openGitHub))
        } else {
            ContentUnavailableView("Select an item", systemImage: "rectangle.stack")
        }
    }

    private var libraryContent: some View {
        NavigationSplitView(columnVisibility: Binding(get: { library.sidebarVisible ? .all : .detailOnly }, set: { library.sidebarVisible = $0 != .detailOnly })) {
            sidebar
        } detail: {
            // Keep the native list and detail mounted so switching pages preserves both scroll positions.
            HSplitView {
                activityList.frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
                activityDetail.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(library.calendarPage != nil)
            .allowsHitTesting(library.calendarPage == nil)
            .accessibilityHidden(library.calendarPage != nil)
            .overlay {
                switch library.calendarPage {
                case .upcoming:
                    UpcomingMeetingsView(calendar: recorder.calendar, embedded: true) {
                        library.destination = .calendar(.people)
                    }
                    .onAppear {
                        recorder.calendar.startMonitoring(refreshImmediately: false)
                        recorder.calendar.refresh()
                    }
                case .people:
                    PeopleDirectoryView(calendar: recorder.calendar, embedded: true)
                case nil:
                    Color.clear.frame(width: 0, height: 0)
                        .modifier(LibrarySearchField(presentation: library.searchPresentation, setQuery: { library.search = $0 }))
                }
            }
            .navigationTitle(library.calendarPage?.rawValue ?? library.filter.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if library.calendarPage == nil {
                    Menu {
                        if library.filter == .github {
                            Picker("Repository", selection: $library.githubRepository) {
                                Text("Any repository").tag("")
                                ForEach(library.github.snapshot.selections) { Text($0.repo.name).tag($0.repo.name) }
                            }
                            Picker("Item type", selection: $library.githubType) {
                                Text("Issues and pull requests").tag(""); Text("Issues").tag("issue"); Text("Pull requests").tag("pr")
                            }
                            Picker("Activity date", selection: $library.githubPeriod) {
                                ForEach(GitHubPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Contribution", selection: $library.githubAction) {
                                Text("Any contribution").tag("")
                                ForEach(GitHubActionKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                            }
                        }
                        if library.sources.contains(.recordings) && library.filter.showsRecordings {
                            Toggle("Search previous transcript versions", isOn: $library.searchHistory)
                            Picker("Speaker", selection: $library.searchSpeaker) {
                                Text("Any speaker").tag("")
                                ForEach(library.speakerNames, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if library.sources.contains(.coding) && !library.coding.projects.isEmpty && library.filter.showsCoding {
                            Picker("Coding project", selection: $library.codingProject) {
                                Text("Any project").tag("")
                                ForEach(library.coding.projects, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("Coding branch", selection: $library.codingBranch) {
                                Text("Any branch").tag("")
                                ForEach(library.coding.branches, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Divider()
                        Text("Matches word beginnings · \"exact words or phrases\"")
                    } label: { Label("Search options", systemImage: library.searchHistory || !library.searchSpeaker.isEmpty ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                        .help("Search options")
                    Button {
                        library.github.refresh(); library.coding.refresh(); library.refresh()
                    } label: {
                        Label("Refresh library", systemImage: "arrow.clockwise")
                    }
                        .help("Refresh enabled sources")
                }
                if library.sources.contains(.recordings) {
                    Button(action: showControls) { Label("Recording controls", systemImage: "slider.horizontal.3") }
                        .help("Microphone, audio levels, and recording controls")
                    RecordingToolbarButton(recorder: recorder, clock: recorder.telemetry.clock, showControls: showControls)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if library.sources.contains(.recordings), let message = recorder.message {
                    HStack {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button("Recording controls", action: showControls)
                    }.font(.caption).padding(10).background(.bar)
                }
                if library.calendarPage == nil && !library.issues.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(library.issues.joined(separator: "\n")).textSelection(.enabled)
                        Spacer()
                        Button("Retry") { library.refresh() }
                    }.font(.caption).padding(10).background(.bar)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var body: some View {
        Group {
            if library.sources.isEmpty { LibrarySourceChooser(library: library, destination: recorder.destination) }
            else { libraryContent }
        }
        .background(LibraryCommandScope(bindings: library.calendarPage == nil ? keyboardBindings : [:], cancelEditing: .init(enabled: {
            library.calendarPage == nil && (library.renamingID != nil || library.selectedRecording.map { library.transcriptDrafts[$0.id] != nil || library.summaryDrafts[$0.id] != nil } == true)
        }, perform: cancelInlineEditing)).frame(width: 0, height: 0))
        .frame(minWidth: 940, minHeight: 600)
        .sheet(item: $detailsEditor) { recording in
            CallDetailsEditor(recording: recording, library: library)
        }
        .confirmationDialog(trashTarget?.title ?? "Move to Trash?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } }), titleVisibility: .visible, presenting: trashTarget) { target in
            Button("Move to Trash", role: .destructive) {
                Task {
                    do { try await library.moveToTrash(target.recording, version: target.version, playback: playback) }
                    catch { managementError = error.localizedDescription }
                }
            }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.cancelAction)
        } message: { target in Text(target.message) }
        .confirmationDialog("Discard transcript edits?", isPresented: Binding(get: { discardTranscriptEdits != nil }, set: { if !$0 { discardTranscriptEdits = nil } }), titleVisibility: .visible, presenting: discardTranscriptEdits) { recording in
            Button("Discard Edits", role: .destructive) { library.cancelTranscriptEditing(recording) }.keyboardShortcut(.defaultAction)
            Button("Keep Editing", role: .cancel) {}.keyboardShortcut(.cancelAction)
        } message: { _ in Text("Your unsaved text and speaker changes will be discarded. The saved transcript will stay as it is.") }
        .confirmationDialog("Discard summary edits?", isPresented: Binding(get: { discardSummaryEdits != nil }, set: { if !$0 { discardSummaryEdits = nil } }), titleVisibility: .visible, presenting: discardSummaryEdits) { recording in
            Button("Discard Edits", role: .destructive) { library.cancelSummaryEditing(recording) }.keyboardShortcut(.defaultAction)
            Button("Keep Editing", role: .cancel) {}.keyboardShortcut(.cancelAction)
        } message: { _ in Text("Your unsaved summary changes will be discarded. Saved versions are kept.") }
        .alert("Couldn’t update recording", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("OK", role: .cancel) { managementError = nil }
        } message: { Text(managementError ?? "") }
        .onChange(of: library.selectedRecording?.id) { _, _ in
            if let recording = library.selectedRecording { playback.select(recording) }
            else { playback.clear() }
        }
        .onChange(of: library.renamingID) { previous, current in
            if previous != nil && current == nil && library.calendarPage == nil { focus = .callList }
        }
        .onChange(of: library.selectedRecording.flatMap { library.summaryDrafts[$0.id]?.id }) { previous, current in
            if previous != nil && current == nil && library.calendarPage == nil { focus = .callList }
        }
        .onChange(of: library.selectedRecording.flatMap { library.transcriptDrafts[$0.id]?.version.id }) { previous, current in
            if previous != nil && current == nil && library.calendarPage == nil { focus = .callList }
        }
    }

    private func cancelInlineEditing() {
        if library.renamingID != nil { library.cancelRename(); return }
        if let recording = library.selectedRecording, let draft = library.summaryDrafts[recording.id] {
            guard !draft.saving else { return }
            if draft.changed { discardSummaryEdits = recording }
            else { library.cancelSummaryEditing(recording) }
            return
        }
        guard let recording = library.selectedRecording, let draft = library.transcriptDrafts[recording.id], !draft.saving else { return }
        if draft.changed { discardTranscriptEdits = recording }
        else { library.cancelTranscriptEditing(recording) }
    }

    private var keyboardBindings: [LibraryCommand: LibraryCommandBinding] {
        [
            .rename: .init(enabled: { library.selectedRecording != nil && !library.managing && library.renamingID == nil }, perform: {
                if let recording = library.selectedRecording { library.beginRenaming(recording) }
            }),
            .trash: .init(enabled: {
                focus == .callList && library.selectedRecording != nil && !library.managing && !recorder.locked && !recorder.transcription.busy && library.renamingID == nil && library.selectedRecording.map { library.transcriptDrafts[$0.id] == nil && library.summaryDrafts[$0.id] == nil } == true
            }, perform: {
                if let recording = library.selectedRecording { trashTarget = .init(recording: recording) }
            }),
            .details: .init(enabled: { library.selectedRecording != nil && !library.managing && library.renamingID == nil }, perform: {
                detailsEditor = library.selectedRecording
            }),
            .save: .init(enabled: {
                guard !library.managing else { return false }
                if library.renamingID != nil { return !library.renaming }
                if let recording = library.selectedRecording, let draft = library.summaryDrafts[recording.id] { return draft.changed && !draft.saving }
                guard let recording = library.selectedRecording, let draft = library.transcriptDrafts[recording.id] else { return false }
                return draft.changed && !draft.saving
            }, perform: {
                if library.renamingID != nil { Task { await library.saveRename() } }
                else if let recording = library.selectedRecording, library.summaryDrafts[recording.id] != nil { Task { await library.saveSummaryDraft(for: recording) } }
                else if let recording = library.selectedRecording { Task { await library.saveTranscriptDraft(for: recording) } }
            })
        ]
    }
}

private struct TrashTarget {
    let recording: LibraryRecording
    var version: LibraryTranscript? = nil
    var title: String { version == nil ? "Move “\(recording.name)” to Trash?" : "Move this transcript version to Trash?" }
    var message: String {
        version == nil ? "The call’s audio, details, summaries, and associated transcripts will move to the Mac’s Trash. You can restore them from there."
            : "This version’s text and JSON files will move to Trash. The recording and other transcript versions will remain."
    }
}

private struct RecordingRow: View {
    let recording: LibraryRecording
    @ObservedObject var library: RecordingLibraryModel
    @FocusState.Binding var focus: LibraryFocus?
    private var isRenaming: Bool { library.renamingID == recording.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if isRenaming {
                    TextField("Call title", text: $library.renameText).font(.headline).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .title(recording.id)).onSubmit { Task { await library.saveRename() } }
                        .onExitCommand { library.cancelRename() }.disabled(library.renaming)
                        .task {
                            await Task.yield()
                            if !Task.isCancelled && isRenaming { focus = .title(recording.id) }
                        }
                    Button { Task { await library.saveRename() } } label: { Image(systemName: "checkmark") }
                        .help("Save title (Return)").accessibilityLabel("Save title").disabled(library.managing)
                    Button { library.cancelRename() } label: { Image(systemName: "xmark") }
                        .help("Cancel rename (Escape)").accessibilityLabel("Cancel rename").disabled(library.renaming)
                } else {
                    Text(recording.name).font(.headline).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { library.beginRenaming(recording) } label: { Image(systemName: "pencil").font(.caption) }
                        .foregroundStyle(.secondary).help("Rename call (R)").accessibilityLabel("Rename \(recording.name)")
                        .disabled(library.managing || library.renamingID != nil)
                }
            }.buttonStyle(.borderless)
            if isRenaming, let error = library.renameError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 6) {
                Text(recording.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                if let duration = recording.duration { Text("·"); Text(Transcript.timestamp(duration)) }
            }.font(.caption).foregroundStyle(.secondary)
            if library.transcriptDrafts[recording.id] != nil {
                Label("Editing transcript", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
            } else if let passage = library.searchHits[recording.id]?.snippet {
                Text(passage).font(.caption).lineLimit(3).foregroundStyle(.secondary)
            } else {
                Label(recording.hasTranscript ? "Transcript available" : recording.transcripts.isEmpty ? "Not transcribed" : "Transcript needs attention",
                      systemImage: recording.hasTranscript ? "text.bubble" : "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

private struct RecordingDetail: View {
    let recording: LibraryRecording
    let query: String
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var recorder: RecordingCoordinator
    @ObservedObject var transcription: TranscriptionCoordinator
    let playback: RecordingPlayback
    let editDetails: () -> Void
    let trash: (LibraryTranscript?) -> Void
    let cancelEditing: () -> Void
    @State private var versionID: String?
    @State private var reviewingSpeakers = false
    @State private var showingAttendance = false
    @State private var selectedSummary: Bool?
    private var showingSummary: Bool {
        get {
            if let selectedSummary { return selectedSummary }
            if library.summaryDrafts[recording.id] != nil { return true }
            if draft != nil { return false }
            if !query.isEmpty { return library.searchHits[recording.id]?.summaryMatch == true }
            return library.filter == .needsSummary || recording.summary?.current != nil
        }
        nonmutating set { selectedSummary = newValue }
    }
    private struct SuggestionRequest: Equatable {
        let versionID: String?
        let attendees: [CallAttendee]
        let automaticParticipant: String?
        let revision: Int
    }
    @State private var voiceRevision = 0
    @State private var loadedSuggestions: (request: SuggestionRequest, matches: [String: SpeakerSuggestion])?
    private var suggestionRequest: SuggestionRequest {
        .init(versionID: version?.id, attendees: recording.details.callAttendees,
              automaticParticipant: version.flatMap { recording.automaticParticipant(for: $0) }, revision: voiceRevision)
    }
    private var pendingSpeakerNames: [String: String] {
        guard let version else { return [:] }
        let matches = loadedSuggestions?.request == suggestionRequest ? loadedSuggestions?.matches : version.document?.speakerSuggestions
        guard let matches, !matches.isEmpty else { return [:] }
        return recording.details.pendingSpeakerNames(matches, for: version)
    }
    private var draft: TranscriptDraft? { library.transcriptDrafts[recording.id] }

    private var version: LibraryTranscript? {
        draft?.version ?? recording.transcripts.first { $0.id == versionID } ?? recording.latestTranscript
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(recording.name).font(.title2.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                    Spacer()
                    Menu {
                        Button("Rename") { library.beginRenaming(recording) }.disabled(library.renamingID != nil)
                        Button("Edit details…", action: editDetails).disabled(library.renamingID != nil)
                        Button("Show in Finder") { recorder.reveal(recording.url) }
                        Divider()
                        Button("Move call to Trash…", role: .destructive) { trash(nil) }.disabled(recorder.locked || transcription.busy || draft != nil || library.summaryDrafts[recording.id] != nil || library.renamingID == recording.id)
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                        .help("Call actions").accessibilityLabel("Call actions").disabled(library.managing)
                }
                HStack {
                    Text(recording.date, format: .dateTime.weekday().month().day().year().hour().minute())
                    Spacer()
                    Button(action: editDetails) { Label("Edit details", systemImage: "pencil") }.disabled(library.managing || library.renamingID != nil)
                        .help("Edit call details (⌘I)")
                }.font(.callout).foregroundStyle(.secondary)
                HStack {
                    Label(recording.details.participants.isEmpty ? "No active participants" : recording.participantDisplayNames.joined(separator: ", "), systemImage: "person.2")
                        .lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Attendance…") { showingAttendance = true }.disabled(library.managing)
                }.font(.callout)
                if recording.details.callAttendees.contains(where: { $0.attendance == .absent }) {
                    Text("\(recording.details.callAttendees.filter { $0.attendance == .absent }.count) excluded · Review attendance to restore")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let meeting = recording.details.meeting {
                    Label("From " + meeting.calendar, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                }
                if !recording.details.tags.isEmpty {
                    Label(recording.details.tags.joined(separator: " · "), systemImage: "tag").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                if !recording.details.description.isEmpty {
                    Text(recording.details.description).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                if let error = recording.detailsError {
                    Label("Couldn’t read call details: " + error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                Picker("Call content", selection: Binding(get: { showingSummary }, set: { showingSummary = $0 })) {
                    Text("Summary").tag(true)
                    Text("Transcript").tag(false)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Call content").disabled(draft != nil || library.summaryDrafts[recording.id] != nil)
                if !showingSummary {
                    HStack {
                        Text("Transcript").font(.headline)
                        Spacer()
                        if let draft {
                            InlineTranscriptActions(recording: recording, draft: draft, library: library, cancel: cancelEditing)
                        } else {
                            if let document = version?.document {
                                if recording.tracks.contains(where: { $0.source == .system }), document.segments.contains(where: { $0.source == .system }) {
                                    Button { playback.pause(); reviewingSpeakers = true } label: { Label("Speakers…", systemImage: "person.wave.2") }
                                        .disabled(library.managing || recorder.locked || transcription.busy)
                                }
                                Button(action: copyTranscript) { Label("Copy", systemImage: "doc.on.doc") }
                                .help("Copy readable transcript (⌘⇧C)")
                                Button { beginEditing() } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.plain).help("Edit transcript (E)").accessibilityLabel("Edit transcript")
                                    .disabled(library.managing || document.paragraphs.isEmpty)
                            }
                            Button(recording.transcripts.isEmpty ? "Transcribe" : "Transcribe again") {
                                transcription.transcribe(recording: recording.url)
                            }.disabled(transcription.busy || library.managing || recorder.locked || transcription.installed[transcription.selectedID] == nil)
                                .help("Transcribe with \(transcription.selected.name)")
                        }
                    }
                    if let draft { InlineTranscriptNotice(draft: draft) }
                    HStack {
                        if recording.transcripts.count > 1 {
                            Picker("Version", selection: Binding(get: { version?.id ?? "" }, set: { versionID = $0; library.preferredTranscriptID = nil })) {
                                ForEach(recording.transcripts) { version in
                                    Text("\(version.document?.editing == nil ? "" : "Edited · ")\(version.document?.modelName ?? "Unreadable transcript") · \(version.date.formatted(date: .abbreviated, time: .shortened))").tag(version.id)
                                }
                            }.font(.caption).disabled(draft != nil)
                        } else if let document = version?.document {
                            Text((document.editing == nil ? "" : "Edited · ") + document.modelName + " · " + document.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let version {
                            Spacer(minLength: 0)
                            Menu {
                                Button("Show transcript in Finder") { recorder.reveal(version.url) }
                                Divider()
                                Button("Move version to Trash…", role: .destructive) { trash(version) }
                                    .disabled(recorder.locked || transcription.busy || draft != nil)
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                                .help("Transcript version actions").accessibilityLabel("Transcript version actions").disabled(library.managing)
                        }
                    }
                }
            }.padding(24)
            Divider()
            if showingSummary {
                CallSummaryView(recording: recording, library: library, cancelEditing: cancelEditing)
            } else if let document = version?.document {
                ReadableTranscript(paragraphs: document.paragraphs, edited: document.editing != nil, query: query, playback: playback, playbackDisabled: recorder.locked,
                                   draft: draft, canEdit: !library.managing, editParagraph: { beginEditing(paragraph: $0) },
                                   participants: recording.details.participants, automaticParticipant: version.flatMap { recording.automaticParticipant(for: $0) },
                                   participantNames: version.map { recording.details.participantNames(for: $0) } ?? [:], displayNames: recording.directoryLabels ?? [:],
                                   speakerSuggestions: pendingSpeakerNames, assignGroup: { group, name, paragraph in
                                       if let version { Task { await library.assignSpeakerGroup(group, to: name, from: paragraph, recording: recording, version: version) } }
                                   },
                                   assignment: library.participantAssignments[recording.id].flatMap { $0.versionID == version?.id ? $0 : nil },
                                   assignParticipant: { name, paragraph in
                                       if let version { Task { await library.assignParticipant(name, to: paragraph, recording: recording, version: version) } }
                                   }, editParticipants: { showingAttendance = true },
                                   searchMatches: library.searchHits[recording.id].flatMap { $0.versionID == version?.id ? $0.paragraphIDs : nil } ?? [])
            } else if let error = version?.error {
                ContentUnavailableView {
                    Label("Couldn’t read this transcript", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Show transcript file") { if let url = version?.url { recorder.reveal(url) } }
                }
            } else {
                ContentUnavailableView {
                    Label("Ready when you are", systemImage: "text.bubble")
                } description: {
                    Text("Generate a transcript to read and search this recording. Audio is processed locally on your Mac.")
                } actions: {
                    if transcription.installed[transcription.selectedID] == nil {
                        SettingsLink { Text("Choose a model in Settings") }
                    } else {
                        Text("Selected model: \(transcription.selected.name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            PlaybackBar(recording: recording, playback: playback, disabled: recorder.locked)
        }
        .background(LibraryCommandScope(bindings: [
            .editTranscript: .init(enabled: { draft == nil && library.summaryDrafts[recording.id] == nil && !library.managing && library.renamingID == nil && version?.document?.paragraphs.isEmpty == false }, perform: { beginEditing(paragraph: 0) }),
            .copyTranscript: .init(enabled: { draft == nil && version?.document != nil }, perform: copyTranscript),
            .playPause: .init(enabled: { !recorder.locked && playback.canPlay }, perform: playback.toggle),
            .backward: .init(enabled: { !recorder.locked && playback.canPlay }, perform: { playback.seek(playback.position - 10) }),
            .forward: .init(enabled: { !recorder.locked && playback.canPlay }, perform: { playback.seek(playback.position + 10) })
        ]).frame(width: 0, height: 0))
        .onAppear {
            if selectedSummary == nil { selectedSummary = showingSummary }
            playback.select(recording)
            selectMatchingVersion()
        }
        .task(id: suggestionRequest) { await loadSpeakerSuggestions() }
        .onReceive(NotificationCenter.default.publisher(for: VoiceProfiles.changed)) { _ in voiceRevision += 1 }
        .onReceive(recorder.calendar.$directory.removeDuplicates().dropFirst()) { _ in voiceRevision += 1 }
        .sheet(isPresented: $reviewingSpeakers) {
            if let version, let audio = recording.tracks.first(where: { $0.source == .system }) {
                SpeakerReviewSheet(recording: recording, version: version, audio: audio.url, library: library, calendar: recorder.calendar)
            }
        }
        .sheet(isPresented: $showingAttendance) { AttendanceEditor(recording: recording, version: version, library: library) }
        .onChange(of: library.filter) { previous, current in
            if previous == .needsSummary || current == .needsSummary { selectedSummary = nil }
        }
        .onChange(of: query) { _, query in
            if query.isEmpty && library.filter == .needsSummary { selectedSummary = nil }
            selectMatchingVersion()
        }
        .onChange(of: library.searchHits[recording.id]?.summaryMatch) { _, _ in selectMatchingVersion() }
        .onChange(of: library.searchHits[recording.id]?.versionID) { _, _ in selectMatchingVersion() }
        .onChange(of: recording.transcripts.map(\.id)) { _, _ in versionID = nil; selectMatchingVersion() }
        .onChange(of: draft?.version.id) { _, _ in selectMatchingVersion() }
        .onChange(of: library.summaryDrafts[recording.id]?.id) { _, new in if new != nil { showingSummary = true } }
    }
    private func beginEditing(paragraph: Int? = nil) {
        showingSummary = false
        if let version { library.beginTranscriptEditing(recording, version: version, paragraph: paragraph) }
    }
    private func copyTranscript() {
        guard let version, let text = recording.readableText(for: version, suggestions: pendingSpeakerNames) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func loadSpeakerSuggestions() async {
        guard let version else { return }
        let request = suggestionRequest, directory = recorder.calendar.directory
        let matches = await Task.detached(priority: .utility) { [recording] in
            version.currentSpeakerSuggestions(for: recording, directory: directory)
        }.value
        guard !Task.isCancelled, suggestionRequest == request else { return }
        loadedSuggestions = (request, matches)
    }
    private func selectMatchingVersion() {
        guard draft == nil, library.summaryDrafts[recording.id] == nil else { return }
        if !query.isEmpty { showingSummary = library.searchHits[recording.id]?.summaryMatch == true }
        if let preferred = library.preferredTranscriptID, recording.transcripts.contains(where: { $0.id == preferred }) {
            versionID = preferred; library.preferredTranscriptID = nil; return
        }
        guard !query.isEmpty else { versionID = recording.latestTranscript?.id; return }
        versionID = library.searchHits[recording.id]?.versionID ?? recording.latestTranscript?.id
    }
}

struct ReadableTranscript: View {
    let paragraphs: [TranscriptParagraph]
    let edited: Bool
    let query: String
    let playback: RecordingPlayback
    @State private var playbackReady = false
    @FocusState private var focusedParagraph: Int?
    let playbackDisabled: Bool
    let draft: TranscriptDraft?
    let canEdit: Bool
    let editParagraph: (Int) -> Void
    let participants: [String]
    let automaticParticipant: String?
    var participantNames: [String: String] = [:]
    var displayNames: [String: String] = [:]
    var speakerSuggestions: [String: String] = [:]
    var assignGroup: ((String, String, Int) -> Void)? = nil
    var assignment: ParticipantAssignmentStatus? = nil
    let assignParticipant: (String?, Int) -> Void
    let editParticipants: () -> Void
    var searchMatches: [Int] = []
    private var firstMatch: Int? {
        if let match = searchMatches.first(where: { id in paragraphs.contains { $0.id == id } }) { return match }
        guard !query.isEmpty else { return nil }
        let parsed = LibrarySearchQuery(query)
        let automaticName = automaticParticipant.map { displayNames[$0] ?? $0 }
        let names = participantNames.mapValues { displayNames[$0] ?? $0 }
        return paragraphs.first {
            !parsed.highlightRanges(in: $0.text).isEmpty ||
                !parsed.highlightRanges(in: $0.speakerLabel(automaticParticipant: automaticName, participantNames: names)).isEmpty
        }?.id
    }
    var body: some View {
        if paragraphs.isEmpty {
            ContentUnavailableView(edited ? "Transcript is empty" : "No speech detected", systemImage: "waveform",
                                   description: Text(edited ? "This edited version has no text. Choose another version or transcribe the recording again." : "You can listen to the audio or try another transcription model."))
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(paragraphs) { paragraph in
                        paragraphRow(paragraph)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets(top: 13, leading: 28, bottom: 13, trailing: 28))
                            .listRowSeparator(.hidden)
                    }
                    Text("“\(TranscriptSource.microphone.label)” follows the microphone track. Other speaker names use the call’s participant assignments.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 13, leading: 28, bottom: 28, trailing: 28))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .onReceive(playback.$availability.removeDuplicates()) { playbackReady = $0 != .empty }
                .onAppear { if draft == nil, let firstMatch { proxy.scrollTo(firstMatch, anchor: .top) } }
                .onChange(of: query) { _, _ in if draft == nil, let firstMatch { proxy.scrollTo(firstMatch, anchor: .top) } }
                .onChange(of: searchMatches) { _, _ in if draft == nil, let firstMatch { proxy.scrollTo(firstMatch, anchor: .top) } }
                .task(id: draft.map(ObjectIdentifier.init)) {
                    guard let target = draft?.focusedParagraph else { return }
                    proxy.scrollTo(target)
                    await Task.yield()
                    if !Task.isCancelled { focusedParagraph = target }
                }
            }
        }
    }

    private func paragraphRow(_ paragraph: TranscriptParagraph) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Circle().fill(paragraph.source == .microphone ? Color.accentColor : .secondary).frame(width: 7, height: 7)
                if paragraph.source == .system {
                    if let draft {
                        DraftParticipantPicker(paragraph: paragraph, draft: draft, participants: participants, automaticParticipant: automaticParticipant, displayNames: displayNames,
                                               assign: { assignParticipant($0, paragraph.id) }, editParticipants: editParticipants)
                            .disabled(!canEdit)
                    } else {
                        let group = paragraph.segments.first?.speakerGroup
                        ParticipantPicker(participant: paragraph.participant.map { participantNames[$0] ?? $0 }, participants: participants, automaticParticipant: automaticParticipant, displayNames: displayNames, speakerGroup: group,
                                          suggestedParticipant: group.flatMap { speakerSuggestions[$0] },
                                          assignGroup: assignGroup.map { action in { group, name in action(group, name, paragraph.id) } }, start: paragraph.start,
                                          assign: { assignParticipant($0, paragraph.id) }, editParticipants: editParticipants)
                            .disabled(!canEdit)
                    }
                } else { Text(paragraph.source.label).font(.callout.weight(.semibold)) }
                if assignment?.paragraph == paragraph.id, assignment?.error == nil {
                    ProgressView().controlSize(.small).help("Saving speaker…").accessibilityLabel("Saving speaker")
                }
                Button(Transcript.timestamp(paragraph.start)) {
                    playback.seek(paragraph.start); playback.play()
                }.buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .disabled(playbackDisabled || !playbackReady)
                    .help("Play from \(Transcript.timestamp(paragraph.start))")
                    .accessibilityLabel("Play from \(Transcript.timestamp(paragraph.start))")
                Spacer()
                ParagraphPlaybackIndicator(playback: playback, start: paragraph.start, end: paragraph.end)
                if draft == nil {
                    Button { editParagraph(paragraph.id) } label: { Image(systemName: "pencil").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!canEdit)
                        .help("Edit this paragraph").accessibilityLabel("Edit paragraph at \(Transcript.timestamp(paragraph.start))")
                }
            }
            if assignment?.paragraph == paragraph.id, let error = assignment?.error {
                Text("Couldn’t save speaker: \(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let draft {
                InlineParagraphEditor(paragraph: paragraph, draft: draft, focusedParagraph: $focusedParagraph)
            } else {
                Text(highlighted(paragraph.text)).font(.system(size: 15)).lineSpacing(5)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }
        let result = NSMutableAttributedString(string: text)
        for range in LibrarySearchQuery(query).highlightRanges(in: text) {
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
        }
        return AttributedString(result)
    }
}

private struct ParagraphPlaybackIndicator: View {
    let playback: RecordingPlayback
    let start: Double
    let end: Double
    @State private var active = false

    var body: some View {
        Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor)
            .opacity(active ? 1 : 0).accessibilityLabel("Playing").accessibilityHidden(!active)
            .onReceive(playback.$playing.combineLatest(playback.$position)
                .map { playing, position in playing && start <= position && position < end }
                .removeDuplicates()) { active = $0 }
    }
}

private struct PlaybackBar: View {
    let recording: LibraryRecording
    @ObservedObject var playback: RecordingPlayback
    let disabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if disabled { Text("Playback is paused while recording or testing audio.").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.wantsPlayback ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                }.buttonStyle(.plain).accessibilityLabel(playback.wantsPlayback ? "Pause playback" : "Play recording")
                    .help("Play / pause (Space)")
                    .disabled(disabled || !playback.canPlay)
                Text(Transcript.timestamp(playback.position)).font(.caption.monospacedDigit()).frame(width: 60)
                Slider(value: Binding(get: { min(playback.position, playback.duration) }, set: playback.seek), in: 0...max(0.01, playback.duration))
                    .accessibilityLabel("Playback position").disabled(disabled || !playback.canPlay || playback.duration == 0)
                Text(Transcript.timestamp(playback.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60)
            }
            HStack {
                Picker("Audio", selection: Binding(get: { playback.source }, set: { playback.changeTrack($0, in: recording) })) {
                    ForEach(recording.tracks) { Text($0.label).tag($0.source) }
                }.labelsHidden().frame(maxWidth: 180).disabled(disabled)
                Spacer()
                Text("Click a transcript timestamp to listen").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(.bar)
    }
}

private struct TranscriptionActivity: View {
    @ObservedObject var transcription: TranscriptionCoordinator
    var body: some View {
        if let status = transcription.status {
            VStack(alignment: .leading, spacing: 8) {
                if transcription.busy {
                    Text(transcription.recordingName ?? "Transcribing").font(.caption.weight(.medium)).lineLimit(2)
                    if let fraction = transcription.fraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                if transcription.busy { Button("Cancel transcription") { transcription.cancel() }.font(.caption) }
            }
            Divider()
        }
    }
}
