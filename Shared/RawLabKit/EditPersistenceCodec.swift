import CryptoKit
import Darwin
import Foundation

public struct PhotoIdentity: Codable, Equatable, Hashable, Sendable {
    public let resourceIdentifier: String?
    public let contentIdentifier: String?
    public let legacyContentIdentifier: String?

    public init(resourceIdentifier: String) {
        self.resourceIdentifier = resourceIdentifier.isEmpty ? nil : resourceIdentifier
        self.contentIdentifier = nil
        self.legacyContentIdentifier = nil
    }

    public init(contentIdentifier: String) {
        self.resourceIdentifier = nil
        self.contentIdentifier = contentIdentifier.isEmpty ? nil : contentIdentifier
        self.legacyContentIdentifier = nil
    }

    public init(resourceIdentifier: String?, contentIdentifier: String?, legacyContentIdentifier: String? = nil) {
        self.resourceIdentifier = resourceIdentifier?.isEmpty == true ? nil : resourceIdentifier
        self.contentIdentifier = contentIdentifier?.isEmpty == true ? nil : contentIdentifier
        self.legacyContentIdentifier = legacyContentIdentifier?.isEmpty == true ? nil : legacyContentIdentifier
    }

    public var key: String {
        if let resourceIdentifier {
            return "photo:\(resourceIdentifier)"
        }
        if let contentIdentifier {
            return "content:\(contentIdentifier)"
        }
        return "content:missing"
    }

    // Photos keeps the asset identifier when its underlying bytes change.
    public var editKey: String {
        guard let resourceIdentifier, let contentIdentifier else { return key }
        return "photo-content:\(resourceIdentifier.utf8.count):\(resourceIdentifier):\(contentIdentifier)"
    }

    public static func fallback(for url: URL, resourceIdentifier: String? = nil) throws -> PhotoIdentity {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return PhotoIdentity(resourceIdentifier: resourceIdentifier,
                             contentIdentifier: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Computes or returns a cached content identity validated by the resolved file's stat fingerprint.
    public static func cachedFallback(for url: URL,
                                      resourceIdentifier: String? = nil,
                                      digestCache: FileDigestCache = .shared) throws -> PhotoIdentity {
        PhotoIdentity(resourceIdentifier: resourceIdentifier,
                      contentIdentifier: try digestCache.digest(for: url))
    }
}

public struct OriginalFileIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let modified: Date
    public let fileNumber: UInt64

    public init(path: String, size: UInt64, modified: Date, fileNumber: UInt64) {
        self.path = path
        self.size = size
        self.modified = modified
        self.fileNumber = fileNumber
    }

    public init(_ url: URL) throws {
        path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        self.size = size.uint64Value
        self.modified = modified
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    public func requireCurrent() throws {
        guard try OriginalFileIdentity(URL(fileURLWithPath: path)) == self else { throw AdjustmentCommitError.photoChanged }
    }
}

public enum AdjustmentCommitError: Error, Sendable {
    case photoChanged
    case expired
    case historyOrder
}

public enum EditPersistenceError: LocalizedError, Sendable {
    case invalidIdentity
    case corruptStore
    case legacyAssetEditNeedsDecision

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return L10n.text("无法识别原始照片，调整尚未保存。")
        case .corruptStore:
            return L10n.text("无法读取已保存的调整，原有记录未被覆盖。")
        case .legacyAssetEditNeedsDecision:
            return L10n.text("请先打开这张照片，确认是否恢复旧调整。")
        }
    }
}

public struct UnusableEditRecordError: LocalizedError {
    public let message: String
    public let underlying: Error?

    public init(_ message: String = L10n.text("无法读取已保存的调整，原有记录未被覆盖。"), underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying
    }

    public var errorDescription: String? { message }
}

public enum EditStoreJSONCodec {
    public static func isVersionOne(_ slice: Data) -> Bool {
        guard !slice.contains(UInt8(ascii: ".")),
              !slice.contains(UInt8(ascii: "e")),
              !slice.contains(UInt8(ascii: "E")),
              let value = try? JSONDecoder().decode(Int.self, from: slice) else { return false }
        return value == 1
    }

    public static func appendRawMap(_ map: [String: Data], encoder: JSONEncoder, to out: inout Data) throws {
        out.append(UInt8(ascii: "{"))
        var first = true
        for key in map.keys.sorted() {
            if !first { out.append(UInt8(ascii: ",")) }
            first = false
            out.append(try encoder.encode(key))
            out.append(UInt8(ascii: ":"))
            out.append(map[key]!)
        }
        out.append(UInt8(ascii: "}"))
    }

