import RawLabKit
import Combine
import CryptoKit
import ImageIO
import UIKit

struct IOSPhotoPreviewSource {
    let identity: PhotoIdentity
    let file: PhotoSourceFile
    let displayName: String
    let isRaw: Bool
}

struct IOSPhotoPreviewPlan {
    static let edge = 320

    let source: IOSPhotoPreviewSource
    let record: PhotoEditRecord
    let look: URL?
    let settings: RawSettings
    private let sourceDigest: String
    private let core: PhotoPreviewPlan
    var key: PhotoPreviewCacheKey { core.key }

    static func isEdited(_ record: PhotoEditRecord, isRaw: Bool) -> Bool {
        guard let state = record.state else { return false }
        return EditorAdjustmentRules.isModified(.all, snapshot: state,
            context: .init(isRaw: isRaw, defaultExposureMode: isRaw ? RawSettings.default.exposureMode : .sensor))
    }

    init(source: IOSPhotoPreviewSource, record: PhotoEditRecord, look: URL?,
         digestCache: FileDigestCache = .shared) throws {
        self.source = source; self.record = record; self.look = look
        let state = try record.state ?? source.file.withReadAccess {
            PhotoEditState(settings: try Sony2FujiProcessor().defaultSettings(for: $0, isRaw: source.isRaw), updatedAt: Date(timeIntervalSince1970: 0))
        }
        settings = state.settings
        guard !state.settings.hasLook || state.settings.isHDREditing || look != nil else { throw CocoaError(.fileNoSuchFile) }
        let measured = try source.file.withReadAccess { try digestCache.digest(for: $0) }
        guard source.identity.contentIdentifier == nil || measured == source.identity.contentIdentifier else {
            throw RecentPhotoError.originalChanged
        }
        sourceDigest = measured
        let stable = PhotoIdentity(resourceIdentifier: source.identity.resourceIdentifier, contentIdentifier: measured)
        var specs: [PhotoPreviewResourceSpec] = []
        if let look {
            specs.append(PhotoPreviewResourceSpec(url: look))
        }
        if state.settings.isHDREditing, let hdr = state.settings.hdr {
            specs.append(contentsOf: try PhotoPreviewPlan.resolveHDRResourceSpecs(
                hdr: hdr,
                profileURLProvider: { try HDRCameraProfileAssetStore.url(for: $0) }
            ))
        }
        let (requirements, encodedResources) = try PhotoPreviewPlan.evaluateResources(
            specs,
            includeFileIdentity: false,
            digestCache: digestCache
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let cacheKey = PhotoPreviewCacheKey(
            identity: try encoder.encode(stable),
            adjustments: try encoder.encode(state.withUpdatedAt(Date(timeIntervalSince1970: 0))),
            resources: encodedResources,
            edge: Self.edge
        )
        core = PhotoPreviewPlan(key: cacheKey, resourceRequirements: requirements)
    }

    func isCurrent(in store: EditPersistence, digestCache: FileDigestCache = .shared) throws -> Bool {
        guard record.hasSameAdjustments(as: try store.readState(for: record.identity)) else { return false }
        let measured = try source.file.withReadAccess { try digestCache.digest(for: $0) }
        guard source.identity.contentIdentifier == nil || measured == source.identity.contentIdentifier else {
            throw RecentPhotoError.originalChanged
        }
        guard measured == sourceDigest else { return false }
        return try core.areResourcesCurrent(digestCache: digestCache)
    }

    static func thumbnailData(_ image: UIImage) throws -> Data {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return try PhotoPreviewThumbnailCodec.encodeThumbnail(cgImage, maxEdge: edge, format: .jpeg(quality: 0.86))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = normalized.cgImage else { throw CocoaError(.fileWriteUnknown) }
        return try PhotoPreviewThumbnailCodec.encodeThumbnail(cgImage, maxEdge: edge, format: .jpeg(quality: 0.86))
    }
}

@MainActor final class IOSPhotoPreviewLibrary: ObservableObject {
    @Published private(set) var photos: [RecentPhoto] = []
    @Published private(set) var edited: [String: Bool] = [:]
    @Published private(set) var revision = 0
    @Published var error: String?
    @Published var isEditorBusy = false
    let recentStore: RecentPhotoStore?
    private let worker: IOSPhotoPreviewWorker

    init(recentStore: RecentPhotoStore? = nil,
         cacheDirectory: URL? = nil,
         digestCache: FileDigestCache = .shared) {
        var store = recentStore
        do { if store == nil { store = try RecentPhotoStore.appStore() } }
        catch { self.error = error.localizedDescription }
        self.recentStore = store
        worker = IOSPhotoPreviewWorker(
            cacheDirectory: cacheDirectory ??
                FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RawLab/EditedPhotoPreviews"),
            digestCache: digestCache)
    }

