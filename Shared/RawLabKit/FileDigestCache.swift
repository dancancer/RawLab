import CryptoKit
import Darwin
import Foundation

public typealias POSIXStat = Darwin.stat

public struct FileStatFingerprint: Hashable, Sendable {
    public let device: dev_t
    public let inode: UInt64
    public let size: Int64
    public let mode: mode_t
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int
    public let changedSeconds: Int
    public let changedNanoseconds: Int

    public var isRegularFile: Bool { (mode & S_IFMT) == S_IFREG }

    public init(statBuffer st: POSIXStat) {
        self.device = st.st_dev
        self.inode = UInt64(st.st_ino)
        self.size = Int64(st.st_size)
        self.mode = st.st_mode
        self.modifiedSeconds = st.st_mtimespec.tv_sec
        self.modifiedNanoseconds = st.st_mtimespec.tv_nsec
        self.changedSeconds = st.st_ctimespec.tv_sec
        self.changedNanoseconds = st.st_ctimespec.tv_nsec
    }

    public init?(resolvedPath: String) {
        var st = POSIXStat()
        guard stat(resolvedPath, &st) == 0 else { return nil }
        self.init(statBuffer: st)
    }

    public static func fileDescriptor(_ fd: Int32) -> FileStatFingerprint? {
        var st = POSIXStat()
        guard fstat(fd, &st) == 0 else { return nil }
        return FileStatFingerprint(statBuffer: st)
    }
}

public struct BoundedLRUCache<Key: Hashable, Value> {
    public let maximumEntries: Int
    private var entries: [Key: Value] = [:]
    private var order: [Key] = []

    public init(maximumEntries: Int) {
        self.maximumEntries = max(0, maximumEntries)
    }

    public var count: Int { entries.count }

    public func peek(forKey key: Key) -> Value? { entries[key] }

    public mutating func value(forKey key: Key) -> Value? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func setValue(_ value: Value, forKey key: Key) {
        guard maximumEntries > 0 else { return }
        if entries[key] != nil {
            entries[key] = value
            touch(key)
            return
        }
        entries[key] = value
        order.append(key)
        while order.count > maximumEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    public mutating func removeValue(forKey key: Key) {
        guard entries.removeValue(forKey: key) != nil else { return }
        if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        guard let idx = order.firstIndex(of: key) else { return }
        if idx != order.count - 1 {
            order.remove(at: idx)
            order.append(key)
        }
    }
}

/// Bounded LRU SHA-256 cache validated against canonical path + POSIX stat fingerprint + pre/post stability.
public final class FileDigestCache: @unchecked Sendable {
    public static let defaultMaximumEntries = 128
    public static let shared = FileDigestCache()

    private struct Entry {
        let fingerprint: FileStatFingerprint
        let digestData: Data
        let digestHex: String
        let fileIdentity: OriginalFileIdentity?
    }

    public let maximumEntries: Int
    private let cacheLock = NSLock()
    private let metricsLock = NSLock()
    private let stripeLocks: [NSLock] = (0..<16).map { _ in NSLock() }
    private var cache: BoundedLRUCache<String, Entry>
    private var invalidationEpochs: [String: UInt64] = [:]
    private var _digestComputeCount = 0
    private var _digestComputeCountsByPath: [String: Int] = [:]
    private let readObserver: ((URL, Int) -> Void)?

    public init(maximumEntries: Int = FileDigestCache.defaultMaximumEntries,
                readObserver: ((URL, Int) -> Void)? = nil) {
        let bounded = max(0, maximumEntries)
        self.maximumEntries = bounded
        self.cache = BoundedLRUCache(maximumEntries: bounded)
        self.readObserver = readObserver
    }

    public var digestComputeCount: Int {
        metricsLock.lock(); defer { metricsLock.unlock() }
        return _digestComputeCount
    }

