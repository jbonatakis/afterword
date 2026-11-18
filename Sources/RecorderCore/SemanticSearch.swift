import Foundation

public struct SemanticSearchStatus: Encodable, Sendable, Equatable {
    public var enabled: Bool
    public var model: String
    public var state: String
    public var indexed: Int
    public var total: Int
    public var message: String
    public var mode: String = "keyword"
    public var complete: Bool { enabled && state == "ready" && indexed == total }
    private enum CodingKeys: String, CodingKey { case enabled, model, state, indexed, total, message, mode, coverage_complete }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled); try container.encode(model, forKey: .model)
        try container.encode(state, forKey: .state); try container.encode(indexed, forKey: .indexed)
        try container.encode(total, forKey: .total); try container.encode(message, forKey: .message)
        try container.encode(mode, forKey: .mode); try container.encode(complete, forKey: .coverage_complete)
    }
}
struct SemanticChunk: Sendable {
    enum Origin: Sendable {
        case call(id: String, version: String, paragraphs: [Int])
        case coding(session: String, message: String, timestamp: Date?, archived: Bool)
    }
    let origin: Origin
    let latest: Bool
    let text: String
    let hash: String
    init(origin: Origin, latest: Bool, text: String) {
        self.origin = origin; self.latest = latest; self.text = text
        hash = AgentJSON.hash(text)
    }
    var paragraphs: [Int] {
        if case .call(_, _, let ids) = origin { return ids }
        return []
    }
    var key: String {
        switch origin {
        case let .call(id, version, ids): return id + ":" + version + ":" + ids.map(String.init).joined(separator: ",") + ":" + hash
        case let .coding(session, message, _, _): return "coding:" + session + ":" + message + ":" + hash
        }
    }
}

