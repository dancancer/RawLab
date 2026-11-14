import AppKit
import Combine
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

final class MacResourceDigestCache {
    static let defaultMaximumEntries = 128
    static let shared = MacResourceDigestCache()

    struct Result {
        let identity: OriginalFileIdentity
        let digest: Data
    }

    private struct Entry {
        let fingerprint: FileStatFingerprint
        let identity: OriginalFileIdentity
        let digest: Data
    }

    private let stateLock = NSLock()
    private let stripeLocks = (0..<16).map { _ in NSLock() }
    private var cache: BoundedLRUCache<String, Entry>
    private var invalidationEpoch: UInt64 = 0
    private var _sha256Count = 0

    let maximumEntries: Int

    init(maximumEntries: Int = MacResourceDigestCache.defaultMaximumEntries) {
        self.maximumEntries = max(1, maximumEntries)
        self.cache = BoundedLRUCache(maximumEntries: self.maximumEntries)
    }

    var entryCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache.count
    }

    var sha256Count: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _sha256Count
    }

    private func stripeLock(for path: String) -> NSLock {
        let hash = UInt(bitPattern: path.hashValue)
        return stripeLocks[Int(hash % UInt(stripeLocks.count))]
    }

    func invalidate(url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        invalidate(path: path)
    }

    private func invalidate(path: String) {
        stateLock.lock()
        invalidationEpoch &+= 1
        cache.removeValue(for: path)
        stateLock.unlock()
    }

    func fingerprintDigest(
        for url: URL,
        maxBytes: Int? = nil,
        onHash: (() -> Void)? = nil,
        readData: ((URL) throws -> Data)? = nil
    ) throws -> Result {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolvedURL.path

        if let cached = lookup(path: path) {
            if let maxBytes, !(1...maxBytes).contains(Int(cached.fingerprint.size)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Result(identity: cached.identity, digest: cached.digest)
        }

        let stripe = stripeLock(for: path)
        stripe.lock()
        defer { stripe.unlock() }

        if let cached = lookup(path: path) {
            if let maxBytes, !(1...maxBytes).contains(Int(cached.fingerprint.size)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Result(identity: cached.identity, digest: cached.digest)
        }

        for attempt in 0..<3 {
            stateLock.lock()
            let epochBefore = invalidationEpoch
            stateLock.unlock()

            guard let statBefore = FileStatFingerprint(path: path) else {
                invalidate(path: path)
                _ = try OriginalFileIdentity(url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            if let maxBytes, !(1...maxBytes).contains(Int(statBefore.size)) {
                throw CocoaError(.fileReadCorruptFile)
            }

            let identity = try OriginalFileIdentity(resolvedURL)
            let data = try (readData?(resolvedURL) ?? Data(contentsOf: resolvedURL))
            if let maxBytes, data.isEmpty || data.count > maxBytes {
                throw CocoaError(.fileReadCorruptFile)
            }

            stateLock.lock()
            _sha256Count += 1
            stateLock.unlock()
            onHash?()
            let digest = Data(SHA256.hash(data: data))

            let statAfter = FileStatFingerprint(path: path)
            if statAfter == statBefore,
               Int64(data.count) == statBefore.size,
               identity.size == UInt64(statBefore.size) {
                stateLock.lock()
                if invalidationEpoch == epochBefore, FileStatFingerprint(path: path) == statBefore {
                    cache.set(Entry(fingerprint: statBefore, identity: identity, digest: digest), for: path)
                }
                stateLock.unlock()
                return Result(identity: identity, digest: digest)
            }

            invalidate(path: path)
            if attempt == 2 {
                return Result(identity: identity, digest: digest)
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func lookup(path: String) -> Entry? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let statNow = FileStatFingerprint(path: path) else {
            cache.removeValue(for: path)
            return nil
        }
        guard let hit = cache.get(path), hit.fingerprint == statNow else {
            cache.removeValue(for: path)
            return nil
        }
        return hit
    }
}

struct MacPhotoPreviewPlan {
    static let edge = 256
    private static let resourceHashLock = NSLock()
    private static var _resourceHashCount = 0
    static var resourceHashCount: Int {
        resourceHashLock.lock()
        defer { resourceHashLock.unlock() }
        return _resourceHashCount
    }
    private static func recordResourceHash() {
        resourceHashLock.lock()
        _resourceHashCount += 1
        resourceHashLock.unlock()
    }
    let record: PhotoEditRecord
    let look: URL?
    let key: PhotoPreviewCacheKey
    let resourceURLs: [URL]
    var url: URL { URL(fileURLWithPath: record.identity.path) }

    static func isEditedState(_ state: PhotoEditState?, atPath path: String) -> Bool {
        guard let state else { return false }
        let raw = !RenderEngine.isRasterInput(URL(fileURLWithPath: path))
        return EditorAdjustmentRules.isModified(scope: .all, snapshot: state,
            context: .init(isRaw: raw, defaultExposureMode: raw ? Adjustments().exposureMode : .sensor, neutralFilmID: ""))
    }

    static func isEdited(_ record: PhotoEditRecord) -> Bool {
        isEditedState(record.state, atPath: record.identity.path)
    }

    static func editedRevision(for state: PhotoEditState?, atPath path: String) -> String? {
        guard let state, isEditedState(state, atPath: path) else { return nil }
        return EditPersistence.stateRevisionDigest(for: state)
    }

    static func editedRevision(for record: PhotoEditRecord) -> PhotoThumbnails.EditedRevision? {
        guard let revision = editedRevision(for: record.state, atPath: record.identity.path) else { return nil }
        return PhotoThumbnails.EditedRevision(identity: record.identity.thumbnailFileIdentity, revision: revision)
    }

    init(record: PhotoEditRecord, films: [Film],
         hdrLookDirectory: URL = HDRLookSettings.directory,
         resourceDigestCache: MacResourceDigestCache = .shared) throws {
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
        var precomputedHDRLook: (url: URL, result: MacResourceDigestCache.Result)? = nil
        if let look { resources.append(look) }
        if state.settings.isHDREditing, let hdr = state.settings.hdr {
            guard hdr.lookSettings.isValid else { throw CocoaError(.fileNoSuchFile) }
            if let asset = hdr.lookSettings.asset(in: hdrLookDirectory) {
                guard asset.isFileURL,
                      let cached = try? resourceDigestCache.fingerprintDigest(
                          for: asset, maxBytes: 32 * 1024 * 1024, onHash: Self.recordResourceHash),
                      cached.digest.map({ String(format: "%02x", $0) }).joined() == hdr.lookSettings.sha256 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                resources.append(asset)
                precomputedHDRLook = (asset, cached)
            } else {
                guard hdr.lookSettings.isDefault else { throw CocoaError(.fileNoSuchFile) }
            }
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
            let cached: MacResourceDigestCache.Result
            if let precomputedHDRLook, precomputedHDRLook.url == url {
                cached = precomputedHDRLook.result
            } else {
                cached = try resourceDigestCache.fingerprintDigest(for: url, onHash: Self.recordResourceHash)
            }
            let identity = try encoder.encode(cached.identity)
            return identity + cached.digest
        }
        key = PhotoPreviewCacheKey(identity: try encoder.encode(record.identity),
            adjustments: try encoder.encode(state), resources: try encoder.encode(fingerprints), edge: Self.edge)
    }

    func isCurrent(in store: EditPersistence, films: [Film],
                   hdrLookDirectory: URL = HDRLookSettings.directory,
                   resourceDigestCache: MacResourceDigestCache = .shared) throws -> Bool {
        guard try store.readState(for: url) == record else { return false }
        return try MacPhotoPreviewPlan(record: record, films: films,
            hdrLookDirectory: hdrLookDirectory, resourceDigestCache: resourceDigestCache).key == key
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

    fileprivate static func decodeThumbnailImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension OriginalFileIdentity {
    var thumbnailFileIdentity: PhotoThumbnails.FileIdentity {
        .init(fileSize: size, modified: modified, fileNumber: fileNumber)
    }
}

extension PhotoThumbnailCacheKey {
    init(identity: OriginalFileIdentity, previewKey: PhotoPreviewCacheKey, maxPixelSize: Int = MacPhotoPreviewPlan.edge) {
        self.init(path: identity.path, fileSize: identity.size, modified: identity.modified,
                  fileNumber: identity.fileNumber, maxPixelSize: maxPixelSize,
                  appliesAdjustments: true, adjustmentRevision: previewKey.digest)
    }
}

private struct MacAcceptedPhotoPreview {
    let key: PhotoPreviewCacheKey
    let image: NSImage
}

@MainActor final class MacEditedPhotoPreviews: ObservableObject {
    struct CachedThumbnail {
        let image: NSImage
        let identity: OriginalFileIdentity
        let isEdited: Bool
    }

    @Published private(set) var revision = 0
    @Published var isEditorBusy = false {
        didSet {
            guard oldValue, !isEditorBusy, hasDeferredEditedRefresh else { return }
            hasDeferredEditedRefresh = false
            refresh()
        }
    }
    private var hasDeferredEditedRefresh = false
    private let worker: MacPhotoPreviewWorker
    private let editDirectory: URL
    private let canonicalEditDirectoryPath: String
    private let cache: EditedPhotoPreviewCache
    let thumbnails: PhotoThumbnails
    private var accepted: (record: PhotoEditRecord, task: Task<MacAcceptedPhotoPreview?, Never>)?
    private var activeKeys: [String: (key: PhotoThumbnailCacheKey, identity: OriginalFileIdentity, isEdited: Bool, generation: UInt64)] = [:]
    private var trackedEditStates: [String: PhotoThumbnails.TrackedEditState] = [:]
    private var watches: [URL: (source: DispatchSourceFileSystemObject?, readers: Int)] = [:]
    private var resourceWatches: [URL: Set<URL>] = [:]
    private var persistenceCancellables: Set<AnyCancellable> = []
    private(set) var imageDecodeCount = 0
    private(set) var editedInvalidationCount = 0
    var films: [Film] = [] {
        didSet {
            guard films != oldValue else { return }
            reconcileFilmsChange(from: oldValue, to: films)
        }
    }

    init(editDirectory: URL, cacheDirectory: URL? = nil, thumbnails: PhotoThumbnails = .shared) {
        self.editDirectory = editDirectory
        self.canonicalEditDirectoryPath = editDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        self.thumbnails = thumbnails
        cache = EditedPhotoPreviewCache(directory: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/EditedPhotoPreviews"))
        worker = MacPhotoPreviewWorker(editDirectory: editDirectory, cache: cache)
        observePersistenceNotifications()
    }

    func refresh() { revision &+= 1 }

    func noteDeferredEditedRefresh() {
        if isEditorBusy { hasDeferredEditedRefresh = true }
    }

    func cachedThumbnail(for url: URL) -> CachedThumbnail? {
        let path = PhotoThumbnailCacheKey.canonicalPath(for: url)
        guard let active = activeKeys[path],
              active.generation == thumbnails.editGeneration(forPath: path),
              let image = thumbnails.cachedImage(for: active.key) else {
            activeKeys.removeValue(forKey: path)
            return nil
        }
        return CachedThumbnail(image: image, identity: active.identity, isEdited: active.isEdited)
    }

    func originalImage(for url: URL, identity: OriginalFileIdentity, recordAsActive: Bool = true) async -> NSImage? {
        let editGen = thumbnails.editGeneration(forPath: identity.path)
        let image = await thumbnails.image(for: url)
        if recordAsActive, image != nil,
           thumbnails.editGeneration(forPath: identity.path) == editGen {
            let key = PhotoThumbnailCacheKey(path: identity.path, fileSize: identity.size,
                modified: identity.modified, fileNumber: identity.fileNumber,
                maxPixelSize: PhotoThumbnails.defaultMaxPixelSize, appliesAdjustments: false)
            activeKeys[identity.path] = (key, identity, false, editGen)
        }
        return image
    }

    func cachedImage(for record: PhotoEditRecord) async -> NSImage? {
        guard MacPhotoPreviewPlan.isEdited(record) else { return nil }
        let films = films, directory = editDirectory, thumbnails = thumbnails
        let editGen = thumbnails.editGeneration(forPath: record.identity.path)
        guard let resolved = await Task.detached(priority: .utility, operation: { () -> (PhotoThumbnailCacheKey, NSImage)? in
            guard let store = try? EditPersistence(directory: directory),
                  let plan = try? MacPhotoPreviewPlan(record: record, films: films),
                  (try? plan.isCurrent(in: store, films: films)) == true else { return nil }
            let key = PhotoThumbnailCacheKey(identity: record.identity, previewKey: plan.key)
            guard let image = thumbnails.cachedImage(for: key) else { return nil }
            return (key, image)
        }).value else { return nil }
        if thumbnails.editGeneration(forPath: record.identity.path) == editGen {
            activeKeys[record.identity.path] = (resolved.0, record.identity, true, editGen)
        }
        return resolved.1
    }

    func invalidateEdited(for url: URL) {
        if invalidateEdited(atPath: PhotoThumbnailCacheKey.canonicalPath(for: url)) {
            refresh()
        }
    }

    func invalidate(for url: URL) {
        let path = PhotoThumbnailCacheKey.canonicalPath(for: url)
        activeKeys.removeValue(forKey: path)
        if accepted?.record.identity.path == path { accepted = nil }
        _ = markLocalEditedInvalidated(atPath: path)
        thumbnails.invalidate(atPath: path)
        refresh()
    }

    private func markLocalEditedInvalidated(atPath path: String) -> Bool {
        switch trackedEditStates[path] {
        case .revision(let rev):
            trackedEditStates[path] = .invalidated(rev)
            return true
        case .cached:
            trackedEditStates.removeValue(forKey: path)
            return true
        case .invalidated, .none:
            return false
        }
    }

    private func markLocalEditedStored(for identity: OriginalFileIdentity, editedRevision: PhotoThumbnails.EditedRevision?) {
        let path = identity.path
        let fileIdentity = identity.thumbnailFileIdentity
        switch trackedEditStates[path] {
        case .invalidated(let existing) where existing.identity == fileIdentity:
            trackedEditStates[path] = .revision(existing)
        case .revision(let existing) where existing.identity == fileIdentity:
            break
        case .cached(fileIdentity):
            break
        case .none, .invalidated, .revision, .cached:
            trackedEditStates[path] = editedRevision.map(PhotoThumbnails.TrackedEditState.revision) ?? .cached(fileIdentity)
        }
    }

    private func beginEditedRender(for record: PhotoEditRecord) -> (generation: UInt64, editedRevision: PhotoThumbnails.EditedRevision?) {
        let path = record.identity.path
        guard let editedRevision = MacPhotoPreviewPlan.editedRevision(for: record) else {
            return (thumbnails.editGeneration(forPath: path), nil)
        }
        let seeded = thumbnails.seedEditedRevisionIfUntracked(editedRevision, atPath: path)
        if trackedEditStates[path]?.identity != editedRevision.identity {
            trackedEditStates[path] = .revision(editedRevision)
            if seeded.seeded { editedInvalidationCount += 1 }
        }
        return (seeded.generation, editedRevision)
    }

    @discardableResult
    private func invalidateEdited(atPath path: String, preInvalidatedThumbnails: Bool = false) -> Bool {
        var removedActive = false
        if activeKeys[path]?.isEdited == true {
            activeKeys.removeValue(forKey: path)
            removedActive = true
        }
        var clearedAccepted = false
        if accepted?.record.identity.path == path {
            accepted = nil
            clearedAccepted = true
        }
        let localTransitioned = markLocalEditedInvalidated(atPath: path)
        let invalidatedThumbnails = preInvalidatedThumbnails || thumbnails.invalidateEdited(atPath: path)
        let changed = removedActive || clearedAccepted || localTransitioned || invalidatedThumbnails
        if changed { editedInvalidationCount += 1 }
        return changed
    }

    @discardableResult
    private func handlePersistedRecordChange(_ record: PhotoEditRecord, preInvalidatedThumbnails: Bool) -> Bool {
        let path = record.identity.path
        guard let editedRevision = MacPhotoPreviewPlan.editedRevision(for: record) else {
            let hadLocal = trackedEditStates.removeValue(forKey: path) != nil
            var removedActive = false
            if let active = activeKeys[path], active.isEdited || active.identity != record.identity {
                activeKeys.removeValue(forKey: path)
                removedActive = true
            }
            var clearedAccepted = false
            if accepted?.record.identity.path == path {
                accepted = nil
                clearedAccepted = true
            }
            let invalidatedThumbnails = preInvalidatedThumbnails || thumbnails.reconcileEditedRevision(nil, atPath: path)
            let changed = hadLocal || removedActive || clearedAccepted || invalidatedThumbnails
            if changed { editedInvalidationCount += 1 }
            return changed
        }
        let localTransitioned: Bool
        switch trackedEditStates[path] {
        case .revision(editedRevision), .invalidated(editedRevision):
            localTransitioned = false
        case .revision, .invalidated, .cached, .none:
            trackedEditStates[path] = .revision(editedRevision)
            localTransitioned = true
        }
        let invalidatedThumbnails = preInvalidatedThumbnails || thumbnails.reconcileEditedRevision(editedRevision, atPath: path)
        var removedActive = false
        if let active = activeKeys[path],
           localTransitioned || invalidatedThumbnails || !active.isEdited || active.identity != record.identity {
            activeKeys.removeValue(forKey: path)
            removedActive = true
        }
        var clearedAccepted = false
        if (localTransitioned || invalidatedThumbnails), accepted?.record.identity.path == path {
            accepted = nil
            clearedAccepted = true
        }
        let changed = localTransitioned || removedActive || clearedAccepted || invalidatedThumbnails
        if changed { editedInvalidationCount += 1 }
        return changed
    }

    private func observePersistenceNotifications() {
        let targetDirectory = canonicalEditDirectoryPath
        let thumbnails = thumbnails
        NotificationCenter.default.publisher(for: EditPersistence.didChangeRecordsNotification)
            .sink { [weak self] notification in
                guard notification.userInfo?[EditPersistence.directoryPathUserInfoKey] as? String == targetDirectory,
                      let changes = notification.userInfo?[EditPersistence.changedRecordsUserInfoKey] as? [String: PhotoEditRecord] else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for record in changes.values {
                            _ = self.handlePersistedRecordChange(record, preInvalidatedThumbnails: false)
                        }
                        if !changes.isEmpty { self.refresh() }
                    }
                } else {
                    let revisions = notification.userInfo?[EditPersistence.editedRevisionsUserInfoKey] as? [String: String]
                    var preInvalidated = Set<String>()
                    for (path, record) in changes {
                        let revision = revisions?[path] ?? MacPhotoPreviewPlan.editedRevision(for: record.state, atPath: path)
                        let editedRevision = revision.map {
                            PhotoThumbnails.EditedRevision(identity: record.identity.thumbnailFileIdentity, revision: $0)
                        }
                        if thumbnails.reconcileEditedRevision(editedRevision, atPath: path) {
                            preInvalidated.insert(path)
                        }
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for (path, record) in changes {
                            _ = self.handlePersistedRecordChange(record, preInvalidatedThumbnails: preInvalidated.contains(path))
                        }
                        if !changes.isEmpty { self.refresh() }
                    }
                }
            }
            .store(in: &persistenceCancellables)

        NotificationCenter.default.publisher(for: EditPersistence.didInvalidateEditedNotification)
            .sink { [weak self] notification in
                guard notification.userInfo?[EditPersistence.directoryPathUserInfoKey] as? String == targetDirectory,
                      let paths = notification.userInfo?[EditPersistence.invalidatedPathsUserInfoKey] as? Set<String> else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for path in paths {
                            _ = self.invalidateEdited(atPath: path)
                        }
                        if !paths.isEmpty { self.refresh() }
                    }
                } else {
                    var preInvalidated = Set<String>()
                    for path in paths where thumbnails.invalidateEdited(atPath: path) {
                        preInvalidated.insert(path)
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for path in paths {
                            _ = self.invalidateEdited(atPath: path, preInvalidatedThumbnails: preInvalidated.contains(path))
                        }
                        if !paths.isEmpty { self.refresh() }
                    }
                }
            }
            .store(in: &persistenceCancellables)
    }

    private func reconcileFilmsChange(from oldFilms: [Film], to newFilms: [Film]) {
        let currentByID = Dictionary(uniqueKeysWithValues: newFilms.map { ($0.id, $0.url) })
        let currentByBrowserID = Dictionary(uniqueKeysWithValues: newFilms.map { ($0.browserID, $0.url) })
        var invalidatedIDs = Set<String>()
        for film in oldFilms where currentByID[film.id] != film.url || currentByBrowserID[film.browserID] != film.url {
            invalidatedIDs.insert(film.id)
            invalidatedIDs.insert(film.browserID)
        }
        guard !invalidatedIDs.isEmpty,
              let store = try? EditPersistence(directory: editDirectory) else { return }
        for path in store.pathsReferencingFilms(invalidatedIDs) {
            _ = invalidateEdited(atPath: path)
        }
    }

    func renderStats() async -> (renders: Int, diskReads: Int, decodes: Int) {
        let stats = await worker.stats()
        return (stats.renders, stats.diskReads, imageDecodeCount)
    }

    private func watchedFileDidChange(_ url: URL) {
        if resourceWatches[url] != nil {
            let path = PhotoThumbnailCacheKey.canonicalPath(for: url)
            if (try? OriginalFileIdentity(url)) != activeKeys[path]?.identity {
                activeKeys.removeValue(forKey: path)
                if accepted?.record.identity.path == path { accepted = nil }
                _ = markLocalEditedInvalidated(atPath: path)
                thumbnails.invalidate(atPath: path)
            }
        }
        for (photoURL, resources) in resourceWatches where photoURL != url && resources.contains(url) {
            guard url != photoURL.deletingLastPathComponent() else { continue }
            if (try? OriginalFileIdentity(url)) == nil {
                _ = invalidateEdited(atPath: PhotoThumbnailCacheKey.canonicalPath(for: photoURL))
            }
        }
        refresh()
    }

    func watch(_ url: URL) {
        if let watch = watches[url] { watches[url] = (watch.source, watch.readers + 1); return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { watches[url] = (nil, 1); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.watchedFileDidChange(url) } }
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
        let canonicalPath = PhotoThumbnailCacheKey.canonicalPath(for: url)
        let editGenBeforeRead = thumbnails.editGeneration(forPath: canonicalPath)
        let record = try await worker.record(for: url)
        let fileIdentity = record.identity.thumbnailFileIdentity
        let stateRevision = MacPhotoPreviewPlan.editedRevision(for: record.state, atPath: record.identity.path)
        let editedRevision = stateRevision.map { PhotoThumbnails.EditedRevision(identity: fileIdentity, revision: $0) }
        let edited = editedRevision != nil
        let films = films
        let planInfo = await Task.detached(priority: .utility) { () -> (key: PhotoPreviewCacheKey, resources: [URL])? in
            guard let plan = try? MacPhotoPreviewPlan(record: record, films: films) else { return nil }
            return (plan.key, plan.resourceURLs)
        }.value
        try Task.checkCancellation()
        let previewRevision = edited ? planInfo?.key.digest : nil
        let hadLocalEdited = trackedEditStates[record.identity.path] != nil ||
            activeKeys[record.identity.path]?.isEdited == true
        let staleInvalidated = thumbnails.invalidateStaleEntries(
            atPath: record.identity.path, fileSize: record.identity.size,
            modified: record.identity.modified, fileNumber: record.identity.fileNumber,
            stateRevision: stateRevision, editedRevision: previewRevision,
            expectedEditGeneration: editGenBeforeRead)
        if staleInvalidated {
            activeKeys.removeValue(forKey: record.identity.path)
            if accepted?.record.identity.path == record.identity.path { accepted = nil }
            if let editedRevision {
                trackedEditStates[record.identity.path] = previewRevision != nil ? .revision(editedRevision) : .invalidated(editedRevision)
            } else {
                trackedEditStates.removeValue(forKey: record.identity.path)
            }
            if editedRevision != nil || hadLocalEdited {
                editedInvalidationCount += 1
            }
        } else {
            if thumbnails.editGeneration(forPath: record.identity.path) == editGenBeforeRead,
               trackedEditStates[record.identity.path]?.identity != fileIdentity,
               let editedRevision {
                trackedEditStates[record.identity.path] = previewRevision != nil ? .revision(editedRevision) : .invalidated(editedRevision)
            }
            if let active = activeKeys[record.identity.path], active.isEdited != edited || active.identity != record.identity {
                activeKeys.removeValue(forKey: record.identity.path)
            }
        }
        let resources = planInfo?.resources ?? []
        let previous = resourceWatches[url] ?? []
        var candidates = resources
        if resources.isEmpty, let state = record.state, edited {
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
        if resources.isEmpty, edited { next.formUnion(previous) }
        for removed in previous.subtracting(next) { unwatch(removed) }
        for added in next.subtracting(previous) { watch(added) }
        for retained in next.intersection(previous) { refreshWatch(retained) }
        resourceWatches[url] = next
        return record
    }
    func image(for record: PhotoEditRecord) async throws -> NSImage {
        if let hit = await cachedImage(for: record) { return hit }
        let (editGen, editedRevision) = beginEditedRender(for: record)
        if let accepted, accepted.record == record, let ready = await accepted.task.value {
            let films = films, directory = editDirectory
            let current = await Task.detached(priority: .utility) {
                guard let store = try? EditPersistence(directory: directory),
                      let plan = try? MacPhotoPreviewPlan(record: record, films: films) else { return false }
                return plan.key == ready.key && (try? plan.isCurrent(in: store, films: films)) == true
            }.value
            if current {
                try Task.checkCancellation()
                let cacheKey = PhotoThumbnailCacheKey(identity: record.identity, previewKey: ready.key)
                thumbnails.store(ready.image, for: cacheKey, expectedEditGeneration: editGen)
                if thumbnails.editGeneration(forPath: record.identity.path) == editGen {
                    markLocalEditedStored(for: record.identity, editedRevision: editedRevision)
                    activeKeys[record.identity.path] = (cacheKey, record.identity, true, editGen)
                }
                return ready.image
            }
        }
        let rendered: (key: PhotoPreviewCacheKey, image: NSImage)
        do {
            rendered = try await worker.image(for: record, films: films)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = invalidateEdited(atPath: record.identity.path)
            throw error
        }
        try Task.checkCancellation()
        imageDecodeCount += 1
        let cacheKey = PhotoThumbnailCacheKey(identity: record.identity, previewKey: rendered.key)
        thumbnails.store(rendered.image, for: cacheKey, expectedEditGeneration: editGen)
        if thumbnails.editGeneration(forPath: record.identity.path) == editGen {
            markLocalEditedStored(for: record.identity, editedRevision: editedRevision)
            activeKeys[record.identity.path] = (cacheKey, record.identity, true, editGen)
        }
        return rendered.image
    }
    func accept(record: PhotoEditRecord, image: CGImage) {
        guard MacPhotoPreviewPlan.isEdited(record) else {
            _ = invalidateEdited(atPath: record.identity.path)
            return
        }
        let (editGen, editedRevision) = beginEditedRender(for: record)
        let films = films, directory = editDirectory, cache = cache, thumbnails = thumbnails
        let task = Task.detached(priority: .utility) { () -> MacAcceptedPhotoPreview? in
            do {
                let store = try EditPersistence(directory: directory)
                let plan = try MacPhotoPreviewPlan(record: record, films: films)
                guard try plan.isCurrent(in: store, films: films) else { return nil }
                let data = try MacPhotoPreviewPlan.thumbnailData(image)
                guard try plan.isCurrent(in: store, films: films),
                      let decoded = MacPhotoPreviewPlan.decodeThumbnailImage(data) else { return nil }
                try? cache.write(data, for: plan.key)
                let cacheKey = PhotoThumbnailCacheKey(identity: record.identity, previewKey: plan.key)
                thumbnails.store(decoded, for: cacheKey, expectedEditGeneration: editGen)
                return MacAcceptedPhotoPreview(key: plan.key, image: decoded)
            } catch { return nil }
        }
        accepted = (record, task)
        Task { [weak self] in
            guard let self else { return }
            guard let ready = await task.value else {
                if self.accepted?.record == record {
                    _ = self.invalidateEdited(atPath: record.identity.path)
                }
                return
            }
            let cacheKey = PhotoThumbnailCacheKey(identity: record.identity, previewKey: ready.key)
            if self.thumbnails.editGeneration(forPath: record.identity.path) == editGen,
               self.thumbnails.cachedImage(for: cacheKey) != nil {
                self.markLocalEditedStored(for: record.identity, editedRevision: editedRevision)
                self.activeKeys[record.identity.path] = (cacheKey, record.identity, true, editGen)
            }
            self.refresh()
        }
    }
}

// 独立会话串行显影；任务只来自仍显示的 tile，离屏或修订后的任务会取消。
private actor MacPhotoPreviewWorker {
    let editDirectory: URL
    let cache: EditedPhotoPreviewCache
    private var renderCount = 0
    private var diskReadCount = 0
    init(editDirectory: URL, cache: EditedPhotoPreviewCache) {
        self.editDirectory = editDirectory; self.cache = cache
    }
    func stats() -> (renders: Int, diskReads: Int) { (renderCount, diskReadCount) }
    func record(for url: URL) throws -> PhotoEditRecord {
        try Task.checkCancellation()
        return try EditPersistence(directory: editDirectory).readState(for: url)
    }
    func image(for record: PhotoEditRecord, films: [Film]) async throws -> (key: PhotoPreviewCacheKey, image: NSImage) {
        let progress = AIPreparation { _, _, _ in }
        return try await withTaskCancellationHandler {
            try render(record, films: films, progress: progress)
        } onCancel: { progress.cancel() }
    }
    private func render(_ record: PhotoEditRecord, films: [Film], progress: AIPreparation) throws -> (key: PhotoPreviewCacheKey, image: NSImage) {
        try Task.checkCancellation()
        let store = try EditPersistence(directory: editDirectory)
        let plan = try MacPhotoPreviewPlan(record: record, films: films)
        guard try plan.isCurrent(in: store, films: films) else { throw AdjustmentCommitError.expired }
        if let data = try? cache.read(plan.key), let decoded = MacPhotoPreviewPlan.decodeThumbnailImage(data) {
            try Task.checkCancellation()
            guard try plan.isCurrent(in: store, films: films) else { throw AdjustmentCommitError.expired }
            diskReadCount += 1
            return (plan.key, decoded)
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
        renderCount += 1
        let data = try MacPhotoPreviewPlan.thumbnailData(frame.image)
        guard let decoded = MacPhotoPreviewPlan.decodeThumbnailImage(data) else { throw CocoaError(.fileReadCorruptFile) }
        try? cache.write(data, for: plan.key)
        return (plan.key, decoded)
    }
}
