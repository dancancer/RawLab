import SwiftUI
import AppKit
import ImageIO
import Combine

struct DirectoryContents {
    let folders: [URL]
    let photos: [URL]
    static let rawExtensions: Set<String> = ["arw", "arq", "dng", "nef", "nrw", "cr2", "cr3", "crw", "raf",
        "rw2", "rwl", "orf", "pef", "srw", "raw", "3fr", "fff", "iiq", "mos", "srf", "sr2", "mrw", "kdc", "dcr", "erf", "x3f"]
    static let supportedExtensions = rawExtensions.union(["jpg", "jpeg", "png", "tif", "tiff", "heif", "heic"])

    static func photoURLs(from urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { candidate in
            guard candidate.isFileURL else { return nil }
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func read(_ url: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        let entries = try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var folders: [URL] = [], photos: [URL] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: keys)
            if values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true {
                folders.append(entry)
            } else if values.isRegularFile == true && supportedExtensions.contains(entry.pathExtension.lowercased()) {
                photos.append(entry)
            }
        }
        let sorted: ([URL]) -> [URL] = { $0.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
        return Self(folders: sorted(folders), photos: sorted(photos))
    }
}

final class PhotoFolder: ObservableObject, Identifiable {
    let url: URL
    var id: URL { url }
    @Published var expanded = false
    @Published private(set) var folders: [PhotoFolder] = [] {
        didSet {
            folderSubscriptions = folders.map { child in
                child.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            }
        }
    }
    @Published private(set) var photos: [URL] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var contentRevision = 0
    private var loaded = false
    private var loadWaiters: [() -> Void] = []
    var canExpand: Bool { !loaded || !folders.isEmpty }
    var isExpandedInTree: Bool { expanded && canExpand }
    private var folderSubscriptions: [AnyCancellable] = []
    init(_ url: URL) { self.url = url }

    func toggle() { expanded.toggle(); if expanded { load() } }
    func load(then completion: @escaping () -> Void) {
        if loaded { completion(); return }
        loadWaiters.append(completion)
        load()
    }
    func refresh() {
        guard !loading else { return }
        PhotoThumbnails.shared.invalidateDirectory(url)
        loaded = false
        load()
    }
    func load() {
        guard !loaded, !loading else { return }
        loading = true; error = nil
        let url = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DirectoryContents.read(url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.contentRevision &+= 1
                switch result {
                case .success(let contents):
                    let existing = Dictionary(uniqueKeysWithValues: self.folders.map { ($0.id, $0) })
                    self.folders = contents.folders.map { existing[$0] ?? PhotoFolder($0) }
                    self.photos = contents.photos; self.loaded = true
                case .failure(let error): self.error = error.localizedDescription
                }
                let waiters = self.loadWaiters
                self.loadWaiters.removeAll()
                waiters.forEach { $0() }
            }
        }
    }
}

final class PhotoLibrary: ObservableObject {
    @Published private(set) var roots: [PhotoFolder] {
        didSet { observeRoots() }
    }
    private var rootSubscriptions: [AnyCancellable] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        roots = (defaults.stringArray(forKey: "photoFolders") ?? [])
            .map { PhotoFolder(URL(fileURLWithPath: $0)) }
        observeRoots()
    }
    private func observeRoots() {
        rootSubscriptions = roots.map { root in
            root.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    func addDirectories() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("添加照片目录")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addDirectories(panel.urls)
    }
    @discardableResult func addDirectories(_ urls: [URL]) -> Bool {
        var accepted = false
        for candidate in urls where candidate.isFileURL {
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true, values.isPackage != true else { continue }
            accepted = true
            if let existing = roots.first(where: { $0.url == url }) {
                existing.expanded = true; existing.load()
            } else {
                let folder = PhotoFolder(url); roots.append(folder); folder.toggle()
            }
        }
        if accepted { persist() }
        return accepted
    }
    func remove(_ root: PhotoFolder) {
        PhotoThumbnails.shared.invalidateDirectory(root.url)
        roots.removeAll { $0.id == root.id }
        persist()
    }
    private func persist() { defaults.set(roots.map { $0.url.path }, forKey: "photoFolders") }
}

