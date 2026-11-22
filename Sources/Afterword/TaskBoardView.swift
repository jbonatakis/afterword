import SwiftUI
import AppKit
import RecorderCore

@MainActor private final class BoardWorkspace: ObservableObject {
    let store: TaskBoardStore
    @Published private(set) var board: TaskBoard?
    @Published private(set) var saving = false
    @Published var error: String?
    @Published var drafts: [String: TicketDraft] = [:]

    init(store: TaskBoardStore) { self.store = store }

    private func display(_ snapshot: TaskBoard) {
        if snapshot.revision >= (board?.revision ?? 0) { board = snapshot }
    }

    func refresh() async {
        do { display(try await Task.detached(priority: .userInitiated) { [store] in try store.read() }.value) }
        catch { self.error = error.localizedDescription }
    }

    func watch(afterRefresh: () -> Void = {}) async {
        do {
            let updates = try await Task.detached(priority: .userInitiated) { [store] in try store.updates() }.value
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await refresh()
                if !Task.isCancelled { afterRefresh() }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func save(_ ticket: BoardTicket, original: BoardTicket?) async throws {
        saving = true
        defer { saving = false }
        let snapshot = try await Task.detached(priority: .userInitiated) { [store] in try store.save(ticket, original: original) }.value
        display(snapshot)
        error = nil
    }

    func edit(revision: Int, _ change: @escaping @Sendable (inout TaskBoard) throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            let next = try await Task.detached(priority: .userInitiated) { [store] in
                try store.change(expectedRevision: revision, change)
            }.value
            display(next)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            await refresh()
            return false
        }
    }
}

@Observable private final class TicketDraft: Identifiable {
    var ticket: BoardTicket
    var original: BoardTicket
    var conflicts: [BoardTicketField] = []
    var issue: String?
    let isNew: Bool
    var id: String { ticket.id }

    init(ticket: BoardTicket, isNew: Bool) {
        self.ticket = ticket
        self.original = ticket
        self.isNew = isNew
    }
}

private struct TicketSearchField: NSViewRepresentable {
    @Binding var text: String
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(_ text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search tickets"
        field.setAccessibilityLabel("Search tickets")
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }
}

private actor BoardSearchWorker {
    private let index = BoardTicketSearch()
    func results(on board: TaskBoard, for query: BoardTicketQuery) throws -> [BoardTicketHit] {
        try index.results(on: board, for: query)
    }
}

private struct TicketPaneDivider: NSViewRepresentable {
    let width: CGFloat
    let setWidth: (CGFloat) -> Void

    final class Handle: NSView {
        var width: CGFloat = 0
        var setWidth: (CGFloat) -> Void = { _ in }
        private var startX: CGFloat = 0
        private var startWidth: CGFloat = 0

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            startWidth = width
        }
        override func mouseDragged(with event: NSEvent) {
            let delta = event.locationInWindow.x - startX
            setWidth(startWidth + (userInterfaceLayoutDirection == .rightToLeft ? delta : -delta))
        }
        override func accessibilityPerformIncrement() -> Bool { setWidth(width + 20); return true }
        override func accessibilityPerformDecrement() -> Bool { setWidth(width - 20); return true }
    }

    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        handle.setAccessibilityElement(true)
        handle.setAccessibilityRole(.splitter)
        handle.setAccessibilityLabel("Ticket pane width")
        return handle
    }
    func updateNSView(_ handle: Handle, context: Context) {
        handle.width = width
        handle.setWidth = setWidth
        handle.setAccessibilityValue(NSNumber(value: Double(width)))
    }
}

struct TaskBoardView: View {
    @StateObject private var workspace: BoardWorkspace
    let library: RecordingLibraryModel
    @State private var selectedID: String?
    @State private var preferredPaneWidth: CGFloat = 420
    @Binding private var ticketSource: BoardReference?
    @State private var presentedTicket: TicketDraft?
    @State private var layout = false
    @State private var dropTarget: String?
    @State private var query = BoardTicketQuery()
    @State private var citationLabel = ""
    @State private var worker = BoardSearchWorker()
    @State private var hits: [BoardTicketHit] = []
    @State private var searchError: String?
    @State private var completedSearch: Request?