    public func digestComputeCount(for url: URL) -> Int {
        let resolved = Self.canonicalPath(for: url)
        metricsLock.lock(); defer { metricsLock.unlock() }
        return _digestComputeCountsByPath[resolved, default: 0]
    }

    public var entryCount: Int {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache.count
    }

    public func cachedDigest(for url: URL) -> String? {
        let resolvedPath = Self.canonicalPath(for: url)
        guard let current = FileStatFingerprint(resolvedPath: resolvedPath), current.isRegularFile else {
            return nil
        }
        return cachedDigest(forPath: resolvedPath, fingerprint: current)
    }

    public func invalidate(for url: URL) {
        let resolved = Self.canonicalPath(for: url)
        let raw = url.standardizedFileURL.path
        cacheLock.lock(); defer { cacheLock.unlock() }
        invalidationEpochs[resolved, default: 0] &+= 1
        cache.removeValue(forKey: resolved)
        if raw != resolved {
            invalidationEpochs[raw, default: 0] &+= 1
            cache.removeValue(forKey: raw)
        }
    }

    public func invalidateAll() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        for key in invalidationEpochs.keys {
            invalidationEpochs[key, default: 0] &+= 1
        }
        cache.removeAll()
    }

    /// Returns the hex SHA-256 digest for a regular file, reusing a cached digest when stat metadata is unchanged.
    public func digest(for url: URL, maximumBytes: Int? = nil) throws -> String {
        guard url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
        let initialPath = Self.canonicalPath(for: url)
        let initialFingerprint: FileStatFingerprint
        do {
            initialFingerprint = try Self.statOrThrow(resolvedPath: initialPath)
        } catch {
            invalidate(for: url)
            throw error
        }
        guard initialFingerprint.isRegularFile else { throw CocoaError(.fileReadCorruptFile) }
        if let maximumBytes {
            guard initialFingerprint.size > 0 && initialFingerprint.size <= Int64(maximumBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if let hit = cachedDigest(forPath: initialPath, fingerprint: initialFingerprint) {
            return hit
        }

        let stripe = stripeLocks[Self.stripeIndex(for: initialPath)]
        stripe.lock(); defer { stripe.unlock() }

        for attempt in 0..<3 {
            let resolvedPath = Self.canonicalPath(for: url)
            let before: FileStatFingerprint
            do {
                before = try Self.statOrThrow(resolvedPath: resolvedPath)
            } catch {
                invalidate(for: url)
                throw error
            }
            guard before.isRegularFile else { throw CocoaError(.fileReadCorruptFile) }
            if let maximumBytes {
                guard before.size > 0 && before.size <= Int64(maximumBytes) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if let hit = cachedDigest(forPath: resolvedPath, fingerprint: before) {
                return hit
            }
            let startEpoch = epoch(for: resolvedPath)
            let fd = Darwin.open(resolvedPath, O_RDONLY)
            if fd < 0 {
                let code = errno
                if code == ENOENT { invalidate(for: url) }
                throw Self.posixOrCocoaError(for: code)
            }
            defer { Darwin.close(fd) }
            guard let fdBefore = FileStatFingerprint.fileDescriptor(fd), fdBefore.isRegularFile else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if fdBefore != before { continue }

            recordCompute(forPath: resolvedPath)
            readObserver?(url, attempt)
            let (digestData, digest, totalBytes) = try Self.hashFileDescriptorData(fd, maximumBytes: maximumBytes)
            guard let fdAfter = FileStatFingerprint.fileDescriptor(fd) else {
                continue
            }
            let afterPath = Self.canonicalPath(for: url)
            let afterStat = FileStatFingerprint(resolvedPath: afterPath)
            if fdAfter == fdBefore && afterPath == resolvedPath && afterStat == fdBefore {
                if let maximumBytes, totalBytes == 0 || totalBytes > maximumBytes {
                    throw CocoaError(.fileReadCorruptFile)
                }
                store(Entry(fingerprint: fdBefore, digestData: digestData, digestHex: digest, fileIdentity: nil),
                      forPath: resolvedPath, expectedEpoch: startEpoch)
                return digest
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    public func digestAndFingerprint(
        for url: URL,
        maximumBytes: Int? = nil,
        returnOnUnstableThirdAttempt: Bool = false,
        onHash: (() -> Void)? = nil,
        readData: ((URL) throws -> Data)? = nil
    ) throws -> (identity: OriginalFileIdentity, digest: Data, hex: String, fingerprint: FileStatFingerprint) {
        guard url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
        let initialPath = Self.canonicalPath(for: url)
        let initialFingerprint: FileStatFingerprint
        do {
            initialFingerprint = try Self.statOrThrow(resolvedPath: initialPath)
        } catch {
            invalidate(for: url)
            if returnOnUnstableThirdAttempt {
                _ = try OriginalFileIdentity(url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            throw error
        }
        guard initialFingerprint.isRegularFile else {
            if returnOnUnstableThirdAttempt {
                _ = try OriginalFileIdentity(url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        if let maximumBytes {
            guard initialFingerprint.size > 0 && initialFingerprint.size <= Int64(maximumBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if readData == nil,
           let hit = cachedEntry(forPath: initialPath, fingerprint: initialFingerprint),
           let fileIdentity = hit.fileIdentity {
            return (fileIdentity, hit.digestData, hit.digestHex, initialFingerprint)
        }

        let stripe = stripeLocks[Self.stripeIndex(for: initialPath)]
        stripe.lock(); defer { stripe.unlock() }

        for attempt in 0..<3 {
            let resolvedURL = Self.canonicalURL(for: url)
            let resolvedPath = resolvedURL.path
            let before: FileStatFingerprint
            do {
                before = try Self.statOrThrow(resolvedPath: resolvedPath)
            } catch {
                invalidate(for: url)
                if returnOnUnstableThirdAttempt {
                    _ = try OriginalFileIdentity(url)
                    throw CocoaError(.fileReadNoSuchFile)
                }
                throw error
            }
            guard before.isRegularFile else {
                if returnOnUnstableThirdAttempt {
                    _ = try OriginalFileIdentity(url)
                    throw CocoaError(.fileReadNoSuchFile)
                }
                throw CocoaError(.fileReadCorruptFile)
            }
            if let maximumBytes {
                guard before.size > 0 && before.size <= Int64(maximumBytes) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if readData == nil,
               let hit = cachedEntry(forPath: resolvedPath, fingerprint: before),
               let fileIdentity = hit.fileIdentity {
                return (fileIdentity, hit.digestData, hit.digestHex, before)
            }
            let startEpoch = epoch(for: resolvedPath)
            let identity = try OriginalFileIdentity(resolvedURL)

            if let readData {
                let data = try readData(resolvedURL)
                if let maximumBytes, data.isEmpty || data.count > maximumBytes {
                    throw CocoaError(.fileReadCorruptFile)
                }
                recordCompute(forPath: resolvedPath)
                readObserver?(url, attempt)
                onHash?()
                let digestData = Data(SHA256.hash(data: data))
                let hex = digestData.map { String(format: "%02x", $0) }.joined()
                let afterPath = Self.canonicalPath(for: url)
                let afterStat = FileStatFingerprint(resolvedPath: afterPath)
                if afterPath == resolvedPath,
                   afterStat == before,
                   Int64(data.count) == before.size,
                   identity.size == UInt64(before.size) {
                    store(Entry(fingerprint: before, digestData: digestData, digestHex: hex, fileIdentity: identity),
                          forPath: resolvedPath, expectedEpoch: startEpoch)
                    return (identity, digestData, hex, before)
                }
                invalidate(for: url)
                if returnOnUnstableThirdAttempt && attempt == 2 {
                    return (identity, digestData, hex, before)
                }
                continue
            }

            let fd = Darwin.open(resolvedPath, O_RDONLY)
            if fd < 0 {
                let code = errno
                if code == ENOENT { invalidate(for: url) }
                throw Self.posixOrCocoaError(for: code)
            }
            defer { Darwin.close(fd) }
            guard let fdBefore = FileStatFingerprint.fileDescriptor(fd), fdBefore.isRegularFile else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if fdBefore != before { continue }

            recordCompute(forPath: resolvedPath)
            readObserver?(url, attempt)
            onHash?()
            let (digestData, hex, totalBytes) = try Self.hashFileDescriptorData(fd, maximumBytes: maximumBytes)
            guard let fdAfter = FileStatFingerprint.fileDescriptor(fd) else {
                if returnOnUnstableThirdAttempt && attempt == 2 {
                    invalidate(for: url)
                    return (identity, digestData, hex, fdBefore)
                }
                continue
            }
            let afterPath = Self.canonicalPath(for: url)
            let afterStat = FileStatFingerprint(resolvedPath: afterPath)
            if fdAfter == fdBefore && afterPath == resolvedPath && afterStat == fdBefore && identity.size == UInt64(fdBefore.size) {
                if let maximumBytes, totalBytes == 0 || totalBytes > maximumBytes {
                    throw CocoaError(.fileReadCorruptFile)
                }
                store(Entry(fingerprint: fdBefore, digestData: digestData, digestHex: hex, fileIdentity: identity),
                      forPath: resolvedPath, expectedEpoch: startEpoch)
                return (identity, digestData, hex, fdBefore)
            }
            if returnOnUnstableThirdAttempt && attempt == 2 {
                invalidate(for: url)
                return (identity, digestData, hex, fdBefore)
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    public static func canonicalURL(for url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func canonicalPath(for url: URL) -> String {
        canonicalURL(for: url).path
    }

    private static func stripeIndex(for key: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % 16)
    }

    private func cachedDigest(forPath path: String, fingerprint: FileStatFingerprint) -> String? {
        cachedEntry(forPath: path, fingerprint: fingerprint)?.digestHex
    }

    private func cachedEntry(forPath path: String, fingerprint: FileStatFingerprint) -> Entry? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let entry = cache.value(forKey: path), entry.fingerprint == fingerprint else { return nil }
        return entry
    }

    private func epoch(for path: String) -> UInt64 {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return invalidationEpochs[path, default: 0]
    }

    private func store(_ entry: Entry, forPath path: String, expectedEpoch: UInt64) {
        guard maximumEntries > 0 else { return }
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard invalidationEpochs[path, default: 0] == expectedEpoch else { return }
        cache.setValue(entry, forKey: path)
    }

    private func recordCompute(forPath path: String) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        _digestComputeCount += 1
        _digestComputeCountsByPath[path, default: 0] += 1
    }

    private static func hashFileDescriptorData(_ fd: Int32, maximumBytes: Int?) throws -> (Data, String, Int) {
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress, chunkSize)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            total += count
            if let maximumBytes, total > maximumBytes {
                throw CocoaError(.fileReadCorruptFile)
            }
            hasher.update(data: buffer.prefix(count))
        }
        if maximumBytes != nil && total == 0 {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digestData = Data(hasher.finalize())
        let digestHex = digestData.map { String(format: "%02x", $0) }.joined()
        return (digestData, digestHex, total)
    }

    private static func statOrThrow(resolvedPath: String) throws -> FileStatFingerprint {
        var st = POSIXStat()
        guard stat(resolvedPath, &st) == 0 else {
            throw posixOrCocoaError(for: errno)
        }
        return FileStatFingerprint(statBuffer: st)
    }

    private static func posixOrCocoaError(for code: Int32) -> Error {
        if code == ENOENT { return CocoaError(.fileNoSuchFile) }
        if code == EACCES || code == EPERM { return CocoaError(.fileReadNoPermission) }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
