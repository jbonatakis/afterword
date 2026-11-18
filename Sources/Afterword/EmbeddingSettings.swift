import SwiftUI
import RecorderCore

@MainActor final class EmbeddingCoordinator: ObservableObject {
    @Published private(set) var settings: EmbeddingSettings
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: String?
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    let directory: URL
    var changed: (() -> Void)?
    private var task: Task<Void, Never>?
    private var operation: UUID?
    private let priority = EmbeddingPriority()
    init(directory: URL) {
        self.directory = directory
        settings = (try? EmbeddingSettings.load(directory: directory)) ?? .init()
        refreshModels()
    }
    func change(enabled: Bool? = nil, modelID: String? = nil) {
        var next = settings
        if let enabled { next.enabled = enabled }
        if let modelID { next.modelID = modelID }
        do { try next.save(directory: directory); settings = next; message = nil; changed?() }
        catch { message = error.localizedDescription }
    }
    func setBusy(_ busy: Bool) {
        do { try priority.setBusy(busy, directory: directory) }
        catch { message = error.localizedDescription }
    }
    func refreshModels() {
        installed = Set(EmbeddingModel.catalog.filter { FileManager.default.fileExists(atPath: ModelStore.ownedURL($0.asset, root: EmbeddingSettings.modelRoot(directory)).path) }.map(\.id))
    }
    func download(_ model: EmbeddingModel) {
        guard downloading == nil else { return }
        let id = UUID(); operation = id; downloading = model.id; progress = 0; message = nil
        task = Task {
            do {
                _ = try await ModelStore.download(model.asset, root: EmbeddingSettings.modelRoot(directory)) { [weak self] value in
                    Task { @MainActor in guard self?.operation == id else { return }; self?.progress = value }
                }
                message = "\(model.asset.name) is ready."
            } catch { message = Task.isCancelled ? "Download cancelled." : error.localizedDescription }
            operation = nil; downloading = nil; task = nil; refreshModels(); changed?()
        }
    }
    func cancelDownload() { task?.cancel() }
    func remove(_ model: EmbeddingModel) {
        guard downloading != model.id else { return }
        do { try ModelStore.remove(model.asset, root: EmbeddingSettings.modelRoot(directory)); refreshModels(); changed?() }
        catch { message = error.localizedDescription }
    }
    func shutdown() { task?.cancel(); try? priority.setBusy(false, directory: directory) }
}

struct EmbeddingSettingsView: View {
    @ObservedObject var library: RecordingLibraryModel
    @ObservedObject var embeddings: EmbeddingCoordinator
    var body: some View {
        Form {
            Section {
                Toggle("Semantic search", isOn: Binding(get: { embeddings.settings.enabled }, set: { embeddings.change(enabled: $0) }))
                Text("Find related ideas even when a transcript uses different words. Combines local semantic results with keyword search in the library and connected agents.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Search model", selection: Binding(get: { embeddings.settings.modelID }, set: { embeddings.change(modelID: $0) })) {
                    ForEach(EmbeddingModel.catalog) { Text($0.asset.name).tag($0.id) }
                }
                Text("Transcripts stay on your Mac. Downloads require internet; searching does not. Changing models builds a separate search index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Models") {
                ForEach(EmbeddingModel.catalog) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.asset.name).fontWeight(.medium)
                                Text("\(model.asset.detail) · \(model.asset.sizeLabel)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if embeddings.downloading == model.id {
                                Button("Cancel") { embeddings.cancelDownload() }
                            } else if embeddings.installed.contains(model.id) {
                                Button("Remove") { embeddings.remove(model) }
                            } else {
                                Button("Download") { embeddings.download(model) }.disabled(embeddings.downloading != nil)
                            }
                        }
                        if embeddings.downloading == model.id {
                            ProgressView(value: embeddings.progress)
                            Text(embeddings.progress == nil ? "Verifying download…" : "Downloading…").font(.caption)
                        }
                        Link("Model details & license", destination: model.asset.licenseURL).font(.caption)
                    }.padding(.vertical, 4)
                }
                if let message = embeddings.message { Text(message).font(.caption).textSelection(.enabled) }
            }
            Section("Search index") {
                LibraryIndexProgress(presentation: library.searchPresentation, showBar: true)
                Text("Indexing pauses while recording or transcribing. Participant names and speaker assignments always come from the current transcript.").font(.caption).foregroundStyle(.secondary)
                Button("Retry indexing") { library.retrySemanticSearch() }.disabled(!embeddings.settings.enabled)
            }
        }.formStyle(.grouped)
    }
}