    private struct Request: Equatable {
        let revision: Int
        let query: BoardTicketQuery
    }

    private var searching: Bool { !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.citation != nil }

    init(library: RecordingLibraryModel, ticketSource: Binding<BoardReference?> = .constant(nil)) {
        self.library = library
        _workspace = StateObject(wrappedValue: BoardWorkspace(store: library.boardStore))
        _ticketSource = ticketSource
    }

    var body: some View {
        VStack(spacing: 0) {
            if let board = workspace.board {
                let request = Request(revision: board.revision, query: query)
                HStack {
                    if board.name != "Task board" { Text(board.name).font(.headline).lineLimit(1) }
                    TicketSearchField(text: $query.text).frame(minWidth: 110, idealWidth: 200, maxWidth: 260).frame(height: 24)
                    filterMenu(board)
                    Spacer()
                    if searching {
                        if completedSearch == request, searchError == nil {
                            Text(hits.count == 1 ? "1 match" : "\(hits.count) matches").foregroundStyle(.secondary)
                        }
                    } else {
                        let count = query.columnID == nil && query.swimlaneID == nil ? board.tickets.count : board.tickets.filter(query.includesCell).count
                        Text(count == 1 ? "1 ticket" : "\(count) tickets").foregroundStyle(.secondary)
                    }
                    Button { layout = true } label: { Label("Edit layout", systemImage: "slider.horizontal.3") }
                    Button { newTicket(on: board) } label: {
                        Label("New ticket", systemImage: "plus")
                    }.buttonStyle(.borderedProminent)
                }.padding()
                if query.citation != nil {
                    HStack {
                        Label(citationLabel, systemImage: "link")
                        Button { query.citation = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear citation filter")
                        Spacer()
                    }.font(.callout).padding(.horizontal).padding(.bottom, 8)
                }
                Divider()
                GeometryReader { bounds in
                    ZStack {
                        if searching { searchResults(board, request: request) }
                        else { grid(board) }
                    }
                    .frame(width: bounds.size.width, height: bounds.size.height)
                    .overlay(alignment: .trailing) {
                        if let id = selectedID { ticketPane(id, availableWidth: bounds.size.width) }
                    }
                    .clipped()
                }
                .task(id: request) {
                    guard searching else { completedSearch = nil; hits = []; return }
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                        let matches = try await worker.results(on: board, for: request.query)
                        try Task.checkCancellation()
                        hits = matches
                        searchError = nil
                    } catch {
                        guard !Task.isCancelled else { return }
                        hits = []
                        searchError = error.localizedDescription
                    }
                    completedSearch = request
                }
                .onChange(of: board.revision) { _, _ in
                    if let id = query.columnID, !board.columns.contains(where: { $0.id == id }) { query.columnID = nil }
                    if let id = query.swimlaneID, !id.isEmpty, !board.swimlanes.contains(where: { $0.id == id }) { query.swimlaneID = nil }
                }
            } else if workspace.error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = workspace.error, presentedTicket == nil && !layout {
                HStack {
                    Text(error).foregroundStyle(.secondary)
                    Button("Reload") { workspace.error = nil; Task { await workspace.refresh() } }
                }.padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await workspace.watch {
                if let source = ticketSource, let board = workspace.board {
                    ticketSource = nil
                    newTicket(on: board, references: [source])
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await workspace.refresh() } }
        .sheet(item: $presentedTicket) { draft in
            BoardTicketEditor(workspace: workspace, library: library, draft: draft) { presentedTicket = nil }
                .frame(width: 480)
        }
        .sheet(isPresented: $layout) { BoardLayoutEditor(workspace: workspace) }
    }

    private func ticketPane(_ id: String, availableWidth: CGFloat) -> some View {
        let minimum = min(300, availableWidth)
        let maximum = max(minimum, availableWidth - 160)
        func clamped(_ width: CGFloat) -> CGFloat { min(maximum, max(minimum, width)) }
        let width = clamped(preferredPaneWidth)
        return BoardTicketReader(workspace: workspace, library: library, ticketID: id,
                                 findCitingTickets: { reference in
                                     query = BoardTicketQuery()
                                     query.citation = .init(source: reference.source, itemID: reference.itemID)
                                     citationLabel = reference.label
                                 },
                                 openWindow: { library.boardWindows.open(id: id, library: library) },
                                 close: { selectedID = nil })
            .id(id)
            .frame(width: width)
            .clipped()
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .shadow(color: .black.opacity(0.16), radius: 5, x: 0, y: 1)
            }
            .overlay(alignment: .leading) {
                TicketPaneDivider(width: width) { preferredPaneWidth = clamped($0) }
                    .frame(width: 8)
                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1).allowsHitTesting(false) }
            }
    }

    private func filterMenu(_ board: TaskBoard) -> some View {
        Menu {
            Picker("Column", selection: $query.columnID) {
                Text("All columns").tag(String?.none)
                ForEach(board.columns) { Text($0.name).tag(Optional($0.id)) }
            }
            if !board.swimlanes.isEmpty {
                Picker("Swimlane", selection: $query.swimlaneID) {
                    Text("All swimlanes").tag(String?.none)
                    Text("Unassigned").tag(Optional(""))
                    ForEach(board.swimlanes) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if query.columnID != nil || query.swimlaneID != nil || query.citation != nil {
                Divider()
                Button("Clear filters") { query.columnID = nil; query.swimlaneID = nil; query.citation = nil }
            }
        } label: {
            let filtered = query.columnID != nil || query.swimlaneID != nil || query.citation != nil
            Label("Filter tickets", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }.labelStyle(.iconOnly).fixedSize().help("Filter tickets")
    }

    @ViewBuilder private func searchResults(_ board: TaskBoard, request: Request) -> some View {
        if completedSearch != request { ProgressView() }
        else if let searchError {
            ContentUnavailableView("Ticket search unavailable", systemImage: "magnifyingglass", description: Text(searchError))
        } else if hits.isEmpty {
            ContentUnavailableView("No matching tickets", systemImage: "magnifyingglass")
        } else {
            List(hits, selection: $selectedID) { hit in
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.ticket.title).font(.headline)
                    let column = board.columns.first { $0.id == hit.ticket.columnID }?.name
                    let lane = board.swimlanes.first { $0.id == hit.ticket.swimlaneID }?.name
                    Text([column, lane].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if let match = hit.match, match.field != .title || match.excerpt != hit.ticket.title {
                        Label(match.excerpt, systemImage: match.field == .citation ? "link" : "text.alignleft").lineLimit(2)
                    }
                    if let reference = hit.sharedReference { Label(reference.label, systemImage: "link").font(.caption) }
                }.padding(.vertical, 4).tag(hit.id)
            }.listStyle(.inset)
        }
    }

    private func grid(_ board: TaskBoard) -> some View {
        GeometryReader { geometry in
            let columns = board.columns.filter { query.columnID == nil || $0.id == query.columnID }
            let count = CGFloat(max(1, columns.count))
            let width = max(210, min(360, (geometry.size.width - 32 - (count - 1) * 12) / count))
            let cells = Dictionary(grouping: board.tickets, by: { Cell(column: $0.columnID, lane: $0.swimlaneID) })
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ForEach(columns) { column in
                            Text(column.name).font(.headline).lineLimit(2)
                                .frame(width: width, alignment: .leading)
                        }
                    }
                    if query.swimlaneID == nil || query.swimlaneID == "" {
                        lane(nil, board: board, columns: columns, width: width, cells: cells)
                    }
                    ForEach(board.swimlanes.filter { query.swimlaneID == nil || $0.id == query.swimlaneID }) { group in
                        lane(group, board: board, columns: columns, width: width, cells: cells)
                    }
                }.padding(16)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private struct Cell: Hashable { let column: String; let lane: String? }

    private func newTicket(on board: TaskBoard, references: [BoardReference] = []) {
        let column = board.columns.first { $0.id == query.columnID } ?? board.columns[0]
        let lane = board.swimlanes.first { $0.id == query.swimlaneID }
        let ticket = BoardTicket(title: "", columnID: column.id, swimlaneID: lane?.id, references: references)
        presentedTicket = TicketDraft(ticket: ticket, isNew: true)
    }

    @ViewBuilder private func lane(_ lane: BoardGroup?, board: TaskBoard, columns: [BoardGroup], width: CGFloat, cells: [Cell: [BoardTicket]]) -> some View {
        if !board.swimlanes.isEmpty {
            Text(lane?.name ?? "Unassigned").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        HStack(alignment: .top, spacing: 12) {
            ForEach(columns) { column in
                let tickets = cells[Cell(column: column.id, lane: lane?.id)] ?? []
                let key = column.id + "/" + (lane?.id ?? "")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tickets) { ticket in
                        Button { selectedID = ticket.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ticket.title).font(.body.weight(.medium)).lineLimit(3)
                                if !ticket.notes.isEmpty {
                                    Text(ticket.notes).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if let ref = ticket.references.first {
                                    Label(ref.label, systemImage: "link").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        .overlay {
                            if selectedID == ticket.id { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
                        }
                        .accessibilityAddTraits(selectedID == ticket.id ? .isSelected : [])
                        .accessibilityLabel(ticket.title)
                        .draggable(ticket.id)
                        .contextMenu {
                            ForEach([(-1, "Move up"), (1, "Move down")], id: \.0) { step, title in
                                let index = (tickets.firstIndex { $0.id == ticket.id } ?? 0) + step
                                Button(title) {
                                    Task { _ = await workspace.edit(revision: board.revision) { _ = try $0.saveTicket(ticket, position: index) } }
                                }.disabled(!tickets.indices.contains(index))
                            }
                        }
                    }
                }
                .padding(8).frame(width: width, alignment: .topLeading)
                .frame(minHeight: 90, alignment: .topLeading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .overlay { if dropTarget == key { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2) } }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, let ticket = try? board.ticket(id) else { return false }
                    Task {
                        _ = await workspace.edit(revision: board.revision) { snapshot in
                            var moved = ticket
                            moved.columnID = column.id
                            moved.swimlaneID = lane?.id
                            _ = try snapshot.saveTicket(moved)
                        }
                    }
                    return true
                } isTargeted: { over in
                    if over { dropTarget = key } else if dropTarget == key { dropTarget = nil }
                }
            }
        }
    }
}

@MainActor final class BoardWindows: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var boardWindow: NSWindow?

    func openBoard(library: RecordingLibraryModel) {
        guard library.sources.contains(.board) else { return }
        if let boardWindow {
            if boardWindow.isMiniaturized { boardWindow.deminiaturize(nil) }
            boardWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = LibraryCommandWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 700),
                                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = LibraryPage.board.title
        window.minSize = NSSize(width: 660, height: 380)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: TaskBoardView(library: library))
        window.center()
        boardWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func open(id: String, library: RecordingLibraryModel) {
        guard library.sources.contains(.board) else { return }
        if let existing = windows[id] {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Ticket"
        window.minSize = NSSize(width: 350, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: TicketWindowContent(id: id, library: library) { [weak window] title in
            window?.title = title
        })
        window.center()
        if let front = NSApp.keyWindow { window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)) }
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === boardWindow { boardWindow = nil }
        else { windows = windows.filter { $0.value !== window } }
    }

    func closeAll() {
        boardWindow?.close()
        for window in Array(windows.values) { window.close() }
    }
}