struct PhotoThumbnailCacheKey: Hashable, Sendable {
    let path: String
    let fileSize: UInt64
    let modified: Date
    let fileNumber: UInt64
    let maxPixelSize: Int
    let appliesAdjustments: Bool
    let adjustmentRevision: String?

    static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    init(path: String, fileSize: UInt64, modified: Date, fileNumber: UInt64,
         maxPixelSize: Int, appliesAdjustments: Bool, adjustmentRevision: String? = nil) {
        self.path = path
        self.fileSize = fileSize
        self.modified = modified
        self.fileNumber = fileNumber
        self.maxPixelSize = maxPixelSize
        self.appliesAdjustments = appliesAdjustments
        self.adjustmentRevision = appliesAdjustments ? adjustmentRevision : nil
    }

    var fileIdentity: PhotoThumbnails.FileIdentity {
        .init(fileSize: fileSize, modified: modified, fileNumber: fileNumber)
    }

    init?(uneditedFileAt url: URL, maxPixelSize: Int = PhotoThumbnails.defaultMaxPixelSize) {
        let path = Self.canonicalPath(for: url)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        self.init(path: path, fileSize: size.uint64Value, modified: modified, fileNumber: fileNumber,
                  maxPixelSize: maxPixelSize, appliesAdjustments: false, adjustmentRevision: nil)
    }
}

