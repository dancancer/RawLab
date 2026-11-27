import RawLabKit
import AppKit
import Combine
import Darwin
import CryptoKit
import ImageIO
import os
import UniformTypeIdentifiers

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
    let record: MacPhotoEditRecord
    let look: URL?
    let resourceURLs: [URL]
    private let core: PhotoPreviewPlan
    var key: PhotoPreviewCacheKey { core.key }
    var url: URL { URL(fileURLWithPath: record.identity.path) }

    static func isEditedState(_ state: MacPhotoEditState?, atPath path: String) -> Bool {
        guard let state else { return false }
        let raw = !RenderEngine.isRasterInput(URL(fileURLWithPath: path))
        return MacEditorAdjustmentRules.isModified(scope: .all, snapshot: state,
            context: .init(isRaw: raw, defaultExposureMode: raw ? Adjustments().exposureMode : .sensor, neutralFilmID: ""))
    }

    static func isEdited(_ record: MacPhotoEditRecord) -> Bool {
        isEditedState(record.state, atPath: record.identity.path)
    }

    static func editedRevision(for state: MacPhotoEditState?, atPath path: String) -> String? {
        guard let state, isEditedState(state, atPath: path) else { return nil }
        return MacEditPersistence.stateRevisionDigest(for: state)
    }

    static func editedRevision(for record: MacPhotoEditRecord) -> PhotoThumbnails.EditedRevision? {
        guard let revision = editedRevision(for: record.state, atPath: record.identity.path) else { return nil }
        return PhotoThumbnails.EditedRevision(identity: record.identity.thumbnailFileIdentity, revision: revision)
    }

    init(record: MacPhotoEditRecord, films: [Film],
         hdrLookDirectory: URL = HDRLookSettings.directory,
         resourceDigestCache: MacResourceDigestCache = .shared,
         aiModelDirectory: URL? = RenderEngine.resolvedAIModelDirectory) throws {
        self.record = record
        guard let state = record.state else { throw AdjustmentCommitError.expired }
        if state.settings.isHDREditing { look = nil }
        else if let recipeID = state.settings.masterRecipeID ?? state.masterRecipeID {
            guard let url = MasterRecipe.recipe(for: recipeID)?.lutURL() else { throw CocoaError(.fileNoSuchFile) }
            look = url
        } else if let filmID = state.filmID, !filmID.isEmpty {
            guard let film = Film.independentRecipe(filmID) ?? films.first(where: {
                $0.id == filmID || $0.browserID == filmID
            }) else { throw CocoaError(.fileNoSuchFile) }
            look = film.url
        } else { look = nil }
        var specs: [PhotoPreviewResourceSpec] = []
        if let look { specs.append(PhotoPreviewResourceSpec(url: look)) }
        if state.settings.isHDREditing, let hdr = state.settings.hdr {
            specs.append(contentsOf: try PhotoPreviewPlan.resolveHDRResourceSpecs(
                hdr: hdr,
                hdrLookDirectory: hdrLookDirectory,
                profileURLProvider: { try HDRCameraProfileAssetStore.url(for: $0) }
            ))
        }
        if state.settings.activeAIDenoise {
            guard let model = aiModelDirectory else { throw CocoaError(.fileNoSuchFile) }
            specs.append(PhotoPreviewResourceSpec(url: model.appendingPathComponent("manifest.json")))
        }
        resourceURLs = specs.map(\.url)
        let (requirements, encodedResources) = try PhotoPreviewPlan.evaluateResources(
            specs,
            includeFileIdentity: true,
            digestCache: resourceDigestCache.rawDigestCache,
            onHash: Self.recordResourceHash
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let cacheKey = PhotoPreviewCacheKey(
            identity: try encoder.encode(record.identity),
            adjustments: try encoder.encode(state),
            resources: encodedResources,
            edge: Self.edge
        )
        core = PhotoPreviewPlan(key: cacheKey, resourceRequirements: requirements)
    }

    func isCurrent(in store: MacEditPersistence, films: [Film],
                   hdrLookDirectory: URL = HDRLookSettings.directory,
                   resourceDigestCache: MacResourceDigestCache = .shared,
                   aiModelDirectory: URL? = RenderEngine.resolvedAIModelDirectory) throws -> Bool {
        guard try store.readState(for: url) == record else { return false }
        return try MacPhotoPreviewPlan(record: record, films: films,
            hdrLookDirectory: hdrLookDirectory, resourceDigestCache: resourceDigestCache,
            aiModelDirectory: aiModelDirectory).key == key
    }

    static func thumbnailData(_ image: CGImage, edge: Int = Self.edge) throws -> Data {
        try PhotoPreviewThumbnailCodec.encodeThumbnail(image, maxEdge: edge, format: .png)
    }

    fileprivate static func decodeThumbnailImage(_ data: Data) -> NSImage? {
        guard let cgImage = PhotoPreviewThumbnailCodec.decodeCGImage(data) else {
            // 不兜 NSImage(data:)：它能按 PNG 头部懒初始化出 0×0 空白图，把「解不出 CGImage」伪装成成功。
            return nil
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

struct AIPreparationProgress: Equatable, Sendable {
    let path: String
    let fileName: String
    let phase: Int
    let done: UInt64
    let total: UInt64

    var title: String {
        switch phase {
        case 2: return L10n.text("正在处理 RAW 噪声")
        case 3: return L10n.text("正在处理颜色噪声")
        case 4: return L10n.text("正在保存 AI 结果")
        default: return L10n.text("正在准备 AI 降噪")
        }
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
    @Published private(set) var aiPreparationProgress: AIPreparationProgress?
    // 覆盖整个 AI 缩略图执行窗口（含 prepareAI 前的启动窗口与 prepareAI 后的 render 阶段），
    // 防止在读模型目录或核验缓存期间删除已下载模型。
    @Published private(set) var isRunningAIThumbnail = false
    private var activeAIThumbnailTasks = 0
    @Published var isEditorBusy = false {
        didSet {
            guard oldValue, !isEditorBusy, hasDeferredEditedRefresh else { return }
            hasDeferredEditedRefresh = false
            refresh()
        }
    }
    private var hasDeferredEditedRefresh = false
    private var activeAIProgressToken: UUID?
    private var activeAIProgressSequence: UInt64 = 0
    private var closedAIProgressTokens: Set<UUID> = []
    private let worker: MacPhotoPreviewWorker
    private let editDirectory: URL
    private let canonicalEditDirectoryPath: String
    private let cache: EditedPhotoPreviewCache
    private let aiModelDirectory: URL?
    private let aiModelAccessTracker: AIModelAccessTracker
    let thumbnails: PhotoThumbnails
    private var accepted: (record: MacPhotoEditRecord, task: Task<MacAcceptedPhotoPreview?, Never>)?
    private var activeKeys: [String: (key: PhotoThumbnailCacheKey, identity: OriginalFileIdentity, isEdited: Bool, generation: UInt64)] = [:]
    private var trackedEditStates: [String: PhotoThumbnails.TrackedEditState] = [:]
    private struct FileWatch {
        var source: DispatchSourceFileSystemObject?
        var readers: Int
        var fingerprint: FileStatFingerprint?
    }
    private var watches: [URL: FileWatch] = [:]
    private var watchedPhotos: [URL: Int] = [:]
    private var resourceWatches: [URL: Set<URL>] = [:]
    private var persistenceCancellables: Set<AnyCancellable> = []
    private(set) var imageDecodeCount = 0
    private(set) var editedInvalidationCount = 0
    private(set) var lastFilmScanDiagnostics: [String] = []
    private(set) var isScanningFilmChanges = false
    private var filmScanGeneration: UInt64 = 0
    nonisolated private static let logger = Logger(subsystem: "com.rawlab.mac", category: "MacEditedPhotoPreviews")
    var films: [Film] = [] {
        didSet {
            guard films != oldValue else { return }
            reconcileFilmsChange(from: oldValue, to: films)
        }
    }

    init(editDirectory: URL, cacheDirectory: URL? = nil, thumbnails: PhotoThumbnails = .shared,
         aiModelDirectory: URL? = nil,
         aiModelAccessTracker: AIModelAccessTracker = .shared,
         prepareAI: (@Sendable (URL, Adjustments, AIPreparation) throws -> Void)? = nil,
         renderThumbnail: (@Sendable (URL, Adjustments, URL?) throws -> CGImage?)? = nil) {
        self.editDirectory = editDirectory
        self.canonicalEditDirectoryPath = editDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        self.aiModelDirectory = aiModelDirectory
        self.aiModelAccessTracker = aiModelAccessTracker
        self.thumbnails = thumbnails
        cache = EditedPhotoPreviewCache(directory: cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/EditedPhotoPreviews"))
        let weakSelf = WeakBox<MacEditedPhotoPreviews>()
        let progressSink: @Sendable (AIProgressRelay.Event) -> Void = { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let previews = weakSelf.value else { return }
                    switch event {
                    case .update(let progress, let seq, let token):
                        guard !previews.closedAIProgressTokens.contains(token) else { return }
                        if previews.activeAIProgressToken == token, seq <= previews.activeAIProgressSequence {
                            return
                        }
                        previews.activeAIProgressToken = token
                        previews.activeAIProgressSequence = seq
                        previews.aiPreparationProgress = progress
                    case .clear(let token):
                        if previews.closedAIProgressTokens.count > 64 {
                            previews.closedAIProgressTokens.removeAll(keepingCapacity: true)
                        }
                        previews.closedAIProgressTokens.insert(token)
                        if previews.activeAIProgressToken == token {
                            previews.activeAIProgressToken = nil
                            previews.activeAIProgressSequence = 0
                            previews.aiPreparationProgress = nil
                        }
                    }
                }
            }
        }
        worker = MacPhotoPreviewWorker(editDirectory: editDirectory, cache: cache,
                                       aiModelDirectory: aiModelDirectory,
                                       aiModelAccessTracker: aiModelAccessTracker,
                                       prepareAI: prepareAI, renderThumbnail: renderThumbnail,
                                       aiProgressSink: progressSink)
        weakSelf.value = self
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

    func cachedImage(for record: MacPhotoEditRecord) async -> NSImage? {
        guard MacPhotoPreviewPlan.isEdited(record) else { return nil }
        let films = films, directory = editDirectory, thumbnails = thumbnails
        let overrideModel = aiModelDirectory
        let editGen = thumbnails.editGeneration(forPath: record.identity.path)
        guard let resolved = await Task.detached(priority: .utility, operation: { () -> (PhotoThumbnailCacheKey, NSImage)? in
            let aiModel = overrideModel ?? RenderEngine.resolvedAIModelDirectory
            guard let store = try? MacEditPersistence(directory: directory),
                  let plan = try? MacPhotoPreviewPlan(record: record, films: films, aiModelDirectory: aiModel),
                  (try? plan.isCurrent(in: store, films: films, aiModelDirectory: overrideModel ?? RenderEngine.resolvedAIModelDirectory)) == true else { return nil }
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

    private func beginEditedRender(for record: MacPhotoEditRecord) -> (generation: UInt64, editedRevision: PhotoThumbnails.EditedRevision?) {
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
    private func handlePersistedRecordChange(_ record: MacPhotoEditRecord, preInvalidatedThumbnails: Bool) -> Bool {
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
        NotificationCenter.default.publisher(for: MacEditPersistence.didChangeRecordsNotification)
            .sink { [weak self] notification in
                guard notification.userInfo?[MacEditPersistence.directoryPathUserInfoKey] as? String == targetDirectory,
                      let changes = notification.userInfo?[MacEditPersistence.changedRecordsUserInfoKey] as? [String: MacPhotoEditRecord] else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        for record in changes.values {
                            _ = self.handlePersistedRecordChange(record, preInvalidatedThumbnails: false)
                        }
                        if !changes.isEmpty { self.refresh() }
                    }
                } else {
                    let revisions = notification.userInfo?[MacEditPersistence.editedRevisionsUserInfoKey] as? [String: String]
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

        NotificationCenter.default.publisher(for: MacEditPersistence.didInvalidateEditedNotification)
            .sink { [weak self] notification in
                guard notification.userInfo?[MacEditPersistence.directoryPathUserInfoKey] as? String == targetDirectory,
                      let paths = notification.userInfo?[MacEditPersistence.invalidatedPathsUserInfoKey] as? Set<String> else { return }
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

        NotificationCenter.default.publisher(for: RenderEngine.aiModelAvailabilityDidChangeNotification)
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refresh() }
                } else {
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
            .store(in: &persistenceCancellables)
    }

    private func invalidateAllTrackedEdited() -> Bool {
        let paths = Set(activeKeys.compactMap { $0.value.isEdited ? $0.key : nil })
            .union(trackedEditStates.keys)
        var changed = false
        for path in paths {
            if invalidateEdited(atPath: path) {
                changed = true
            }
        }
        return changed
    }

    private func reconcileFilmsChange(from oldFilms: [Film], to newFilms: [Film]) {
        let currentByID = Dictionary(uniqueKeysWithValues: newFilms.map { ($0.id, $0.url) })
        let currentByBrowserID = Dictionary(uniqueKeysWithValues: newFilms.map { ($0.browserID, $0.url) })
        var invalidatedIDs = Set<String>()
        var invalidatedURLs = Set<URL>()
        for film in oldFilms where currentByID[film.id] != film.url || currentByBrowserID[film.browserID] != film.url {
            invalidatedIDs.insert(film.id)
            invalidatedIDs.insert(film.browserID)
            invalidatedURLs.insert(film.url)
        }
        guard !invalidatedIDs.isEmpty else { return }

        // Synchronously invalidate currently watched/visible tiles whose look resource URL changed.
        var invalidatedWatched = false
        for (photoURL, watchedResources) in resourceWatches where !watchedResources.isDisjoint(with: invalidatedURLs) {
            if invalidateEdited(atPath: PhotoThumbnailCacheKey.canonicalPath(for: photoURL)) {
                invalidatedWatched = true
            }
        }

        // Offload the full edits.json scan + corrupt-record diagnostics off @MainActor.
        filmScanGeneration &+= 1
        let generation = filmScanGeneration
        let directory = editDirectory
        isScanningFilmChanges = true
        Task.detached(priority: .utility) { [weak self] in
            let scan: MacEditPersistence.FilmReferenceScanResult
            do {
                let store = try MacEditPersistence(directory: directory)
                scan = store.scanPathsReferencingFilms(invalidatedIDs)
            } catch {
                let message = "Failed to open edit registry during film invalidation: \(error.localizedDescription)"
                Self.logger.error("\(message, privacy: .public)")
                scan = MacEditPersistence.FilmReferenceScanResult(
                    matchedPaths: [],
                    corruptPaths: [],
                    registryUnreadable: true,
                    diagnostics: [message]
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !scan.diagnostics.isEmpty {
                    self.lastFilmScanDiagnostics = scan.diagnostics
                    for message in scan.diagnostics {
                        Self.logger.error("\(message, privacy: .public)")
                    }
                }
                var changed = false
                if scan.registryUnreadable {
                    changed = self.invalidateAllTrackedEdited()
                } else {
                    for path in scan.pathsToInvalidate {
                        if self.invalidateEdited(atPath: path) {
                            changed = true
                        }
                    }
                }
                if self.filmScanGeneration == generation {
                    self.isScanningFilmChanges = false
                }
                if changed || invalidatedWatched {
                    self.refresh()
                }
            }
        }
    }

    func renderStats() async -> (renders: Int, diskReads: Int, decodes: Int) {
        let stats = await worker.stats()
        return (stats.renders, stats.diskReads, imageDecodeCount)
    }

    private func invalidateWatchedPhoto(_ photoURL: URL) {
        let path = PhotoThumbnailCacheKey.canonicalPath(for: photoURL)
        activeKeys.removeValue(forKey: path)
        if accepted?.record.identity.path == path { accepted = nil }
        _ = markLocalEditedInvalidated(atPath: path)
        thumbnails.invalidate(atPath: path)
    }

    private func updateOrRebindWatch(_ url: URL, currentFingerprint: FileStatFingerprint?, previous: FileWatch) {
        if currentFingerprint == nil || currentFingerprint?.inode != previous.fingerprint?.inode || previous.source == nil {
            rebindWatch(url)
        } else {
            watches[url]?.fingerprint = currentFingerprint
        }
    }

    private func watchedFileDidChange(_ url: URL) {
        guard let existing = watches[url] else { return }
        let path = PhotoThumbnailCacheKey.canonicalPath(for: url)
        let currentFingerprint = FileStatFingerprint(resolvedPath: path)
        // 忽略仅更新 atime 等未改变文件/目录实质状态的事件（防止读取缩略图触发自刷新死循环）。
        guard currentFingerprint != existing.fingerprint else { return }
        updateOrRebindWatch(url, currentFingerprint: currentFingerprint, previous: existing)

        let isWatchedPhoto = watchedPhotos[url] != nil || resourceWatches[url] != nil
        if isWatchedPhoto {
            invalidateWatchedPhoto(url)
        }
        var affectedPhotos = isWatchedPhoto
        let isDirectoryEvent = (currentFingerprint ?? existing.fingerprint).map { !$0.isRegularFile } ?? false
        if isDirectoryEvent {
            var watchedChildren = Set<URL>()
            for photoURL in resourceWatches.keys where photoURL.deletingLastPathComponent() == url {
                watchedChildren.insert(photoURL)
            }
            for photoURL in watchedPhotos.keys where photoURL.deletingLastPathComponent() == url {
                watchedChildren.insert(photoURL)
            }
            for resources in resourceWatches.values {
                for resource in resources where resource != url && resource.deletingLastPathComponent() == url {
                    watchedChildren.insert(resource)
                }
            }
            var changedChildren = Set<URL>()
            var deletedChildren = Set<URL>()
            for child in watchedChildren {
                guard let childWatch = watches[child] else { continue }
                let childFP = FileStatFingerprint(resolvedPath: PhotoThumbnailCacheKey.canonicalPath(for: child))
                if childWatch.fingerprint != childFP {
                    updateOrRebindWatch(child, currentFingerprint: childFP, previous: childWatch)
                    changedChildren.insert(child)
                    if childFP == nil { deletedChildren.insert(child) }
                }
            }
            for (photoURL, resources) in resourceWatches where photoURL != url && resources.contains(url) {
                if changedChildren.contains(photoURL) {
                    invalidateWatchedPhoto(photoURL)
                    affectedPhotos = true
                }
                let childResources = resources.filter { $0 != url && $0.deletingLastPathComponent() == url }
                if !childResources.isEmpty {
                    for resource in childResources where changedChildren.contains(resource) {
                        if deletedChildren.contains(resource) {
                            _ = invalidateEdited(atPath: PhotoThumbnailCacheKey.canonicalPath(for: photoURL))
                        }
                        affectedPhotos = true
                    }
                } else if url != photoURL.deletingLastPathComponent() {
                    affectedPhotos = true
                }
            }
            for photoURL in watchedPhotos.keys where resourceWatches[photoURL] == nil && changedChildren.contains(photoURL) {
                invalidateWatchedPhoto(photoURL)
                affectedPhotos = true
            }
        } else {
            for (photoURL, resources) in resourceWatches where photoURL != url && resources.contains(url) {
                guard url != photoURL.deletingLastPathComponent() else { continue }
                if currentFingerprint == nil {
                    _ = invalidateEdited(atPath: PhotoThumbnailCacheKey.canonicalPath(for: photoURL))
                }
                affectedPhotos = true
            }
        }
        if affectedPhotos {
            refresh()
        }
    }

    private func openWatch(for url: URL, readers: Int) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            let fingerprint = FileStatFingerprint(resolvedPath: PhotoThumbnailCacheKey.canonicalPath(for: url))
            watches[url] = FileWatch(source: nil, readers: readers, fingerprint: fingerprint)
            return
        }
        let fingerprint = FileStatFingerprint.fileDescriptor(descriptor)
        // 不监听 .attrib：读取文件更新 atime 会触发 NOTE_ATTRIB，导致缩略图解码自取消死循环。
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.watchedFileDidChange(url) } }
        source.setCancelHandler { close(descriptor) }
        watches[url] = FileWatch(source: source, readers: readers, fingerprint: fingerprint)
        source.resume()
    }

    private func retainWatch(_ url: URL) {
        if var watch = watches[url] {
            watch.readers += 1
            watches[url] = watch
            return
        }
        openWatch(for: url, readers: 1)
    }

    private func releaseWatch(_ url: URL) {
        guard var watch = watches[url] else { return }
        if watch.readers > 1 {
            watch.readers -= 1
            watches[url] = watch
            return
        }
        watch.source?.cancel()
        watches.removeValue(forKey: url)
    }

    private func rebindWatch(_ url: URL) {
        guard let previous = watches.removeValue(forKey: url) else { return }
        previous.source?.cancel()
        guard previous.readers > 0 else { return }
        openWatch(for: url, readers: previous.readers)
    }

    func watch(_ url: URL) {
        watchedPhotos[url, default: 0] += 1
        retainWatch(url)
    }
    func unwatch(_ url: URL) {
        if let count = watchedPhotos[url] {
            if count > 1 {
                watchedPhotos[url] = count - 1
            } else {
                watchedPhotos.removeValue(forKey: url)
                let resources = resourceWatches.removeValue(forKey: url) ?? []
                for resource in resources { releaseWatch(resource) }
            }
            releaseWatch(url)
        } else {
            releaseWatch(url)
            if watches[url] == nil {
                let resources = resourceWatches.removeValue(forKey: url) ?? []
                for resource in resources { releaseWatch(resource) }
            }
        }
    }
    func refreshWatch(_ url: URL) {
        guard let existing = watches[url] else { return }
        let current = FileStatFingerprint(resolvedPath: PhotoThumbnailCacheKey.canonicalPath(for: url))
        guard existing.source == nil || existing.fingerprint != current else { return }
        rebindWatch(url)
    }
    deinit { for watch in watches.values { watch.source?.cancel() } }
    func record(for url: URL) async throws -> MacPhotoEditRecord {
        let canonicalPath = PhotoThumbnailCacheKey.canonicalPath(for: url)
        let editGenBeforeRead = thumbnails.editGeneration(forPath: canonicalPath)
        let record = try await worker.record(for: url)
        let fileIdentity = record.identity.thumbnailFileIdentity
        let stateRevision = MacPhotoPreviewPlan.editedRevision(for: record.state, atPath: record.identity.path)
        let editedRevision = stateRevision.map { PhotoThumbnails.EditedRevision(identity: fileIdentity, revision: $0) }
        let edited = editedRevision != nil
        let films = films, overrideModel = aiModelDirectory
        let planInfo = await Task.detached(priority: .utility) { () -> (key: PhotoPreviewCacheKey, resources: [URL])? in
            let aiModel = overrideModel ?? RenderEngine.resolvedAIModelDirectory
            guard let plan = try? MacPhotoPreviewPlan(record: record, films: films, aiModelDirectory: aiModel) else { return nil }
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
            if let filmID = state.filmID {
                if let film = films.first(where: { $0.id == filmID || $0.browserID == filmID }) {
                    candidates.append(film.url)
                } else if filmID.hasPrefix("/") { candidates.append(URL(fileURLWithPath: filmID)) }
            }
            if let hdr = state.settings.hdr, state.settings.isHDREditing {
                if let asset = hdr.lookSettings.asset() { candidates.append(asset) }
                if hdr.cameraDevelopmentSettings.cameraProfile != nil { candidates.append(HDRCameraProfileAssetStore.directory) }
            }
        }
        var next = Set(candidates + candidates.map { $0.deletingLastPathComponent() } + [url.deletingLastPathComponent()])
        if resources.isEmpty, edited { next.formUnion(previous) }
        for removed in previous.subtracting(next) { releaseWatch(removed) }
        for added in next.subtracting(previous) { retainWatch(added) }
        for retained in next.intersection(previous) { refreshWatch(retained) }
        resourceWatches[url] = next
        return record
    }
    func image(for record: MacPhotoEditRecord) async throws -> NSImage {
        if let hit = await cachedImage(for: record) { return hit }
        let (editGen, editedRevision) = beginEditedRender(for: record)
        if let accepted, accepted.record == record, let ready = await accepted.task.value {
            let films = films, directory = editDirectory, overrideModel = aiModelDirectory
            let current = await Task.detached(priority: .utility) {
                let aiModel = overrideModel ?? RenderEngine.resolvedAIModelDirectory
                guard let store = try? MacEditPersistence(directory: directory),
                      let plan = try? MacPhotoPreviewPlan(record: record, films: films, aiModelDirectory: aiModel) else { return false }
                return plan.key == ready.key && (try? plan.isCurrent(in: store, films: films, aiModelDirectory: overrideModel ?? RenderEngine.resolvedAIModelDirectory)) == true
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
        let usesAI = record.state?.settings.activeAIDenoise == true
        let readerLease = usesAI ? aiModelAccessTracker.beginReader() : nil
        if usesAI {
            activeAIThumbnailTasks += 1
            isRunningAIThumbnail = true
        }
        defer {
            readerLease?.end()
            if usesAI {
                activeAIThumbnailTasks = max(0, activeAIThumbnailTasks - 1)
                isRunningAIThumbnail = activeAIThumbnailTasks > 0
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
    func accept(record: MacPhotoEditRecord, image: CGImage) {
        guard MacPhotoPreviewPlan.isEdited(record) else {
            _ = invalidateEdited(atPath: record.identity.path)
            return
        }
        let (editGen, editedRevision) = beginEditedRender(for: record)
        let films = films, directory = editDirectory, cache = cache, thumbnails = thumbnails, overrideModel = aiModelDirectory
        let task = Task.detached(priority: .utility) { () -> MacAcceptedPhotoPreview? in
            do {
                let store = try MacEditPersistence(directory: directory)
                var decodedImage: NSImage?
                let acceptedResult = try EditedPhotoPreviewCoordinator.acceptThumbnail(
                    cache: cache,
                    makePlan: { try MacPhotoPreviewPlan(record: record, films: films, aiModelDirectory: overrideModel ?? RenderEngine.resolvedAIModelDirectory) },
                    isCurrent: { try $0.isCurrent(in: store, films: films, aiModelDirectory: overrideModel ?? RenderEngine.resolvedAIModelDirectory) },
                    key: { $0.key },
                    encode: {
                        let data = try MacPhotoPreviewPlan.thumbnailData(image)
                        guard let decoded = MacPhotoPreviewPlan.decodeThumbnailImage(data) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        decodedImage = decoded
                        return data
                    },
                    onAccepted: { plan, _ in
                        guard let decoded = decodedImage else { return }
                        let cacheKey = PhotoThumbnailCacheKey(identity: record.identity, previewKey: plan.key)
                        thumbnails.store(decoded, for: cacheKey, expectedEditGeneration: editGen)
                    }
                )
                guard let decoded = decodedImage else { return nil }
                return MacAcceptedPhotoPreview(key: acceptedResult.key, image: decoded)
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

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T? = nil) { self.value = value }
}

private final class AIProgressRelay: @unchecked Sendable {
    enum Event: Sendable {
        case update(AIPreparationProgress, UInt64, UUID)
        case clear(UUID)
    }

    let token = UUID()
    private let path: String
    private let fileName: String
    private let lock = NSLock()
    private var closed = false
    private var sequence: UInt64 = 0
    private let sink: (@Sendable (Event) -> Void)?

    init(path: String, fileName: String, sink: (@Sendable (Event) -> Void)?) {
        self.path = path
        self.fileName = fileName
        self.sink = sink
    }

    func emit(phase: Int, done: UInt64, total: UInt64) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        sequence &+= 1
        let seq = sequence
        lock.unlock()
        let update = AIPreparationProgress(path: path, fileName: fileName, phase: phase, done: done, total: total)
        sink?(.update(update, seq, token))
    }

    func finish() {
        lock.lock()
        closed = true
        lock.unlock()
        sink?(.clear(token))
    }
}

// 独立会话串行显影；任务只来自仍显示的 tile，离屏或修订后的任务会取消。
private actor MacPhotoPreviewWorker {
    let editDirectory: URL
    let cache: EditedPhotoPreviewCache
    private let aiModelDirectory: URL?
    private let aiModelAccessTracker: AIModelAccessTracker
    private let prepareAI: (@Sendable (URL, Adjustments, AIPreparation) throws -> Void)?
    private let renderThumbnail: (@Sendable (URL, Adjustments, URL?) throws -> CGImage?)?
    private let aiProgressSink: (@Sendable (AIProgressRelay.Event) -> Void)?
    private var renderCount = 0
    private var diskReadCount = 0
    init(editDirectory: URL, cache: EditedPhotoPreviewCache,
         aiModelDirectory: URL? = nil,
         aiModelAccessTracker: AIModelAccessTracker = .shared,
         prepareAI: (@Sendable (URL, Adjustments, AIPreparation) throws -> Void)? = nil,
         renderThumbnail: (@Sendable (URL, Adjustments, URL?) throws -> CGImage?)? = nil,
         aiProgressSink: (@Sendable (AIProgressRelay.Event) -> Void)? = nil) {
        self.editDirectory = editDirectory
        self.cache = cache
        self.aiModelDirectory = aiModelDirectory
        self.aiModelAccessTracker = aiModelAccessTracker
        self.prepareAI = prepareAI
        self.renderThumbnail = renderThumbnail
        self.aiProgressSink = aiProgressSink
    }
    func stats() -> (renders: Int, diskReads: Int) { (renderCount, diskReadCount) }
    nonisolated func record(for url: URL) async throws -> MacPhotoEditRecord {
        try Task.checkCancellation()
        return try MacEditPersistence(directory: editDirectory).readState(for: url)
    }
    func image(for record: MacPhotoEditRecord, films: [Film]) async throws -> (key: PhotoPreviewCacheKey, image: NSImage) {
        let relay = AIProgressRelay(path: record.identity.path,
                                    fileName: URL(fileURLWithPath: record.identity.path).lastPathComponent,
                                    sink: aiProgressSink)
        let progress = AIPreparation(progress: { phase, done, total in
            relay.emit(phase: phase, done: done, total: total)
        })
        return try await withTaskCancellationHandler {
            try render(record, films: films, progress: progress, relay: relay)
        } onCancel: { progress.cancel() }
    }
    private func render(_ record: MacPhotoEditRecord, films: [Film], progress: AIPreparation,
                        relay: AIProgressRelay) throws -> (key: PhotoPreviewCacheKey, image: NSImage) {
        let store = try MacEditPersistence(directory: editDirectory)
        let overrideModel = aiModelDirectory
        var decodedImage: NSImage?
        var cacheHit = false
        var cacheMiss = false
        let outcome = try EditedPhotoPreviewCoordinator.loadOrRenderThumbnail(
            cache: cache,
            makePlan: { try MacPhotoPreviewPlan(record: record, films: films, aiModelDirectory: overrideModel ?? RenderEngine.resolvedAIModelDirectory) },
            isCurrent: { try $0.isCurrent(in: store, films: films, aiModelDirectory: overrideModel ?? RenderEngine.resolvedAIModelDirectory) },
            key: { $0.key },
            decodeCached: { data in
                guard let decoded = MacPhotoPreviewPlan.decodeThumbnailImage(data) else { return false }
                decodedImage = decoded
                return true
            },
            render: { plan in
                guard let settings = record.state?.settings else { throw AdjustmentCommitError.expired }
                let workerLease = settings.activeAIDenoise ? aiModelAccessTracker.beginReader() : nil
                defer { workerLease?.end() }
                let engine = (prepareAI == nil || renderThumbnail == nil) ? try RenderEngine() : nil
                if settings.activeAIDenoise {
                    defer { relay.finish() }
                    relay.emit(phase: 0, done: 0, total: 0)
                    if let prepareAI {
                        try prepareAI(plan.url, settings, progress)
                    } else if let engine {
                        try RenderEngine.validateAIInput(plan.url, settings: settings)
                        try engine.prepareAI(plan.url, settings: settings, progress: progress)
                    }
                }
                try Task.checkCancellation()
                if let renderThumbnail {
                    guard let custom = try renderThumbnail(plan.url, settings, plan.look) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return custom
                } else {
                    guard let frame = try engine!.render(plan.url, settings: settings, lut: plan.look,
                        edge: MacPhotoPreviewPlan.edge, viewportPreview: true) else { throw CocoaError(.fileReadCorruptFile) }
                    return frame.image
                }
            },
            encode: { cgImage in
                let data = try MacPhotoPreviewPlan.thumbnailData(cgImage)
                guard let decoded = MacPhotoPreviewPlan.decodeThumbnailImage(data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                decodedImage = decoded
                return data
            },
            onCacheHit: { cacheHit = true },
            onCacheMissWrite: { _, _ in cacheMiss = true }
        )
        if cacheHit { diskReadCount += 1 }
        if cacheMiss { renderCount += 1 }
        guard let decoded = decodedImage else { throw CocoaError(.fileReadCorruptFile) }
        return (outcome.key, decoded)
    }
}