private struct TicketWindowContent: View {
    let id: String
    let library: RecordingLibraryModel
    let setTitle: (String) -> Void
    @StateObject private var workspace: BoardWorkspace

    init(id: String, library: RecordingLibraryModel, setTitle: @escaping (String) -> Void) {
        self.id = id
        self.library = library
        self.setTitle = setTitle
        _workspace = StateObject(wrappedValue: BoardWorkspace(store: library.boardStore))
    }

    var body: some View {
        BoardTicketReader(workspace: workspace, library: library, ticketID: id)
            .task { await workspace.watch() }
            .onChange(of: workspace.board?.tickets.first { $0.id == id }?.title, initial: true) { _, title in
                setTitle(title ?? "Ticket")
            }
    }
}

private struct BoardTicketReader: View {
    @ObservedObject var workspace: BoardWorkspace
    let library: RecordingLibraryModel
    let ticketID: String
    var findCitingTickets: ((BoardReference) -> Void)?
    var openWindow: (() -> Void)?
    var close: (() -> Void)?
    @State private var citation: BoardReference?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = workspace.drafts[ticketID] {
                BoardTicketEditor(workspace: workspace, library: library, draft: draft) { workspace.drafts[ticketID] = nil }
            } else if let citation {
                Button { self.citation = nil } label: { Label("Back to ticket", systemImage: "chevron.left") }
                    .padding(12)
                Divider()
                BoardCitationView(reference: citation, library: library)
            } else {
                let board = workspace.board
                let ticket = board?.tickets.first { $0.id == ticketID }
                HStack(spacing: 10) {
                    if let openWindow {
                        Button(action: openWindow) { Label("Open in separate window", systemImage: "macwindow.on.rectangle") }
                            .help("Open this ticket in a separate window")
                    }
                    Spacer()
                    if let ticket {
                        Button("Edit") { workspace.drafts[ticketID] = TicketDraft(ticket: ticket, isNew: false) }
                            .keyboardShortcut("e", modifiers: .command)
                    }
                    if let close {
                        Button(action: close) { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel("Close ticket details").help("Close ticket details")
                    }
                }.padding(12)
                Divider()
                if let board, let ticket {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(ticket.title).font(.title2.bold()).textSelection(.enabled)
                            HStack(alignment: .top, spacing: 16) {
                                if let column = board.columns.first(where: { $0.id == ticket.columnID }) {
                                    Label(column.name, systemImage: "rectangle.split.3x1").accessibilityLabel("Column, \(column.name)")
                                }
                                if !board.swimlanes.isEmpty {
                                    let lane = board.swimlanes.first { $0.id == ticket.swimlaneID }?.name ?? "Unassigned"
                                    Label(lane, systemImage: "rectangle.split.1x2").accessibilityLabel("Swimlane, \(lane)")
                                }
                            }.font(.callout).foregroundStyle(.secondary)
                            if !ticket.notes.isEmpty { MarkdownContent(markdown: ticket.notes) }
                            if !ticket.references.isEmpty {
                                Divider()
                                Text("Sources").font(.headline)
                                BoardTicketReferences(references: ticket.references, findCitingTickets: findCitingTickets) { citation = $0 }
                            }
                        }.frame(maxWidth: 700, alignment: .leading).padding(20).frame(maxWidth: .infinity)
                    }
                } else if let error = workspace.error {
                    ContentUnavailableView("Ticket unavailable", systemImage: "exclamationmark.circle", description: Text(error))
                } else if board == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Ticket deleted", systemImage: "rectangle.slash")
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
            .onDisappear {
                if let draft = workspace.drafts[ticketID], draft.ticket == draft.original, draft.conflicts.isEmpty {
                    workspace.drafts[ticketID] = nil
                }
            }
    }
}