    public static func scanJSONObjectSlices(_ data: Data, error: @autoclosure () -> Error) throws -> [String: Data] {
        let bytes = [UInt8](data)
        var index = 0
        let end = bytes.count
        let decoder = JSONDecoder()

        func skipWhitespace() {
            while index < end {
                let b = bytes[index]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
                else { break }
            }
        }

        func skipString() throws {
            guard index < end, bytes[index] == 0x22 else { throw error() }
            index += 1
            while index < end {
                let b = bytes[index]
                if b == 0x5C {
                    index += 2
                    if index > end { throw error() }
                } else if b == 0x22 {
                    index += 1
                    return
                } else {
                    index += 1
                }
            }
            throw error()
        }

        func scanValue() throws -> Data {
            skipWhitespace()
            guard index < end else { throw error() }
            let start = index
            let first = bytes[index]
            if first == 0x22 {
                try skipString()
            } else if first == 0x7B || first == 0x5B {
                var depth = 1
                index += 1
                while index < end && depth > 0 {
                    let b = bytes[index]
                    if b == 0x22 { try skipString() }
                    else if b == 0x7B || b == 0x5B { depth += 1; index += 1 }
                    else if b == 0x7D || b == 0x5D { depth -= 1; index += 1 }
                    else { index += 1 }
                }
                guard depth == 0 else { throw error() }
            } else {
                while index < end {
                    let b = bytes[index]
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x2C || b == 0x7D || b == 0x5D { break }
                    index += 1
                }
                guard index > start else { throw error() }
            }
            return Data(bytes[start..<index])
        }

        skipWhitespace()
        guard index < end, bytes[index] == 0x7B else { throw error() }
        index += 1
        skipWhitespace()
        var result: [String: Data] = [:]
        if index < end, bytes[index] == 0x7D {
            index += 1
            skipWhitespace()
            guard index == end else { throw error() }
            return result
        }
        while true {
            skipWhitespace()
            let keyStart = index
            try skipString()
            let key = try decoder.decode(String.self, from: Data(bytes[keyStart..<index]))
            guard result[key] == nil else { throw error() }
            skipWhitespace()
            guard index < end, bytes[index] == 0x3A else { throw error() }
            index += 1
            result[key] = try scanValue()
            skipWhitespace()
            guard index < end else { throw error() }
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x7D {
                index += 1
                skipWhitespace()
                guard index == end else { throw error() }
                return result
            } else {
                throw error()
            }
        }
    }
}

public enum EditStoreFileLock {
    public static func withExclusiveLock<T>(directory: URL, lockFileName: String = ".edits.lock", createDirectory: Bool = false, body: () throws -> T) throws -> T {
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let descriptor = open(directory.appendingPathComponent(lockFileName).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

public final class EditStoreRegistryCache<Store>: @unchecked Sendable {
    public static var maximumEntriesDefault: Int { 32 }

    private struct Entry {
        let fingerprint: FileStatFingerprint
        let store: Store
    }

    private let lock = NSLock()
    private let stripeLocks: [NSLock] = (0..<16).map { _ in NSLock() }
    private var cache: BoundedLRUCache<String, Entry>
    private var invalidationEpochs: [String: UInt64] = [:]

    public init(maximumEntries: Int = EditStoreRegistryCache.maximumEntriesDefault) {
        self.cache = BoundedLRUCache(maximumEntries: max(0, maximumEntries))
    }

    public func stripeLock(for resolvedPath: String) -> NSLock {
        stripeLocks[Self.stripeIndex(for: resolvedPath)]
    }

    public func cachedStore(forPath path: String, fingerprint: FileStatFingerprint) -> Store? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache.value(forKey: path), entry.fingerprint == fingerprint else { return nil }
        return entry.store
    }

    public func epoch(for path: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return invalidationEpochs[path, default: 0]
    }

    public func store(_ store: Store, fingerprint: FileStatFingerprint, forPath path: String, expectedEpoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard invalidationEpochs[path, default: 0] == expectedEpoch else { return }
        cache.setValue(Entry(fingerprint: fingerprint, store: store), forKey: path)
    }

    public func updateAfterWrite(fileURL: URL, store: Store) {
        let resolved = FileDigestCache.canonicalPath(for: fileURL)
        let raw = fileURL.standardizedFileURL.path
        let stripe = stripeLock(for: resolved)
        stripe.lock(); defer { stripe.unlock() }
        guard let fingerprint = FileStatFingerprint(resolvedPath: resolved), fingerprint.isRegularFile else {
            invalidate(fileURL: fileURL)
            return
        }
        lock.lock(); defer { lock.unlock() }
        cache.setValue(Entry(fingerprint: fingerprint, store: store), forKey: resolved)
        if raw != resolved { cache.removeValue(forKey: raw) }
    }

    public func invalidate(fileURL: URL) {
        let resolved = FileDigestCache.canonicalPath(for: fileURL)
        let raw = fileURL.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        invalidationEpochs[resolved, default: 0] &+= 1
        cache.removeValue(forKey: resolved)
        if raw != resolved {
            invalidationEpochs[raw, default: 0] &+= 1
            cache.removeValue(forKey: raw)
        }
    }

    private static func stripeIndex(for key: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % 16)
    }
}
