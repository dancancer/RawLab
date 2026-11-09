import AppKit
import Combine
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct MacPhotoPreviewPlan {
    static let edge = 256
    let record: PhotoEditRecord
    let look: URL?
    let key: PhotoPreviewCacheKey
    let resourceURLs: [URL]
    var url: URL { URL(fileURLWithPath: record.identity.path) }

    static func isEdited(_ record: PhotoEditRecord) -> Bool {
        guard let state = record.state else { return false }
        let raw = !RenderEngine.isRasterInput(URL(fileURLWithPath: record.identity.path))
        return EditorAdjustmentRules.isModified(scope: .all, snapshot: state,
            context: .init(isRaw: raw, defaultExposureMode: raw ? Adjustments().exposureMode : .sensor, neutralFilmID: ""))
    }

    init(record: PhotoEditRecord, films: [Film]) throws {
        self.record = record
        guard let state = record.state else { throw AdjustmentCommitError.expired }
        if state.settings.isHDREditing { look = nil }
        else if let recipeID = state.settings.masterRecipeID ?? state.masterRecipeID {
            guard let url = MasterRecipe.recipe(for: recipeID)?.lutURL() else { throw CocoaError(.fileNoSuchFile) }
            look = url
        } else if !state.filmID.isEmpty {
            guard let film = Film.independentRecipe(state.filmID) ?? films.first(where: {
                $0.id == state.filmID || $0.browserID == state.filmID
            }) else { throw CocoaError(.fileNoSuchFile) }
            look = film.url
        } else { look = nil }
        var resources = [URL]()
        if let look { resources.append(look) }
        if state.settings.isHDREditing, let hdr = state.settings.hdr {
            guard hdr.lookSettings.assetIsAvailable() else { throw CocoaError(.fileNoSuchFile) }
            if let asset = hdr.lookSettings.asset() { resources.append(asset) }
            if let profile = hdr.cameraDevelopmentSettings.cameraProfile {
                resources.append(try HDRCameraProfileAssetStore.url(for: profile))
            }
        }
        if state.settings.activeAIDenoise {
            guard let model = RenderEngine.bundledAIModel else { throw CocoaError(.fileNoSuchFile) }
            resources.append(model.appendingPathComponent("manifest.json"))
        }
        resourceURLs = resources
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // 包含资源内容，导入同名 LUT 或替换其内容时不能复用旧图。
        let fingerprints = try resources.map { url in
            let identity = try encoder.encode(OriginalFileIdentity(url))
            return identity + Data(SHA256.hash(data: try Data(contentsOf: url)))
        }
        key = PhotoPreviewCacheKey(identity: try encoder.encode(record.identity),
            adjustments: try encoder.encode(state), resources: try encoder.encode(fingerprints), edge: Self.edge)
    }

    func isCurrent(in store: EditPersistence, films: [Film]) throws -> Bool {
        guard try store.readState(for: url) == record else { return false }
        return try MacPhotoPreviewPlan(record: record, films: films).key == key
    }

    static func thumbnailData(_ image: CGImage, edge: Int = Self.edge) throws -> Data {
        let scale = min(1, Double(edge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let small = context.makeImage(), let destination = CGImageDestinationCreateWithData(data,
            UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, small, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

private struct MacAcceptedPhotoPreview {
    let key: PhotoPreviewCacheKey
    let data: Data
}

@MainActor final class MacEditedPhotoPreviews: ObservableObject {
    @Published private(set) var revision = 0
    @Published var isEditorBusy = false
    private let worker: MacPhotoPreviewWorker
    private let editDirectory: URL
    private let cache: EditedPhotoPreviewCache
    private var accepted: (record: PhotoEditRecord, task: Task<MacAcceptedPhotoPreview?, Never>)?
    private var watches: [URL: (source: DispatchSourceFileSystemObject?, readers: Int)] = [:]
    private var resourceWatches: [URL: Set<URL>] = [:]
    var films: [Film] = []

    init(editDirectory: URL, cacheDirectory: URL? = nil) {
        self.editDirectory = editDirectory
        cache = EditedPhotoPreviewCache(directory: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/EditedPhotoPreviews"))
        worker = MacPhotoPreviewWorker(editDirectory: editDirectory, cache: cache)
    }

    func refresh() { revision &+= 1 }
    func watch(_ url: URL) {
        if let watch = watches[url] { watches[url] = (watch.source, watch.readers + 1); return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { watches[url] = (nil, 1); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.refresh() } }
        source.setCancelHandler { close(descriptor) }
        watches[url] = (source, 1)
        source.resume()
    }
    func unwatch(_ url: URL) {
        if let watch = watches[url] {
            if watch.readers > 1 { watches[url] = (watch.source, watch.readers - 1); return }
            watch.source?.cancel(); watches.removeValue(forKey: url)
        }
        let resources = resourceWatches.removeValue(forKey: url) ?? []
        for resource in resources { unwatch(resource) }
    }
    func refreshWatch(_ url: URL) {
        let readers = watches[url]?.readers ?? 0
        watches.removeValue(forKey: url)?.source?.cancel()
        for _ in 0..<readers { watch(url) }
    }
    deinit { for watch in watches.values { watch.source?.cancel() } }
    func record(for url: URL) async throws -> PhotoEditRecord {
        let record = try await worker.record(for: url)
        let films = films
        let resources = await Task.detached(priority: .utility) {
            (try? MacPhotoPreviewPlan(record: record, films: films).resourceURLs) ?? []
        }.value
        try Task.checkCancellation()
        let previous = resourceWatches[url] ?? []
        var candidates = resources
        if resources.isEmpty, let state = record.state, MacPhotoPreviewPlan.isEdited(record) {
            // 资源暂时缺失时仍监听其目录，恢复文件后继续更新可见缩略图。
            if let film = films.first(where: { $0.id == state.filmID || $0.browserID == state.filmID }) {
                candidates.append(film.url)
            } else if state.filmID.hasPrefix("/") { candidates.append(URL(fileURLWithPath: state.filmID)) }
            if let hdr = state.settings.hdr, state.settings.isHDREditing {
                if let asset = hdr.lookSettings.asset() { candidates.append(asset) }
                if hdr.cameraDevelopmentSettings.cameraProfile != nil { candidates.append(HDRCameraProfileAssetStore.directory) }
            }
        }
        var next = Set(candidates + candidates.map { $0.deletingLastPathComponent() } + [url.deletingLastPathComponent()])
        if resources.isEmpty, MacPhotoPreviewPlan.isEdited(record) { next.formUnion(previous) }
        for removed in previous.subtracting(next) { unwatch(removed) }
        for added in next.subtracting(previous) { watch(added) }
        for retained in next.intersection(previous) { refreshWatch(retained) }
        resourceWatches[url] = next
        return record
    }
    func image(for record: PhotoEditRecord) async throws -> NSImage {
        var cached: Data?
        if let accepted, accepted.record == record, let ready = await accepted.task.value {
            let films = films, directory = editDirectory
            let current = await Task.detached(priority: .utility) {
                guard let store = try? EditPersistence(directory: directory),
                      let plan = try? MacPhotoPreviewPlan(record: record, films: films) else { return false }
                return plan.key == ready.key && (try? plan.isCurrent(in: store, films: films)) == true
            }.value
            if current { cached = ready.data }
        }
        let data: Data
        if let cached { data = cached }
        else { data = try await worker.image(for: record, films: films) }
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }
    func accept(record: PhotoEditRecord, image: CGImage) {
        guard MacPhotoPreviewPlan.isEdited(record) else { return }
        let films = films, directory = editDirectory, cache = cache
        let task = Task.detached(priority: .utility) { () -> MacAcceptedPhotoPreview? in
            do {
                let store = try EditPersistence(directory: directory)
                let plan = try MacPhotoPreviewPlan(record: record, films: films)
                guard try plan.isCurrent(in: store, films: films) else { return nil }
                let data = try MacPhotoPreviewPlan.thumbnailData(image)
                guard try plan.isCurrent(in: store, films: films) else { return nil }
                try? cache.write(data, for: plan.key)
                return MacAcceptedPhotoPreview(key: plan.key, data: data)
            } catch { return nil }
        }
        accepted = (record, task)
        Task { [weak self] in if await task.value != nil { self?.refresh() } }
    }
}

// 独立会话串行显影；任务只来自仍显示的 tile，离屏或修订后的任务会取消。
private actor MacPhotoPreviewWorker {
    let editDirectory: URL
    let cache: EditedPhotoPreviewCache
    init(editDirectory: URL, cache: EditedPhotoPreviewCache) {
        self.editDirectory = editDirectory; self.cache = cache
    }
    func record(for url: URL) throws -> PhotoEditRecord {
        try Task.checkCancellation()
        return try EditPersistence(directory: editDirectory).readState(for: url)
    }
    func image(for record: PhotoEditRecord, films: [Film]) async throws -> Data {
        let progress = AIPreparation { _, _, _ in }
        return try await withTaskCancellationHandler {
            try render(record, films: films, progress: progress)
        } onCancel: { progress.cancel() }
    }
    private func render(_ record: PhotoEditRecord, films: [Film], progress: AIPreparation) throws -> Data {
        try Task.checkCancellation()
        let store = try EditPersistence(directory: editDirectory)
        let plan = try MacPhotoPreviewPlan(record: record, films: films)
        guard try plan.isCurrent(in: store, films: films) else { throw AdjustmentCommitError.expired }
        if let data = try? cache.read(plan.key), NSImage(data: data) != nil {
            try Task.checkCancellation()
            guard try plan.isCurrent(in: store, films: films) else { throw AdjustmentCommitError.expired }
            return data
        }
        guard let settings = record.state?.settings else { throw AdjustmentCommitError.expired }
        let engine = try RenderEngine()
        if settings.activeAIDenoise {
            try RenderEngine.validateAIInput(plan.url, settings: settings)
            try engine.prepareAI(plan.url, settings: settings, progress: progress)
        }
        try Task.checkCancellation()
        guard let frame = try engine.render(plan.url, settings: settings, lut: plan.look,
            edge: MacPhotoPreviewPlan.edge, viewportPreview: true) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        guard try plan.isCurrent(in: store, films: films) else { throw AdjustmentCommitError.expired }
        let data = try MacPhotoPreviewPlan.thumbnailData(frame.image)
        try? cache.write(data, for: plan.key)
        return data
    }
}