private struct BoardTicketReferences: View {
    let references: [BoardReference]
    var findCitingTickets: ((BoardReference) -> Void)?
    let open: (BoardReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(references.enumerated()), id: \.offset) { _, ref in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button { open(ref) } label: { Label(ref.label, systemImage: "link") }
                            .buttonStyle(.link).help("Open cited source")
                        if let findCitingTickets {
                            Button { findCitingTickets(ref) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).accessibilityLabel("Find tickets citing this source").help("Find tickets citing this source")
                        }
                    }
                    if let quote = ref.quote, !quote.isEmpty { Text(quote).font(.callout).textSelection(.enabled) }
                    DisclosureGroup("Reference details") {
                        Text([ref.source.rawValue, ref.itemID, ref.versionID, ref.anchor].compactMap { $0 }.joined(separator: " · ")).textSelection(.enabled)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BoardTicketEditor: View {
    @ObservedObject var workspace: BoardWorkspace
    let library: RecordingLibraryModel
    @Bindable var draft: TicketDraft
    let finish: () -> Void
    @State private var confirmingDelete = false
    @State private var citation: BoardReference?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.conflicts.isEmpty ? (draft.isNew ? "New ticket" : "Edit ticket") : "Resolve ticket changes").font(.title2.bold())
            if let field = draft.conflicts.first {
                Text("Both versions changed the " + field.rawValue.lowercased() + ". Choose which version to keep.")
                HStack(alignment: .top, spacing: 12) {
                    comparison("Saved on board", text: display(field, in: draft.original), button: "Use saved") {
                        field.copy(from: draft.original, to: &draft.ticket)
                        draft.conflicts.removeFirst()
                    }
                    comparison("Your draft", text: display(field, in: draft.ticket), button: "Keep my edit") {
                        draft.conflicts.removeFirst()
                    }
                }
            } else if draft.isNew { form.frame(maxHeight: 380).fixedSize(horizontal: false, vertical: true) }
            else { form }
            if let issue = draft.issue { Text(issue).foregroundStyle(.red).font(.callout) }
            HStack {
                if !draft.isNew && draft.conflicts.isEmpty { Button("Delete ticket…", role: .destructive) { confirmingDelete = true } }
                Spacer()
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create ticket" : "Save") { save() }
                    .keyboardShortcut(draft.isNew ? .defaultAction : KeyboardShortcut("s", modifiers: .command))
                    .disabled(!draft.conflicts.isEmpty || draft.ticket.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(draft.isNew ? 22 : 16).disabled(workspace.saving)
            .onAppear { titleFocused = true }
            .confirmationDialog("Delete this ticket?", isPresented: $confirmingDelete) {
                Button("Delete ticket", role: .destructive) {
                    guard let board = workspace.board else { return }
                    Task {
                        let expected = draft.original
                        if await workspace.edit(revision: board.revision, { snapshot in
                            guard try snapshot.ticket(expected.id) == expected else {
                                throw RecorderError.message("This ticket changed. Reopen the editor to review it before deleting.")
                            }
                            try snapshot.deleteTicket(expected.id)
                        }) { finish() }
                        else { draft.issue = workspace.error }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { citation != nil }, set: { if !$0 { citation = nil } })) {
                if let citation {
                    VStack {
                        BoardCitationView(reference: citation, library: library)
                        HStack { Spacer(); Button("Done") { self.citation = nil }.keyboardShortcut(.cancelAction) }.padding()
                    }.frame(width: 620, height: 460)
                }
            }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Ticket title", text: $draft.ticket.title).focused($titleFocused)
                if let board = workspace.board {
                    ViewThatFits(in: .horizontal) {
                        HStack { locationPickers(board) }.fixedSize()
                        VStack(alignment: .leading) { locationPickers(board) }
                    }
                }
                Text("Notes").font(.headline)
                TextEditor(text: $draft.ticket.notes).font(.body).frame(height: draft.isNew ? 135 : 200)
                    .border(.quaternary).accessibilityLabel("Notes")
                if !draft.ticket.references.isEmpty {
                    Text("Sources").font(.headline)
                    BoardTicketReferences(references: draft.ticket.references) { citation = $0 }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
        }
    }

    @ViewBuilder private func locationPickers(_ board: TaskBoard) -> some View {
        Picker("Column", selection: $draft.ticket.columnID) {
            ForEach(board.columns) { Text($0.name).tag($0.id) }
        }
        if !board.swimlanes.isEmpty {
            Picker("Swimlane", selection: $draft.ticket.swimlaneID) {
                Text("Unassigned").tag(String?.none)
                ForEach(board.swimlanes) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }

    private func comparison(_ heading: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            ScrollView {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(button, action: action)
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func display(_ field: BoardTicketField, in value: BoardTicket) -> String {
        switch field {
        case .column: return workspace.board?.columns.first { $0.id == value.columnID }?.name ?? value.columnID
        case .swimlane: return workspace.board?.swimlanes.first { $0.id == value.swimlaneID }?.name ?? value.swimlaneID ?? "Unassigned"
        default: return field.value(in: value).flatMap { $0.isEmpty ? nil : $0 } ?? "Empty"
        }
    }

    private func save() {
        Task {
            do {
                try await workspace.save(draft.ticket, original: draft.isNew ? nil : draft.original)
                finish()
            } catch let conflict as BoardTicketConflict {
                draft.original = conflict.latest
                draft.ticket = conflict.draft
                draft.conflicts = conflict.fields
                draft.issue = nil
                await workspace.refresh()
            } catch { draft.issue = error.localizedDescription; await workspace.refresh() }
        }
    }
}

private struct BoardLayoutEditor: View {
    @ObservedObject var workspace: BoardWorkspace
    @State private var axis: BoardAxis = .column
    @State private var groupName = ""
    @State private var editingGroup: BoardGroup?
    @State private var boardName = ""
    @State private var editRevision = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Board layout").font(.title2.bold())
            if let board = workspace.board {
                HStack {
                    TextField("Board name", text: $boardName)
                    Button("Rename board") {
                        let name = boardName
                        Task { _ = await workspace.edit(revision: editRevision) { try $0.rename(name) }; editRevision = workspace.board?.revision ?? editRevision }
                    }.disabled(boardName == board.name || boardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Picker("Organize", selection: $axis) {
                    Text("Columns").tag(BoardAxis.column)
                    Text("Swimlanes").tag(BoardAxis.swimlane)
                }.pickerStyle(.segmented).labelsHidden()
                let groups = board.groups(axis)
                List {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        HStack {
                            Text(group.name)
                            Spacer()
                            Button { editingGroup = group; groupName = group.name; editRevision = board.revision } label: { Image(systemName: "pencil") }.help("Rename group")
                            Button { move(group, to: index - 1, revision: board.revision) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move up")
                            Button { move(group, to: index + 1, revision: board.revision) } label: { Image(systemName: "arrow.down") }.disabled(index == groups.count - 1).help("Move down")
                            Button(role: .destructive) {
                                let kind = axis
                                Task { if await workspace.edit(revision: board.revision, { try $0.deleteGroup(kind, id: group.id) }) { reset() } }
                            } label: { Image(systemName: "trash") }.help("Delete empty group")
                        }.buttonStyle(.borderless)
                    }
                }.frame(height: 170)
                HStack {
                    TextField(axis == .column ? "Column name" : "Swimlane name", text: $groupName)
                    if editingGroup != nil { Button("Cancel rename") { reset() } }
                    Button(editingGroup == nil ? "Add" : "Rename") {
                        let name = groupName, id = editingGroup?.id, kind = axis
                        let revision = id == nil ? board.revision : editRevision
                        Task { if await workspace.edit(revision: revision, { _ = try $0.saveGroup(kind, id: id, name: name) }) { reset() } }
                    }.disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error = workspace.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.disabled(workspace.saving).padding(22).frame(width: 450)
            .onAppear { boardName = workspace.board?.name ?? ""; workspace.error = nil; reset() }
            .onChange(of: axis) { _, _ in reset() }
    }

    private func reset() {
        editingGroup = nil
        groupName = ""
        editRevision = workspace.board?.revision ?? 0
    }

    private func move(_ group: BoardGroup, to position: Int, revision: Int) {
        let kind = axis
        Task { if await workspace.edit(revision: revision, { _ = try $0.saveGroup(kind, id: group.id, name: group.name, position: position) }) { reset() } }
    }
}