// NSCache and OperationQueue are thread-safe; cached CGImage-backed images are immutable.
final class PhotoThumbnails: @unchecked Sendable {
    private final class EntryKey: NSObject {
        let value: PhotoThumbnailCacheKey
        init(_ value: PhotoThumbnailCacheKey) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Self else { return false }
            return value == other.value
        }
    }

    private struct InFlightKey: Hashable {
        let key: PhotoThumbnailCacheKey
        let generation: UInt64
    }

    struct FileIdentity: Hashable, Sendable {
        let fileSize: UInt64
        let modified: Date
        let fileNumber: UInt64
    }

    struct EditedRevision: Hashable, Sendable {
        let identity: FileIdentity
        let revision: String
    }

    enum TrackedEditState: Equatable {
        case cached(FileIdentity)
        case revision(EditedRevision)
        case invalidated(EditedRevision)

        var identity: FileIdentity {
            switch self {
            case .cached(let identity):
                return identity
            case .revision(let edited), .invalidated(let edited):
                return edited.identity
            }
        }
    }

    static let defaultMaxPixelSize = 180
    static let defaultTotalCostLimit = 64 * 1024 * 1024
    static let defaultCountLimit = 512
    static let shared = PhotoThumbnails(observesEditPersistence: true)

    let totalCostLimit: Int
    let countLimit: Int
    private let cache = NSCache<EntryKey, NSImage>()
    private let lock = NSLock()
    private var keysByPath: [String: Set<PhotoThumbnailCacheKey>] = [:]
    private var fileGenerations: [String: UInt64] = [:]
    private var editGenerations: [String: UInt64] = [:]
    private var trackedEditStates: [String: TrackedEditState] = [:]
    private var trackedKeyCount = 0
    private var inFlight: [InFlightKey: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var _decodeCount = 0
    private var _editedInvalidationCount = 0
    private var persistenceCancellables: Set<AnyCancellable> = []
    private let decodeThumbnail: @Sendable (URL, Int) -> NSImage?
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility; return queue
    }()

    init(totalCostLimit: Int = PhotoThumbnails.defaultTotalCostLimit,
         countLimit: Int = PhotoThumbnails.defaultCountLimit,
         observesEditPersistence: Bool = false,
         decodeThumbnail: @escaping @Sendable (URL, Int) -> NSImage? = PhotoThumbnails.defaultDecodeThumbnail) {
        self.totalCostLimit = max(1, totalCostLimit)
        self.countLimit = max(1, countLimit)
        self.decodeThumbnail = decodeThumbnail
        cache.totalCostLimit = self.totalCostLimit
        cache.countLimit = self.countLimit
        if observesEditPersistence {
            NotificationCenter.default.publisher(for: Notification.Name("RawLab.EditPersistence.didChangeRecords"))
                .sink { [weak self] notification in
                    guard let paths = notification.userInfo?["invalidatedPaths"] as? Set<String> else { return }
                    let revisions = notification.userInfo?["editedRevisions"] as? [String: String] ?? [:]
                    let identities = notification.userInfo?["fileIdentities"] as? [String: (UInt64, Date, UInt64)] ?? [:]
                    for path in paths {
                        if let revision = revisions[path] {
                            guard let rawIdentity = identities[path] else { continue }
                            let identity = FileIdentity(fileSize: rawIdentity.0, modified: rawIdentity.1, fileNumber: rawIdentity.2)
                            self?.reconcileEditedRevision(EditedRevision(identity: identity, revision: revision), atPath: path)
                        } else {
                            self?.reconcileEditedRevision(nil, atPath: path)
                        }
                    }
                }
                .store(in: &persistenceCancellables)
            NotificationCenter.default.publisher(for: Notification.Name("RawLab.EditPersistence.didInvalidateEdited"))
                .sink { [weak self] notification in
                    guard let paths = notification.userInfo?["invalidatedPaths"] as? Set<String> else { return }
                    for path in paths { self?.invalidateEdited(atPath: path) }
                }
                .store(in: &persistenceCancellables)
        }
    }

    var decodeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _decodeCount
    }

    var editedInvalidationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _editedInvalidationCount
    }

    static func imageCost(_ image: NSImage) -> Int {
        if let bitmap = image.representations.first as? NSBitmapImageRep, bitmap.bytesPerRow > 0, bitmap.pixelsHigh > 0 {
            return max(bitmap.bytesPerRow * bitmap.pixelsHigh, bitmap.pixelsWide * bitmap.pixelsHigh * 4)
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(cgImage.bytesPerRow * cgImage.height, cgImage.width * cgImage.height * 4)
        }
        let rep = image.representations.first
        let width = max(rep?.pixelsWide ?? 0, Int(image.size.width.rounded(.up)))
        let height = max(rep?.pixelsHigh ?? 0, Int(image.size.height.rounded(.up)))
        return max(1, width * height * 4)
    }

    @Sendable private static func defaultDecodeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        let raster = !DirectoryContents.rawExtensions.contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: raster,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func cachedImage(for key: PhotoThumbnailCacheKey) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return cache.object(forKey: EntryKey(key))
    }

    func editGeneration(forPath path: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return editGenerations[path, default: 0]
    }

    func seedEditedRevisionIfUntracked(_ edited: EditedRevision, atPath path: String) -> (generation: UInt64, seeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        if trackedEditStates[path]?.identity != edited.identity {
            trackedEditStates[path] = .revision(edited)
            _ = removeKeysLocked(atPath: path, keeping: edited.identity)
            let next = editGenerations[path, default: 0] &+ 1
            editGenerations[path] = next
            _editedInvalidationCount += 1
            return (next, true)
        }
        return (editGenerations[path, default: 0], false)
    }

    @discardableResult
    func reconcileEditedRevision(_ edited: EditedRevision?, available: Bool = true, atPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let edited else {
            let hadTracked = trackedEditStates.removeValue(forKey: path) != nil
            let removedKeys = removeEditedKeysLocked(atPath: path)
            guard hadTracked || removedKeys else { return false }
            editGenerations[path, default: 0] &+= 1
            _editedInvalidationCount += 1
            return true
        }
        let target: TrackedEditState = available ? .revision(edited) : .invalidated(edited)
        switch trackedEditStates[path] {
        case .revision(edited) where available:
            return false
        case .invalidated(edited):
            return false
        default:
            trackedEditStates[path] = target
            _ = removeKeysLocked(atPath: path, keeping: edited.identity)
            editGenerations[path, default: 0] &+= 1
            _editedInvalidationCount += 1
            return true
        }
    }

    func store(_ image: NSImage, for key: PhotoThumbnailCacheKey, expectedEditGeneration: UInt64? = nil) {
        let cost = Self.imageCost(image)
        lock.lock(); defer { lock.unlock() }
        if let expectedEditGeneration, editGenerations[key.path, default: 0] != expectedEditGeneration {
            return
        }
        if key.appliesAdjustments {
            let fileIdentity = key.fileIdentity
            switch trackedEditStates[key.path] {
            case .invalidated(let edited) where edited.identity == fileIdentity:
                trackedEditStates[key.path] = .revision(edited)
            case .revision(let edited) where edited.identity == fileIdentity:
                break
            case .cached(fileIdentity):
                break
            case .none, .invalidated, .revision, .cached:
                trackedEditStates[key.path] = .cached(fileIdentity)
            }
            if var existing = keysByPath[key.path] {
                for prior in existing where prior.appliesAdjustments && prior != key {
                    existing.remove(prior)
                    trackedKeyCount -= 1
                    cache.removeObject(forKey: EntryKey(prior))
                }
                keysByPath[key.path] = existing
            }
        }
        insertLocked(image, for: key, cost: cost)
    }

    /// Drops every cached key for `path` that cannot belong to `identity`: edited keys are
    /// always stale once a new revision is tracked, and unedited keys decoded from a previous
    /// file identity were rendered from different bytes. Leaving those behind makes the next
    /// `invalidateStaleEntries` sweep report a file change for a path that already moved on,
    /// which discards the fresh identity's active preview and counts a second invalidation.
    private func removeKeysLocked(atPath path: String, keeping identity: FileIdentity) -> Bool {
        guard var keys = keysByPath[path] else { return false }
        let removed = keys.filter { $0.appliesAdjustments || $0.fileIdentity != identity }
        guard !removed.isEmpty else { return false }
        for key in removed {
            keys.remove(key)
            trackedKeyCount -= 1
            cache.removeObject(forKey: EntryKey(key))
        }
        if keys.isEmpty { keysByPath.removeValue(forKey: path) }
        else { keysByPath[path] = keys }
        return true
    }

    private func removeEditedKeysLocked(atPath path: String) -> Bool {
        guard var keys = keysByPath[path] else { return false }
        let removed = keys.filter(\.appliesAdjustments)
        guard !removed.isEmpty else { return false }
        for key in removed {
            keys.remove(key)
            trackedKeyCount -= 1
            cache.removeObject(forKey: EntryKey(key))
        }
        if keys.isEmpty { keysByPath.removeValue(forKey: path) }
        else { keysByPath[path] = keys }
        return true
    }

    private func markEditedInvalidatedLocked(atPath path: String) -> Bool {
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

    private func insertLocked(_ image: NSImage, for key: PhotoThumbnailCacheKey, cost: Int) {
        cache.setObject(image, forKey: EntryKey(key), cost: cost)
        if keysByPath[key.path, default: []].insert(key).inserted {
            trackedKeyCount += 1
        }
        if trackedKeyCount > countLimit * 2 {
            pruneEvictedKeysLocked()
        }
    }

    private func pruneEvictedKeysLocked() {
        var remaining = 0
        for (path, keys) in keysByPath {
            let live = keys.filter { cache.object(forKey: EntryKey($0)) != nil }
            if live.isEmpty {
                keysByPath.removeValue(forKey: path)
            } else {
                keysByPath[path] = live
                remaining += live.count
            }
        }
        trackedKeyCount = remaining
    }

    @discardableResult
    func invalidateEdited(for url: URL) -> Bool {
        invalidateEdited(atPath: PhotoThumbnailCacheKey.canonicalPath(for: url))
    }

    @discardableResult
    func invalidateEdited(atPath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let removedKeys = removeEditedKeysLocked(atPath: path)
        let transitioned = markEditedInvalidatedLocked(atPath: path)
        guard transitioned || removedKeys else { return false }
        editGenerations[path, default: 0] &+= 1
        _editedInvalidationCount += 1
        return true
    }

    func invalidate(for url: URL) {
        invalidate(atPath: PhotoThumbnailCacheKey.canonicalPath(for: url))
    }

    func invalidate(atPath path: String) {
        lock.lock(); defer { lock.unlock() }
        fileGenerations[path, default: 0] &+= 1
        let hadEdited = markEditedInvalidatedLocked(atPath: path) ||
            (keysByPath[path]?.contains(where: \.appliesAdjustments) == true)
        if hadEdited {
            editGenerations[path, default: 0] &+= 1
            _editedInvalidationCount += 1
        }
        guard let keys = keysByPath.removeValue(forKey: path) else { return }
        trackedKeyCount -= keys.count
        for key in keys { cache.removeObject(forKey: EntryKey(key)) }
    }

    func invalidateDirectory(_ url: URL) {
        let directoryPath = PhotoThumbnailCacheKey.canonicalPath(for: url)
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        lock.lock(); defer { lock.unlock() }
        let candidates = Set(keysByPath.keys)
            .union(trackedEditStates.keys)
            .union(inFlight.keys.map(\.key.path))
        for path in candidates where path == directoryPath || path.hasPrefix(prefix) {
            fileGenerations[path, default: 0] &+= 1
            let hadEdited = markEditedInvalidatedLocked(atPath: path) ||
                (keysByPath[path]?.contains(where: \.appliesAdjustments) == true)
            if hadEdited {
                editGenerations[path, default: 0] &+= 1
                _editedInvalidationCount += 1
            }
            if let keys = keysByPath.removeValue(forKey: path) {
                trackedKeyCount -= keys.count
                for key in keys { cache.removeObject(forKey: EntryKey(key)) }
            }
        }
    }

    @discardableResult
    func invalidateStaleEntries(atPath path: String, fileSize: UInt64, modified: Date,
                                fileNumber: UInt64, stateRevision: String? = nil,
                                editedRevision: String?, expectedEditGeneration: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fileIdentity = FileIdentity(fileSize: fileSize, modified: modified, fileNumber: fileNumber)
        var removedFile = false
        var removedEdited = false
        if var keys = keysByPath[path] {
            for key in keys {
                let fileChanged = key.fileIdentity != fileIdentity
                let editChanged = key.appliesAdjustments && (editedRevision == nil || key.adjustmentRevision != editedRevision)
                if fileChanged || editChanged {
                    keys.remove(key)
                    trackedKeyCount -= 1
                    cache.removeObject(forKey: EntryKey(key))
                    if fileChanged { removedFile = true }
                    if key.appliesAdjustments { removedEdited = true }
                }
            }
            if keys.isEmpty { keysByPath.removeValue(forKey: path) }
            else { keysByPath[path] = keys }
        }
        if expectedEditGeneration == nil || editGenerations[path, default: 0] == expectedEditGeneration {
            if let stateRevision {
                let target = EditedRevision(identity: fileIdentity, revision: stateRevision)
                if editedRevision != nil {
                    switch trackedEditStates[path] {
                    case .revision(target), .invalidated(target):
                        break
                    case .cached(fileIdentity):
                        trackedEditStates[path] = .revision(target)
                    case .revision, .invalidated, .cached, .none:
                        trackedEditStates[path] = .revision(target)
                        removedEdited = true
                    }
                } else {
                    switch trackedEditStates[path] {
                    case .invalidated(target):
                        break
                    case .revision, .invalidated, .cached, .none:
                        trackedEditStates[path] = .invalidated(target)
                        removedEdited = true
                    }
                }
            } else if trackedEditStates.removeValue(forKey: path) != nil {
                removedEdited = true
            }
        }
        if removedFile {
            fileGenerations[path, default: 0] &+= 1
            if trackedEditStates[path]?.identity != fileIdentity,
               markEditedInvalidatedLocked(atPath: path) {
                removedEdited = true
            }
        }
        if removedEdited {
            editGenerations[path, default: 0] &+= 1
            _editedInvalidationCount += 1
        }
        return removedFile || removedEdited
    }

    func image(for url: URL, maxPixelSize: Int = PhotoThumbnails.defaultMaxPixelSize) async -> NSImage? {
        guard let key = PhotoThumbnailCacheKey(uneditedFileAt: url, maxPixelSize: maxPixelSize) else { return nil }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let cached = cache.object(forKey: EntryKey(key)) {
                lock.unlock()
                continuation.resume(returning: cached)
                return
            }
            let fileGen = fileGenerations[key.path, default: 0]
            let flightKey = InFlightKey(key: key, generation: fileGen)
            if inFlight[flightKey] != nil {
                inFlight[flightKey]!.append(continuation)
                lock.unlock()
                return
            }
            inFlight[flightKey] = [continuation]
            lock.unlock()

            queue.addOperation { [self] in
                let result = decodeThumbnail(url, maxPixelSize)
                let cost = result.map(Self.imageCost) ?? 0
                lock.lock()
                _decodeCount += 1
                if let result, fileGenerations[key.path, default: 0] == fileGen {
                    insertLocked(result, for: key, cost: cost)
                }
                let waiters = inFlight.removeValue(forKey: flightKey) ?? []
                lock.unlock()
                for waiter in waiters { waiter.resume(returning: result) }
            }
        }
    }
}