enum SemanticChunker {
    static func chunks(_ call: AgentCall) -> [SemanticChunk] {
        guard call.recording.detailsError == nil else { return [] }
        return call.recording.transcripts.enumerated().flatMap { index, version -> [SemanticChunk] in
            let paragraphs = version.document?.paragraphs ?? []
            var groups: [(ids: [Int], text: String)] = []
            for paragraph in paragraphs {
                let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let last = groups.last, last.text.count < 160, last.ids.count < 3, last.text.count + text.count < 900 {
                    groups[groups.count - 1] = (last.ids + [paragraph.id], last.text + "\n\n" + text)
                } else { groups.append(([paragraph.id], text)) }
            }
            // Keep individual turns as well as short exchanges. Speaker-filtered
            // retrieval can then use only that person's speech, without attributing
            // a neighboring speaker's meaning to them.
            let groupedIDs = Set(groups.filter { $0.ids.count > 1 }.flatMap(\.ids))
            groups += paragraphs.filter { groupedIDs.contains($0.id) }.map { ([$0.id], $0.text) }
            return groups.flatMap { group in split(group.text).map {
                SemanticChunk(origin: .call(id: call.id, version: version.id, paragraphs: group.ids), latest: index == 0, text: $0)
            } }
        }
    }
    // Prefer complete sentences, with one sentence of overlap for long turns.
    // The native tokenizer provides the final 512-token bound for every language.
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            var remaining = text[range]
            while remaining.count > 900 {
                let end = remaining.index(remaining.startIndex, offsetBy: 900)
                let prefix = remaining[..<end]
                let boundary = prefix.lastIndex(where: { $0.isWhitespace }).flatMap { prefix.distance(from: prefix.startIndex, to: $0) > 450 ? $0 : nil } ?? end
                sentences.append(String(remaining[..<boundary])); remaining = remaining[boundary...]
            }
            if !remaining.isEmpty { sentences.append(String(remaining)) }
        }
        if sentences.isEmpty { return text.isEmpty ? [] : [text] }
        var result: [String] = [], current = "", previous = ""
        for sentence in sentences {
            if !current.isEmpty && current.count + sentence.count > 900 {
                result.append(current)
                current = previous.count <= 160 && previous.count + sentence.count <= 900 ? previous : ""
            }
            current += sentence; previous = sentence
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Only text hashes and vectors persist. Current source snapshots supply every
/// speaker, citation and permission decision. The cache is never authoritative.
final class SemanticSearchEngine: @unchecked Sendable {
    typealias Provider = ([String], EmbeddingModel, URL, () -> Bool) throws -> [[Float]]
    let directory: URL
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "io.local.afterword.embeddings", qos: .utility)
    private let provider: Provider
    private var chunks: [SemanticChunk] = []
    private var settings = EmbeddingSettings()
    private var signature = ""
    private var generation = UUID()
    private var working = false
    private var error: String?
    private var vectors: [String: [Float]] = [:]
    private var pending: [SemanticChunk] = []
    private var nextPending = 0
    private var cacheVersion: String?
    private var queries: [String: [Float]] = [:]
    private var database: SearchDatabase?
    init(directory: URL, provider: Provider? = nil) {
        self.directory = directory
        let runtime = EmbeddingRuntime()
        self.provider = provider ?? { try runtime.embed($0, model: $1, directory: $2, cancelled: $3) }
    }
    func refresh(_ calls: [AgentCall], codingArchive: CodingArchive? = nil) {
        lock.lock(); defer { lock.unlock() }
        do {
            let next = try EmbeddingSettings.load(directory: directory)
            let codingRevision = next.enabled ? try codingArchive?.revision : nil
            let nextSignature = (codingRevision ?? "") + next.model.cacheKey + ":\(next.enabled):" + calls.map { $0.id + $0.revision }.joined()
            if signature != nextSignature {
                generation = UUID(); error = nil
                if settings.modelID != next.modelID || !next.enabled { vectors = [:]; queries = [:]; database = nil }
                settings = next
                chunks = next.enabled ? calls.flatMap(SemanticChunker.chunks) + (try codingArchive?.embeddingChunks() ?? []) : []
                var needed = Set<String>()
                pending = (chunks.filter(\.latest) + chunks.filter { !$0.latest }).filter { needed.insert($0.hash).inserted }
                nextPending = 0
                vectors = vectors.filter { needed.contains($0.key) }
                cacheVersion = nil
                signature = nextSignature
            }
            guard settings.enabled else { return }
            guard FileManager.default.fileExists(atPath: ModelStore.ownedURL(settings.model.asset, root: EmbeddingSettings.modelRoot(directory)).path) else { return }
            if database == nil {
                try PrivateFiles.directory(directory)
                database = try SearchDatabase(url: directory.appendingPathComponent("Vectors-v1.sqlite"))
                try database?.execute("CREATE TABLE IF NOT EXISTS vectors (model TEXT, hash TEXT, vector TEXT, PRIMARY KEY(model, hash))")
            }
            // SQLite changes data_version only for commits from another connection.
            // Local batches already put their vectors in memory.
            if let database, let version = try database.rows("PRAGMA data_version").first?.first, cacheVersion != version {
                let missing = pending[nextPending...].compactMap { vectors[$0.hash] == nil ? $0.hash : nil }
                for start in stride(from: 0, to: missing.count, by: 256) {
                    let hashes = Array(missing[start..<min(start + 256, missing.count)])
                    let placeholders = Array(repeating: "?", count: hashes.count).joined(separator: ",")
                    for row in try database.rows("SELECT hash, vector FROM vectors WHERE model = ? AND hash IN (\(placeholders))", [settings.model.cacheKey] + hashes) {
                        if let data = row[1].data(using: .utf8), let vector = try? JSONDecoder().decode([Float].self, from: data), EmbeddingRuntime.valid(vector, dimensions: settings.model.dimensions) { vectors[row[0]] = vector }
                    }
                }
                cacheVersion = version
            }
            schedule()
        } catch { self.error = Self.describe(error) }
    }
    private func cancelled(_ token: UUID, model: EmbeddingModel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !Task.isCancelled, generation == token, let current = try? EmbeddingSettings.load(directory: directory), current.enabled, current.modelID == model.id else { return true }
        return !FileManager.default.fileExists(atPath: ModelStore.ownedURL(model.asset, root: EmbeddingSettings.modelRoot(directory)).path)
    }
    private func schedule() {
        guard !working, error == nil, settings.enabled, !EmbeddingPriority.isBusy(directory), !EmbeddingPriority.isBusy(directory, fileName: "query.lock") else { return }
        while nextPending < pending.count, vectors[pending[nextPending].hash] != nil { nextPending += 1 }
        // Advance past an item only once its vector is saved. Interrupted work stays eligible.
        let batch = Array(pending[nextPending...].lazy.filter { self.vectors[$0.hash] == nil }.prefix(24))
        guard !batch.isEmpty else { return }
        working = true
        let token = generation, model = settings.model
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.provider(batch.map(\.text), model, self.directory, { self.cancelled(token, model: model) || EmbeddingPriority.isBusy(self.directory, fileName: "query.lock") }) }
            self.lock.lock(); defer { self.lock.unlock() }
            self.working = false
            guard self.generation == token else { self.schedule(); return }
            switch result {
            case .success(let values):
                guard values.count == batch.count, values.allSatisfy({ EmbeddingRuntime.valid($0, dimensions: model.dimensions) }) else { self.error = "Invalid embedding response."; return }
                do {
                    try self.database?.execute("BEGIN IMMEDIATE")
                    for (chunk, vector) in zip(batch, values) {
                        let json = String(decoding: try JSONEncoder().encode(vector), as: UTF8.self)
                        try self.database?.execute("INSERT OR REPLACE INTO vectors VALUES (?, ?, ?)", [model.cacheKey, chunk.hash, json])
                    }
                    try self.database?.execute("COMMIT")
                    for (chunk, vector) in zip(batch, values) { self.vectors[chunk.hash] = vector }
                    self.schedule()
                } catch { try? self.database?.execute("ROLLBACK"); self.error = Self.describe(error) }
            case .failure(let error):
                if error is CancellationError { return }
                // A competing process is transient; retry on the next refresh.
                if !error.localizedDescription.contains("busy") { self.error = Self.describe(error) }
            }
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); signature = ""; settings.enabled = false
        chunks = []; pending = []; nextPending = 0; cacheVersion = nil; vectors = [:]; queries = [:]; database = nil
    }
    private static func describe(_ error: Error) -> String {
        error is RecorderError ? error.localizedDescription : "Search could not read its local data. Retry in Search settings."
    }
    func retry() { lock.lock(); defer { lock.unlock() }; error = nil; schedule() }
    private func status(indexed: Int, total: Int) -> SemanticSearchStatus {
        let model = settings.model
        var status = SemanticSearchStatus(enabled: settings.enabled, model: model.asset.name, state: "disabled", indexed: indexed, total: total, message: "Keyword search")
        if settings.enabled {
            if !FileManager.default.fileExists(atPath: ModelStore.ownedURL(model.asset, root: EmbeddingSettings.modelRoot(directory)).path) { status.state = "missing_model"; status.message = "Download \(model.asset.name) in Search settings." }
            else if let error { status.state = "error"; status.message = error }
            else if EmbeddingPriority.isBusy(directory) { status.state = "paused"; status.message = "Search indexing paused for recording or transcription." }
            else if indexed < total { status.state = "indexing"; status.message = "Indexed \(indexed) of \(total) passages. Semantic results may be incomplete." }
            else { status.state = "ready"; status.message = "Semantic search ready · \(indexed) passages" }
        }
        return status
    }
    func progress(allVersions: Bool) -> SemanticSearchStatus {
        lock.lock(); defer { lock.unlock() }
        var total = 0, indexed = 0
        for chunk in chunks where allVersions || chunk.latest {
            total += 1
            if vectors[chunk.hash] != nil { indexed += 1 }
        }
        return status(indexed: indexed, total: total)
    }
    func snapshot(allVersions: Bool) -> (SemanticSearchStatus, String) {
        lock.lock(); defer { lock.unlock() }
        let relevant = chunks.filter { allVersions || $0.latest }
        let ready = relevant.filter { vectors[$0.hash] != nil }
        let status = status(indexed: ready.count, total: relevant.count)
        return (status, AgentJSON.hash(settings.model.cacheKey + status.state + ready.map(\.key).sorted().joined()))
    }
    func search(_ text: String, allVersions: Bool) -> ([(SemanticChunk, Float)], SemanticSearchStatus, String) {
        lock.lock()
        let (initial, revision) = snapshot(allVersions: allVersions)
        let model = settings.model, token = generation
        let available = chunks.filter { (allVersions || $0.latest) && vectors[$0.hash] != nil }.map { ($0, vectors[$0.hash]!) }
        let cachedQuery = queries[text]
        lock.unlock()
        var status = initial
        guard status.enabled, !["disabled", "missing_model", "error", "paused"].contains(status.state), !available.isEmpty else { return ([], status, revision + ":keyword") }
        do {
            let query: [Float]
            if let cachedQuery { query = cachedQuery }
            else {
                let lease = EmbeddingPriority(fileName: "query.lock")
                try lease.setBusy(true, directory: directory)
                defer {
                    try? lease.setBusy(false, directory: directory)
                    lock.lock(); schedule(); lock.unlock()
                }
                // In-flight background helpers observe the query lease and exit.
                // Bounded retries avoid an app query fighting its own indexer.
                let deadline = Date().addingTimeInterval(2)
                var value: [Float]?
                while value == nil {
                    do { value = try provider([model.queryPrefix + text], model, directory, { self.cancelled(token, model: model) }).first }
                    catch {
                        guard error.localizedDescription.contains("busy"), Date() < deadline else { throw error }
                        Thread.sleep(forTimeInterval: 0.03)
                        continue
                    }
                    if value == nil { throw RecorderError.message("Invalid query embedding.") }
                }
                guard let vector = value, EmbeddingRuntime.valid(vector, dimensions: model.dimensions) else { throw RecorderError.message("Invalid query embedding.") }
                query = vector
                lock.lock()
                if queries.count >= 32 { queries.removeAll() }
                if generation == token { queries[text] = query }
                lock.unlock()
            }
            guard !cancelled(token, model: model) else { throw CancellationError() }
            var ranked: [(SemanticChunk, Float)] = []
            for (chunk, vector) in available {
                var score: Float = 0
                for i in query.indices { score += query[i] * vector[i] }
                // Report the margin above this model's retrieval floor. Independent title and
                // passage evidence can then be combined without counting the baseline twice.
                if score >= model.minimumSimilarity { ranked.append((chunk, score - model.minimumSimilarity)) }
            }
            ranked.sort { a, b in a.1 == b.1 ? a.0.key < b.0.key : a.1 > b.1 }
            status.mode = "hybrid"
            return (ranked, status, revision + ":hybrid")
        } catch {
            status.message = error is CancellationError ? "Semantic search paused; using keyword search." : Self.describe(error)
            return ([], status, revision + ":keyword")
        }
    }
}