    func reload(editDirectory: URL?) async {
        guard let recentStore else { return }
        do {
            let result = try await worker.recentStates(store: recentStore, editDirectory: editDirectory)
            try Task.checkCancellation()
            photos = result.0; edited = result.1
            error = result.2
            revision &+= 1
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func recordOpened(_ source: IOSPhotoPreviewSource, preview: UIImage?, editDirectory: URL?) async {
        guard let recentStore else { return }
        do {
            try await worker.recordOpened(source, preview: preview, store: recentStore)
            await reload(editDirectory: editDirectory)
        } catch { self.error = L10n.format("无法加入最近打开：%@", error.localizedDescription) }
    }

    func remove(_ photo: RecentPhoto, editDirectory: URL?) async {
        guard let recentStore else { return }
        do { try await worker.remove(photo, store: recentStore); await reload(editDirectory: editDirectory) }
        catch { self.error = error.localizedDescription }
    }

    func source(for photo: RecentPhoto) async throws -> IOSPhotoPreviewSource {
        guard let recentStore else { throw RecentPhotoError.unavailable }
        return try await worker.source(for: photo, store: recentStore)
    }

    func lastPreview(for photo: RecentPhoto) async -> UIImage? {
        guard let recentStore, let data = try? await worker.lastPreview(photo, store: recentStore) else { return nil }
        return UIImage(data: data)
    }

    func record(for identity: PhotoIdentity, editDirectory: URL) async throws -> PhotoEditRecord {
        try await worker.record(for: identity, editDirectory: editDirectory)
    }
    func original(_ source: IOSPhotoPreviewSource) async -> UIImage? { await worker.original(source) }
    func image(_ source: IOSPhotoPreviewSource, record: PhotoEditRecord, look: URL?, editDirectory: URL) async throws -> UIImage {
        let data = try await worker.image(source, record: record, look: look, editDirectory: editDirectory, recentStore: recentStore)
        try Task.checkCancellation()
        guard let result = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    func accept(_ source: IOSPhotoPreviewSource, record: PhotoEditRecord, image: UIImage, look: URL?, editDirectory: URL) async {
        guard IOSPhotoPreviewPlan.isEdited(record, isRaw: source.isRaw) else { return }
        do {
            try await worker.accept(source, record: record, image: image, look: look, editDirectory: editDirectory, recentStore: recentStore)
            revision &+= 1
        } catch { /* 可重建缓存的失败不改变编辑保存状态。 */ }
    }
}

private actor IOSPhotoPreviewWorker {
    private let cache: EditedPhotoPreviewCache
    private let digestCache: FileDigestCache
    init(cacheDirectory: URL, digestCache: FileDigestCache = .shared) {
        cache = EditedPhotoPreviewCache(directory: cacheDirectory)
        self.digestCache = digestCache
    }

    func recentStates(store: RecentPhotoStore, editDirectory: URL?) throws -> ([RecentPhoto], [String: Bool], String?) {
        let photos = try store.records()
        guard let editDirectory else {
            return (photos, [:], L10n.text("无法读取已保存的调整，原有记录未被覆盖。"))
        }
        do {
            let edits = try EditPersistence(directory: editDirectory)
            let states = try edits.readStates(for: photos.map(\.identity))
            var flags = [String: Bool]()
            for photo in photos {
                try Task.checkCancellation()
                switch states[photo.identity] {
                case .success(let record):
                    flags[photo.id] = IOSPhotoPreviewPlan.isEdited(record, isRaw: photo.isRaw)
                case .failure(let error) where error is UnusableEditRecordError:
                    break
                case .failure(let error):
                    throw error
                case nil:
                    break
                }
            }
            return (photos, flags, nil)
        } catch is CancellationError { throw CancellationError() }
        catch { return (photos, [:], error.localizedDescription) }
    }
    func recordOpened(_ source: IOSPhotoPreviewSource, preview: UIImage?, store: RecentPhotoStore) throws {
        let photo = try source.file.withReadAccess {
            try store.recordOpened(url: $0, identity: source.identity, displayName: source.displayName, isRaw: source.isRaw)
        }
        if let preview, let bytes = try? IOSPhotoPreviewPlan.thumbnailData(preview) {
            let key = PhotoPreviewCacheKey(identity: Data(photo.id.utf8), adjustments: Data("last-opened".utf8), edge: IOSPhotoPreviewPlan.edge)
            try? store.savePreview(bytes, key: key, for: photo.identity)
        }
    }
    func remove(_ photo: RecentPhoto, store: RecentPhotoStore) throws { try store.remove(photo.id) }
    func source(for photo: RecentPhoto, store: RecentPhotoStore) throws -> IOSPhotoPreviewSource {
        try Task.checkCancellation()
        return .init(identity: photo.identity, file: .externallyManaged(try store.sourceURL(for: photo)), displayName: photo.displayName, isRaw: photo.isRaw)
    }
    func lastPreview(_ photo: RecentPhoto, store: RecentPhotoStore) throws -> Data? { try store.lastPreview(for: photo) }
    func record(for identity: PhotoIdentity, editDirectory: URL) throws -> PhotoEditRecord {
        try Task.checkCancellation()
        return try EditPersistence(directory: editDirectory).readState(for: identity)
    }
    func original(_ source: IOSPhotoPreviewSource) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return source.file.withReadAccess { url in
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), let small = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: !source.isRaw,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: IOSPhotoPreviewPlan.edge
            ] as CFDictionary) else { return nil }
            return UIImage(cgImage: small)
        }
    }
    func image(_ source: IOSPhotoPreviewSource, record: PhotoEditRecord, look: URL?, editDirectory: URL,
               recentStore: RecentPhotoStore?) throws -> Data {
        let edits = try EditPersistence(directory: editDirectory)
        var renderedData: Data?
        let outcome = try EditedPhotoPreviewCoordinator.loadOrRenderThumbnail(
            cache: cache,
            makePlan: { try IOSPhotoPreviewPlan(source: source, record: record, look: look, digestCache: digestCache) },
            isCurrent: { try $0.isCurrent(in: edits, digestCache: digestCache) },
            key: { $0.key },
            render: { plan in
                let processor = Sony2FujiProcessor()
                let settings = plan.settings
                let image: UIImage = try source.file.withReadAccess { url in
                    if settings.isHDREditing {
                        let frame = try processor.processHDR(url: url, settings: settings.hdr!.previewSettings(),
                            previewLongEdge: IOSPhotoPreviewPlan.edge, processing: settings.processing,
                            proRAWDecodeVersion: settings.proRAWDecodeVersion,
                            cancelled: { Task.isCancelled })
                        return try UIImage(cgImage: HDRPresentation.makeSDRImage(frame))
                    }
                    if source.isRaw {
                        let frame = try processor.processRaw(url: url, settings: settings, previewLongEdge: CGFloat(IOSPhotoPreviewPlan.edge),
                            lutURL: look, viewportPreview: true)
                        guard let image = processor.makeUIImage(from: frame.buffer, orientation: frame.orientation) else { throw CocoaError(.fileReadCorruptFile) }
                        return image
                    }
                    let input = try processor.loadRasterBuffer(url: url, previewLongEdge: IOSPhotoPreviewPlan.edge)
                    let output = try processor.processBuffer(buffer: input.buffer, settings: settings, previewLongEdge: CGFloat(IOSPhotoPreviewPlan.edge),
                        lutURL: look, viewportPreview: true)
                    guard let image = processor.makeUIImage(from: output, orientation: .up) else { throw CocoaError(.fileReadCorruptFile) }
                    return image
                }
                renderedData = try IOSPhotoPreviewPlan.thumbnailData(image)
                guard let cg = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
                return cg
            },
            encode: { _ in
                guard let renderedData else { throw CocoaError(.fileWriteUnknown) }
                return renderedData
            },
            onCacheMissWrite: { plan, data in
                try? recentStore?.savePreview(data, key: plan.key, for: source.identity)
            }
        )
        return outcome.data
    }
    func accept(_ source: IOSPhotoPreviewSource, record: PhotoEditRecord, image: UIImage, look: URL?, editDirectory: URL,
                recentStore: RecentPhotoStore?) throws {
        let edits = try EditPersistence(directory: editDirectory)
        _ = try EditedPhotoPreviewCoordinator.acceptThumbnail(
            cache: cache,
            makePlan: { try IOSPhotoPreviewPlan(source: source, record: record, look: look, digestCache: digestCache) },
            isCurrent: { try $0.isCurrent(in: edits, digestCache: digestCache) },
            key: { $0.key },
            encode: { try IOSPhotoPreviewPlan.thumbnailData(image) },
            onAccepted: { plan, data in
                try? recentStore?.savePreview(data, key: plan.key, for: source.identity)
            }
        )
    }
}
