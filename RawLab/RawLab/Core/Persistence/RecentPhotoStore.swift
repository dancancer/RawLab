import CryptoKit
import Darwin
import Foundation

struct RecentPhoto: Codable, Equatable, Identifiable {
    let identity: PhotoIdentity
    let displayName: String
    let isRaw: Bool
    let originalFile: String
    let originalBytes: Int
    let openedAt: Date
    var previewKey: String?
    var id: String { identity.key }
}

enum RecentPhotoError: LocalizedError {
    case originalChanged, unavailable, corruptIndex
    var errorDescription: String? {
        switch self {
        case .originalChanged: L10n.text("原片已变化，请重新选择照片。原有调整已保留。")
        case .unavailable: L10n.text("无法重新打开这张照片，请重新选择。原有调整已保留。")
        case .corruptIndex: L10n.text("无法读取最近打开的照片，原有记录未被覆盖。")
        }
    }
}

// 最近记录保存私有原片副本，避免 PhotosPicker / Files 临时文件在退出后失效。
// 保留最近 100 张及约 2 GiB；单张超限仍保留最新一张，不改写外部原片或编辑记录。
final class RecentPhotoStore: @unchecked Sendable {
    private struct Index: Codable { var version = 1; var photos: [RecentPhoto] = [] }
    let directory: URL
    private let maximumEntries: Int
    private let maximumOriginalBytes: Int
    private let lock = NSLock()
    private let writeData: (Data, URL) throws -> Void
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var originals: URL { directory.appendingPathComponent("Originals", isDirectory: true) }
    private var previews: URL { directory.appendingPathComponent("Previews", isDirectory: true) }

    init(directory: URL, maximumEntries: Int = 100, maximumOriginalBytes: Int = 2 * 1024 * 1024 * 1024,
         writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.directory = directory
        self.maximumEntries = max(1, maximumEntries)
        self.maximumOriginalBytes = max(1, maximumOriginalBytes)
        self.writeData = writeData
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        _ = try readIndex()
        var root = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    static func appStore() throws -> RecentPhotoStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try RecentPhotoStore(directory: root.appendingPathComponent("RawLab/RecentPhotos", isDirectory: true))
    }

    func records() throws -> [RecentPhoto] { try readIndex().photos }

    @discardableResult func recordOpened(url: URL, identity: PhotoIdentity, displayName: String,
                                         isRaw: Bool, now: Date = Date()) throws -> RecentPhoto {
        try withWriteLock {
            var index = try readIndex()
            let measured = try PhotoIdentity.cachedFallback(for: url, resourceIdentifier: identity.resourceIdentifier)
            if let expected = identity.contentIdentifier, measured.contentIdentifier != expected { throw RecentPhotoError.originalChanged }
            let stable = PhotoIdentity(resourceIdentifier: identity.resourceIdentifier,
                contentIdentifier: measured.contentIdentifier, legacyContentIdentifier: identity.legacyContentIdentifier)
            let previous = index.photos.first { $0.id == stable.key && $0.identity.contentIdentifier == stable.contentIdentifier }
            let ext = url.pathExtension.lowercased()
            let safeExtension = ext.count <= 12 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "photo"
            let filename = previous?.originalFile ?? UUID().uuidString + "." + safeExtension
            let destination = originals.appendingPathComponent(filename)
            var copied = false
            if (try? PhotoIdentity.cachedFallback(for: destination).contentIdentifier) != measured.contentIdentifier {
                let temporary = originals.appendingPathComponent(UUID().uuidString + ".pending")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: url, to: temporary)
                guard try PhotoIdentity.fallback(for: temporary).contentIdentifier == measured.contentIdentifier else {
                    throw RecentPhotoError.originalChanged
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                copied = previous == nil
            }
            let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let photo = RecentPhoto(identity: stable, displayName: displayName, isRaw: isRaw,
                originalFile: filename, originalBytes: bytes, openedAt: now, previewKey: previous?.previewKey)
            index.photos.removeAll { $0.id == photo.id }
            index.photos.insert(photo, at: 0)
            var total = index.photos.reduce(0) { $0 + $1.originalBytes }
            while index.photos.count > 1 && (index.photos.count > maximumEntries || total > maximumOriginalBytes) {
                total -= index.photos.removeLast().originalBytes
            }
            do { try save(index) }
            catch {
                if copied { try? FileManager.default.removeItem(at: destination) }
                throw error
            }
            cleanUnusedFiles(index)
            return photo
        }
    }

    func sourceURL(for photo: RecentPhoto) throws -> URL {
        guard let stored = try readIndex().photos.first(where: { $0.id == photo.id }), stored.identity == photo.identity else {
            throw RecentPhotoError.unavailable
        }
        let url = originals.appendingPathComponent(stored.originalFile)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw RecentPhotoError.unavailable }
        guard try PhotoIdentity.cachedFallback(for: url).contentIdentifier == photo.identity.contentIdentifier else {
            throw RecentPhotoError.originalChanged
        }
        return url
    }

    func remove(_ id: String) throws {
        try withWriteLock {
            var index = try readIndex()
            index.photos.removeAll { $0.id == id }
            try save(index)
            cleanUnusedFiles(index)
        }
    }

    func savePreview(_ data: Data, key: PhotoPreviewCacheKey, for identity: PhotoIdentity) throws {
        guard data.count <= 2 * 1024 * 1024 else { return }
        try withWriteLock {
            var index = try readIndex()
            guard let row = index.photos.firstIndex(where: { $0.identity == identity }) else { return }
            try data.write(to: previews.appendingPathComponent(key.digest + ".preview"), options: .atomic)
            index.photos[row].previewKey = key.digest
            try save(index)
            cleanUnusedFiles(index)
        }
    }

    func lastPreview(for photo: RecentPhoto) throws -> Data? {
        guard let stored = try readIndex().photos.first(where: { $0.identity == photo.identity }), let key = stored.previewKey else { return nil }
        return try Data(contentsOf: previews.appendingPathComponent(key + ".preview"))
    }

    private func readIndex() throws -> Index {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return Index() }
        let index: Index
        do { index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)) }
        catch { throw RecentPhotoError.corruptIndex }
        guard index.version == 1, Set(index.photos.map(\.id)).count == index.photos.count,
              index.photos.allSatisfy({ photo in
                  let name = photo.originalFile
                  return !name.isEmpty && name != "." && name != ".." && URL(fileURLWithPath: name).lastPathComponent == name &&
                      !name.contains("/") && photo.originalBytes >= 0 && photo.identity.contentIdentifier != nil &&
                      (photo.previewKey.map(HDRLookSettings.isFingerprint) ?? true)
              }) else { throw RecentPhotoError.corruptIndex }
        return index
    }

    private func save(_ index: Index) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try writeData(encoder.encode(index), indexURL)
    }

    private func cleanUnusedFiles(_ index: Index) {
        let keepOriginals = Set(index.photos.map(\.originalFile))
        let keepPreviews = Set(index.photos.compactMap(\.previewKey).map { $0 + ".preview" })
        for (folder, names) in [(originals, keepOriginals), (previews, keepPreviews)] {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if !names.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let descriptor = open(directory.appendingPathComponent(".recent.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
