#if os(macOS)
import Combine
import CryptoKit
import Darwin
import Foundation

// MARK: - Catalog & Descriptor

public struct AIModelArchiveEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case file
        case directory
    }

    public let path: String
    public let kind: Kind
    public let bytes: UInt64
    public let sha256: String?

    public init(path: String, kind: Kind, bytes: UInt64, sha256: String? = nil) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct AIModelPackageDescriptor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let platform: String
    public let url: String
    public let archiveName: String
    public let archiveSha256: String
    public let archiveBytes: UInt64
    public let manifestSha256: String
    public let unpackedBytes: UInt64
    public let entries: [AIModelArchiveEntry]

    public init(
        schemaVersion: Int = 1,
        platform: String,
        url: String,
        archiveName: String,
        archiveSha256: String,
        archiveBytes: UInt64,
        manifestSha256: String,
        unpackedBytes: UInt64,
        entries: [AIModelArchiveEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.platform = platform
        self.url = url
        self.archiveName = archiveName
        self.archiveSha256 = archiveSha256
        self.archiveBytes = archiveBytes
        self.manifestSha256 = manifestSha256
        self.unpackedBytes = unpackedBytes
        self.entries = entries
    }

    public func validatedDownloadURL(allowLoopbackHTTP: Bool = false) throws -> URL {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              let host = parsed.host?.lowercased(),
              !host.isEmpty else {
            throw AIModelPackageError.insecureURL
        }
        if scheme == "https" {
            return parsed
        }
        if allowLoopbackHTTP, scheme == "http", Self.isLoopbackHost(host) {
            return parsed
        }
        throw AIModelPackageError.insecureURL
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1" || lower == "[::1]"
    }

    public func validate(allowLoopbackHTTP: Bool = false) throws {
        guard schemaVersion == 1 else {
            throw AIModelPackageError.invalidCatalog("Unsupported schemaVersion: \(schemaVersion)")
        }
        guard !platform.isEmpty else {
            throw AIModelPackageError.invalidCatalog("Missing platform")
        }
        _ = try validatedDownloadURL(allowLoopbackHTTP: allowLoopbackHTTP)
        guard !archiveName.isEmpty,
              !archiveName.contains("/"),
              !archiveName.contains("\\"),
              archiveName != ".",
              archiveName != ".." else {
            throw AIModelPackageError.invalidCatalog("Invalid archiveName: \(archiveName)")
        }
        guard Self.isValidSHA256Hex(archiveSha256) else {
            throw AIModelPackageError.invalidCatalog("Invalid archiveSha256")
        }
        guard Self.isValidSHA256Hex(manifestSha256) else {
            throw AIModelPackageError.invalidCatalog("Invalid manifestSha256")
        }
        guard archiveBytes > 0, unpackedBytes > 0, !entries.isEmpty else {
            throw AIModelPackageError.invalidCatalog("Invalid sizes or empty entries")
        }

        var seenExact = Set<String>()
        var seenCaseInsensitive = Set<String>()
        var totalFileBytes: UInt64 = 0
        var manifestEntry: AIModelArchiveEntry?

        for entry in entries {
            guard Self.isSafeRelativePath(entry.path) else {
                throw AIModelPackageError.invalidCatalog("Unsafe catalog entry path: \(entry.path)")
            }
            guard seenExact.insert(entry.path).inserted else {
                throw AIModelPackageError.invalidCatalog("Duplicate catalog entry: \(entry.path)")
            }
            guard seenCaseInsensitive.insert(entry.path.lowercased()).inserted else {
                throw AIModelPackageError.invalidCatalog("Case-colliding catalog entry: \(entry.path)")
            }
            switch entry.kind {
            case .directory:
                guard entry.bytes == 0, entry.sha256 == nil else {
                    throw AIModelPackageError.invalidCatalog("Invalid directory entry: \(entry.path)")
                }
            case .file:
                guard let digest = entry.sha256, Self.isValidSHA256Hex(digest) else {
                    throw AIModelPackageError.invalidCatalog("Missing or invalid file sha256: \(entry.path)")
                }
                let (sum, overflow) = totalFileBytes.addingReportingOverflow(entry.bytes)
                guard !overflow else {
                    throw AIModelPackageError.invalidCatalog("Unpacked byte count overflow")
                }
                totalFileBytes = sum
                if entry.path == "manifest.json" {
                    manifestEntry = entry
                }
            }
        }

        guard totalFileBytes == unpackedBytes else {
            throw AIModelPackageError.invalidCatalog("Unpacked byte sum mismatch: \(totalFileBytes) != \(unpackedBytes)")
        }
        guard let manifestEntry, manifestEntry.sha256 == manifestSha256 else {
            throw AIModelPackageError.invalidCatalog("Catalog manifest.json entry does not match manifestSha256")
        }
    }

    public static func isValidSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\") else {
            return false
        }
        for scalar in path.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return false
            }
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for part in components {
            if part.isEmpty || part == "." || part == ".." {
                return false
            }
        }
        return true
    }
}

public struct AIModelCatalog: Codable, Equatable, Sendable {
    public static let macOSArm64Platform = "macos-arm64"
    public static let windowsX64Platform = "windows-x64"

    public let schemaVersion: Int
    public let platforms: [String: AIModelPackageDescriptor]

    public init(schemaVersion: Int = 1, platforms: [String: AIModelPackageDescriptor]) {
        self.schemaVersion = schemaVersion
        self.platforms = platforms
    }

    public static func load(from url: URL) throws -> AIModelCatalog {
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(AIModelCatalog.self, from: data)
        guard catalog.schemaVersion == 1 else {
            throw AIModelPackageError.invalidCatalog("Unsupported catalog schemaVersion: \(catalog.schemaVersion)")
        }
        return catalog
    }

    public func descriptor(for platform: String, allowLoopbackHTTP: Bool = false) throws -> AIModelPackageDescriptor {
        guard let descriptor = platforms[platform] else {
            throw AIModelPackageError.invalidCatalog("Missing platform descriptor: \(platform)")
        }
        guard descriptor.platform == platform else {
            throw AIModelPackageError.invalidCatalog("Platform key mismatch: \(platform) != \(descriptor.platform)")
        }
        try descriptor.validate(allowLoopbackHTTP: allowLoopbackHTTP)
        return descriptor
    }

    public static func bundledDescriptor(
        platform: String = macOSArm64Platform,
        bundle: Bundle = .main,
        fallbackRepositoryPath: URL? = nil
    ) -> AIModelPackageDescriptor? {
        let candidates: [URL] = [
            bundle.url(forResource: "ai-model-catalog", withExtension: "json"),
            bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "ai-models"),
            fallbackRepositoryPath,
            URL(fileURLWithPath: "Shared/ai-models/catalog.json"),
        ].compactMap { $0 }
        for candidate in candidates {
            guard FileManager.default.isReadableFile(atPath: candidate.path) else { continue }
            if let catalog = try? load(from: candidate),
               let descriptor = try? catalog.descriptor(for: platform, allowLoopbackHTTP: false) {
                return descriptor
            }
        }
        return nil
    }
}

// MARK: - Model Directory Resolution & Errors

public enum AIModelDirectorySource: Equatable, Sendable {
    case override(URL)
    case downloaded(URL)
    case bundled(URL)

    public var url: URL {
        switch self {
        case .override(let url), .downloaded(let url), .bundled(let url):
            return url
        }
    }
}

public enum AIModelPackageError: Error, Equatable, Sendable, LocalizedError {
    case invalidCatalog(String)
    case insecureURL
    case networkUnavailable
    case networkTimeout
    case httpNotFound
    case httpStatus(Int)
    case networkError(String)
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
    case diskFull
    case archiveSizeMismatch(expected: UInt64, actual: UInt64)
    case archiveDigestMismatch(expected: String, actual: String)
    case memberVerificationFailed(String)
    case archiveExtractionFailed(Int32)
    case cancelled
    case fileSystemError(String)
    case removeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Network unavailable"
        case .networkTimeout:
            return "Download timed out"
        case .httpNotFound:
            return "Model archive not found (HTTP 404)"
        case .httpStatus(let code):
            return "Download failed (HTTP \(code))"
        case .insufficientDiskSpace(let requiredBytes, _):
            return "Insufficient free disk space (requires ~\(Self.formatMegabytes(requiredBytes)) MB)"
        case .diskFull:
            return "Disk is full"
        case .archiveSizeMismatch(let expected, let actual):
            return "Archive size mismatch (\(actual) != \(expected))"
        case .archiveDigestMismatch:
            return "Archive SHA-256 mismatch"
        case .memberVerificationFailed(let detail):
            return "Archive member verification failed: \(detail)"
        case .archiveExtractionFailed(let status):
            return "Archive extraction failed (exit \(status))"
        case .insecureURL:
            return "Insecure model download URL"
        case .cancelled:
            return "Model download cancelled"
        case .removeFailed(let detail):
            return "Failed to remove model package: \(detail)"
        case .invalidCatalog(let detail):
            return "Invalid model catalog: \(detail)"
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .fileSystemError(let detail):
            return "File system error: \(detail)"
        }
    }

    public static func formatMegabytes(_ bytes: UInt64) -> String {
        let mb = max(1, (bytes + 500_000) / 1_000_000)
        return String(mb)
    }

    public static func formatProgressMegabytes(_ bytes: UInt64) -> String {
        let mb = (bytes + 500_000) / 1_000_000
        return String(mb)
    }
}

public enum AIModelPackageState: Equatable, Sendable {
    case unavailable
    case notInstalled(downloadBytes: UInt64, unpackedBytes: UInt64)
    case downloading(completedBytes: UInt64, totalBytes: UInt64)
    case verifying
    case installing
    case cancelled(downloadBytes: UInt64, unpackedBytes: UInt64)
    case failed(AIModelPackageError, downloadBytes: UInt64, unpackedBytes: UInt64)
    case installed(AIModelDirectorySource, unpackedBytes: UInt64, removeError: AIModelPackageError? = nil)

    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    public var isDownloadedInstalled: Bool {
        if case .installed(.downloaded, _, _) = self { return true }
        return false
    }
}

// MARK: - Model-Layer Active Reader Guard

/// 模型层活跃读取守卫：追踪所有可能读取已下载模型目录的后台原生操作，
/// 确保在取消/关闭预览或后台线程真正退出原生调用前禁止删除模型，不依赖 SwiftUI 视图绑定。
public final class AIModelAccessTracker: @unchecked Sendable {
    public static let shared = AIModelAccessTracker()

    public final class ReaderLease: @unchecked Sendable {
        private let lock = NSLock()
        private weak var tracker: AIModelAccessTracker?
        private var ended = false

        fileprivate init(tracker: AIModelAccessTracker) {
            self.tracker = tracker
        }

        public func end() {
            lock.lock()
            if ended {
                lock.unlock()
                return
            }
            ended = true
            let owner = tracker
            tracker = nil
            lock.unlock()
            owner?.endReader()
        }

        deinit {
            end()
        }
    }

    private let lock = NSLock()
    private var count = 0
    public let didChange = PassthroughSubject<Void, Never>()

    public init() {}

    public var activeReaderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public var hasActiveReaders: Bool {
        activeReaderCount > 0
    }

    public func beginReader() -> ReaderLease {
        lock.lock()
        let becameActive = count == 0
        count += 1
        lock.unlock()
        if becameActive {
            notifyChanged()
        }
        return ReaderLease(tracker: self)
    }

    public func withReader<T>(_ body: () throws -> T) rethrows -> T {
        let lease = beginReader()
        defer { lease.end() }
        return try body()
    }

    private func endReader() {
        lock.lock()
        count = max(0, count - 1)
        let becameIdle = count == 0
        lock.unlock()
        if becameIdle {
            notifyChanged()
        }
    }

    private func notifyChanged() {
        if Thread.isMainThread {
            didChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.didChange.send()
            }
        }
    }
}

// MARK: - Cancellation Token

public final class AIModelInstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?
    private var process: Process?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let activeTask = task
        let activeProcess = process
        lock.unlock()
        activeTask?.cancel()
        if let activeProcess, activeProcess.isRunning {
            activeProcess.terminate()
        }
    }

    func attach(task newTask: URLSessionTask?) {
        lock.lock()
        task = newTask
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { newTask?.cancel() }
    }

    func attach(process newProcess: Process?) {
        lock.lock()
        process = newProcess
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel, let newProcess, newProcess.isRunning {
            newProcess.terminate()
        }
    }
}

// MARK: - Package Store

public final class AIModelPackageStore: @unchecked Sendable {
    public static let defaultDiskSpaceMarginBytes: UInt64 = 64 * 1024 * 1024

    public static var defaultStorageRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/AI/DualDn", isDirectory: true)
    }

    /// 正式应用共享存储：永远只允许 HTTPS（测试通过独立实例注入临时根目录与 loopback 开关）。
    public static let shared = AIModelPackageStore(
        storageRoot: defaultStorageRoot,
        descriptor: AIModelCatalog.bundledDescriptor(),
        allowLoopbackHTTP: false
    )

    public let storageRoot: URL
    public let descriptor: AIModelPackageDescriptor?
    public let diskSpaceMarginBytes: UInt64
    private let allowLoopbackHTTP: Bool
    private let availableSpaceProvider: (URL) throws -> UInt64
    private let onBeforeUnpack: (() -> Void)?
    private let onBeforeCommit: (() -> Void)?
    private let removeItemHandler: (URL) throws -> Void

    public init(
        storageRoot: URL = AIModelPackageStore.defaultStorageRoot,
        descriptor: AIModelPackageDescriptor?,
        allowLoopbackHTTP: Bool = false,
        diskSpaceMarginBytes: UInt64 = AIModelPackageStore.defaultDiskSpaceMarginBytes,
        availableSpaceProvider: ((URL) throws -> UInt64)? = nil,
        onBeforeUnpack: (() -> Void)? = nil,
        onBeforeCommit: (() -> Void)? = nil,
        removeItemHandler: ((URL) throws -> Void)? = nil
    ) {
        self.storageRoot = storageRoot
        self.descriptor = descriptor
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.diskSpaceMarginBytes = diskSpaceMarginBytes
        self.availableSpaceProvider = availableSpaceProvider ?? Self.volumeAvailableBytes(at:)
        self.onBeforeUnpack = onBeforeUnpack
        self.onBeforeCommit = onBeforeCommit
        self.removeItemHandler = removeItemHandler ?? { try FileManager.default.removeItem(at: $0) }
    }

    public var installedDirectoryURL: URL? {
        guard let descriptor else { return nil }
        return storageRoot.appendingPathComponent(descriptor.manifestSha256, isDirectory: true)
    }

    /// 快速结构检查（供启动和界面状态查询，不在 UI 线程重算数百 MB SHA-256；
    /// 安装时已全量校验 SHA-256，核心创建 AI session 时仍执行最终 SHA-256 校验）。
    public func installedPackageURL() -> URL? {
        guard let descriptor, let candidate = installedDirectoryURL else { return nil }
        guard Self.matchesInstalledStructure(at: candidate, descriptor: descriptor) else {
            return nil
        }
        return candidate
    }

    /// 模型目录选择顺序：显式开发/测试覆盖 -> 已下载的当前 digest 包 -> 应用内预置包。
    public func resolveModelDirectory(override: URL? = nil, bundled: URL? = nil) -> AIModelDirectorySource? {
        if let override {
            return .override(override)
        }
        if let downloaded = installedPackageURL() {
            return .downloaded(downloaded)
        }
        if let bundled, Self.hasManifestFile(at: bundled) {
            return .bundled(bundled)
        }
        return nil
    }

    public func checkDiskSpace(for descriptor: AIModelPackageDescriptor) throws {
        let (sum, overflow1) = descriptor.archiveBytes.addingReportingOverflow(descriptor.unpackedBytes)
        let (required, overflow2) = sum.addingReportingOverflow(diskSpaceMarginBytes)
        guard !overflow1, !overflow2 else {
            throw AIModelPackageError.invalidCatalog("Required disk space overflow")
        }
        let probeURL = Self.nearestExistingDirectory(for: storageRoot)
        let available: UInt64
        do {
            available = try availableSpaceProvider(probeURL)
        } catch {
            throw AIModelPackageError.fileSystemError(error.localizedDescription)
        }
        if available < required {
            throw AIModelPackageError.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
    }

    public enum InstallPhase: Equatable, Sendable {
        case downloading(completedBytes: UInt64, totalBytes: UInt64)
        case verifying
        case installing
    }

    /// 下载、校验并原子安装模型包。仅由用户显式触发调用，绝不在启动或更新后自动调用。
    @discardableResult
    public func downloadAndInstall(
        cancellation: AIModelInstallCancellation = AIModelInstallCancellation(),
        onProgress: @escaping @Sendable (InstallPhase) -> Void = { _ in }
    ) async throws -> URL {
        guard let descriptor else {
            throw AIModelPackageError.invalidCatalog("AI model catalog unavailable")
        }
        try descriptor.validate(allowLoopbackHTTP: allowLoopbackHTTP)
        if cancellation.isCancelled { throw AIModelPackageError.cancelled }

        let downloadURL = try descriptor.validatedDownloadURL(allowLoopbackHTTP: allowLoopbackHTTP)
        try checkDiskSpace(for: descriptor)
        if cancellation.isCancelled { throw AIModelPackageError.cancelled }

        do {
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        } catch {
            throw Self.mapFileSystemError(error)
        }

        // 清理上次异常退出或强杀遗留的临时下载/暂存目录。
        cleanupStaleTempItems()

        let token = UUID().uuidString.lowercased()
        let partURL = storageRoot.appendingPathComponent(".download-\(token).part", isDirectory: false)
        let stagingURL = storageRoot.appendingPathComponent(".staging-\(token)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: partURL)
            try? FileManager.default.removeItem(at: stagingURL)
        }

        onProgress(.downloading(completedBytes: 0, totalBytes: descriptor.archiveBytes))
        try await streamDownload(
            from: downloadURL,
            to: partURL,
            expectedBytes: descriptor.archiveBytes,
            cancellation: cancellation
        ) { completed in
            onProgress(.downloading(completedBytes: completed, totalBytes: descriptor.archiveBytes))
        }

        if cancellation.isCancelled { throw AIModelPackageError.cancelled }
        onProgress(.verifying)

        // 先验归档字节数，再验归档 SHA-256；任一不符立即终止，绝不解压或解析归档。
        try verifyArchiveFile(at: partURL, descriptor: descriptor, cancellation: cancellation)

        if cancellation.isCancelled { throw AIModelPackageError.cancelled }
        onProgress(.installing)

        onBeforeUnpack?()

        try extractArchive(at: partURL, to: stagingURL, cancellation: cancellation)

        if cancellation.isCancelled { throw AIModelPackageError.cancelled }
        try verifyAndNormalizeStagingTree(at: stagingURL, descriptor: descriptor, cancellation: cancellation)

        if cancellation.isCancelled { throw AIModelPackageError.cancelled }
        onBeforeCommit?()
        let destination = storageRoot.appendingPathComponent(descriptor.manifestSha256, isDirectory: true)
        try commitStagingDirectory(stagingURL, to: destination)
        cleanupOlderPackages(keeping: descriptor.manifestSha256)
        return destination
    }

    public func removeInstalledPackages() throws {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil)
        } catch {
            throw AIModelPackageError.removeFailed(error.localizedDescription)
        }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".download-")
                || name.hasPrefix(".staging-")
                || name.hasPrefix(".replacing-")
                || name.hasPrefix(".removing-") {
                continue
            }
            do {
                try removeItemAtomically(at: item)
            } catch let error as AIModelPackageError {
                throw error
            } catch {
                throw AIModelPackageError.removeFailed(error.localizedDescription)
            }
        }
    }

    private func removeItemAtomically(at item: URL) throws {
        var st = stat()
        guard Darwin.lstat(item.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw AIModelPackageError.removeFailed(String(cString: strerror(errno)))
        }
        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFDIR {
            // 先原子改名到同级 .removing-<uuid> 再删除：避免并发读取或中途失败在正式路径留下半删损坏包。
            let removingURL = storageRoot.appendingPathComponent(".removing-\(UUID().uuidString.lowercased())", isDirectory: true)
            guard Darwin.rename(item.path, removingURL.path) == 0 else {
                throw AIModelPackageError.removeFailed(String(cString: strerror(errno)))
            }
            try removeItemHandler(removingURL)
        } else {
            // 符号链接与普通文件直接移除条目本身，不跟随符号链接目标。
            try removeItemHandler(item)
        }
    }

    // MARK: - Verification Helpers (internal for direct defense-in-depth tests)

    func verifyArchiveFile(
        at archiveURL: URL,
        descriptor: AIModelPackageDescriptor,
        cancellation: AIModelInstallCancellation
    ) throws {
        var st = stat()
        guard Darwin.lstat(archiveURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw AIModelPackageError.fileSystemError("Downloaded archive missing")
        }
        let actualSize = UInt64(max(0, st.st_size))
        guard actualSize == descriptor.archiveBytes else {
            throw AIModelPackageError.archiveSizeMismatch(expected: descriptor.archiveBytes, actual: actualSize)
        }
        let digest = try Self.sha256File(at: archiveURL, cancellation: cancellation)
        guard digest == descriptor.archiveSha256 else {
            throw AIModelPackageError.archiveDigestMismatch(expected: descriptor.archiveSha256, actual: digest)
        }
    }

    func extractArchive(
        at archiveURL: URL,
        to stagingURL: URL,
        cancellation: AIModelInstallCancellation
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Self.mapFileSystemError(error)
        }

        try runTar(
            arguments: [
                "-xzf", archiveURL.path,
                "-C", stagingURL.path,
                "--no-same-permissions",
                "--no-same-owner",
                "--no-xattrs",
                "--no-acls",
                "--no-fflags",
                "--no-mac-metadata",
            ],
            cancellation: cancellation
        )
    }

    func verifyAndNormalizeStagingTree(
        at stagingURL: URL,
        descriptor: AIModelPackageDescriptor,
        cancellation: AIModelInstallCancellation
    ) throws {
        let expectedByPath = Dictionary(uniqueKeysWithValues: descriptor.entries.map { ($0.path, $0) })
        var visited = Set<String>()
        var directoriesToChmod: [URL] = []

        func walk(directory: URL, relativePrefix: String) throws {
            if cancellation.isCancelled { throw AIModelPackageError.cancelled }
            guard let dir = opendir(directory.path) else {
                throw AIModelPackageError.fileSystemError("Unable to open staging directory: \(relativePrefix)")
            }
            defer { closedir(dir) }

            var childNames: [String] = []
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer -> String in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                childNames.append(name)
            }
            childNames.sort()

            for name in childNames {
                if cancellation.isCancelled { throw AIModelPackageError.cancelled }
                let relPath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
                let childURL = directory.appendingPathComponent(name, isDirectory: false)

                var st = stat()
                guard Darwin.lstat(childURL.path, &st) == 0 else {
                    throw AIModelPackageError.memberVerificationFailed("Unable to stat extracted item: \(relPath)")
                }
                let fileType = st.st_mode & S_IFMT
                if fileType == S_IFLNK {
                    throw AIModelPackageError.memberVerificationFailed("Extracted tree contains symlink: \(relPath)")
                }
                guard let expected = expectedByPath[relPath] else {
                    throw AIModelPackageError.memberVerificationFailed("Extracted tree contains unexpected item: \(relPath)")
                }
                guard visited.insert(relPath).inserted else {
                    throw AIModelPackageError.memberVerificationFailed("Duplicate extracted item: \(relPath)")
                }

                switch expected.kind {
                case .directory:
                    guard fileType == S_IFDIR else {
                        throw AIModelPackageError.memberVerificationFailed("Expected directory at \(relPath)")
                    }
                    // 先确保目录可读可遍历，子项处理完再统一设为 0o755。
                    _ = Darwin.chmod(childURL.path, 0o700)
                    try walk(directory: childURL, relativePrefix: relPath)
                    directoriesToChmod.append(childURL)
                case .file:
                    guard fileType == S_IFREG else {
                        throw AIModelPackageError.memberVerificationFailed("Expected regular file at \(relPath)")
                    }
                    guard st.st_nlink == 1 else {
                        throw AIModelPackageError.memberVerificationFailed("Extracted file is a hard link: \(relPath)")
                    }
                    let actualSize = UInt64(max(0, st.st_size))
                    guard actualSize == expected.bytes else {
                        throw AIModelPackageError.memberVerificationFailed(
                            "Size mismatch at \(relPath): \(actualSize) != \(expected.bytes)"
                        )
                    }
                    guard let expectedDigest = expected.sha256 else {
                        throw AIModelPackageError.invalidCatalog("Missing expected sha256 for \(relPath)")
                    }
                    let actualDigest = try Self.sha256File(at: childURL, cancellation: cancellation)
                    guard actualDigest == expectedDigest else {
                        throw AIModelPackageError.memberVerificationFailed("SHA-256 mismatch at \(relPath)")
                    }
                    guard Darwin.chmod(childURL.path, 0o644) == 0 else {
                        throw AIModelPackageError.fileSystemError("chmod failed for \(relPath)")
                    }
                }
            }
        }

        try walk(directory: stagingURL, relativePrefix: "")
        guard visited.count == expectedByPath.count else {
            throw AIModelPackageError.memberVerificationFailed("Missing expected items in staging tree")
        }
        for directory in directoriesToChmod {
            guard Darwin.chmod(directory.path, 0o755) == 0 else {
                throw AIModelPackageError.fileSystemError("chmod failed for directory \(directory.lastPathComponent)")
            }
        }
        guard Darwin.chmod(stagingURL.path, 0o755) == 0 else {
            throw AIModelPackageError.fileSystemError("chmod failed for staging root")
        }
    }

    // MARK: - Private Helpers

    private func commitStagingDirectory(_ stagingURL: URL, to destination: URL) throws {
        var backupURL: URL?
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = storageRoot.appendingPathComponent(".replacing-\(UUID().uuidString.lowercased())", isDirectory: true)
            guard Darwin.rename(destination.path, backup.path) == 0 else {
                throw Self.mapErrno(errno)
            }
            backupURL = backup
        }
        if Darwin.rename(stagingURL.path, destination.path) != 0 {
            let err = errno
            if let backupURL {
                _ = Darwin.rename(backupURL.path, destination.path)
            }
            throw Self.mapErrno(err)
        }
        if let backupURL {
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    func cleanupStaleTempItems() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".download-")
                || name.hasPrefix(".staging-")
                || name.hasPrefix(".replacing-")
                || name.hasPrefix(".removing-") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func cleanupOlderPackages(keeping currentDigest: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name == currentDigest { continue }
            if name.hasPrefix(".download-") || name.hasPrefix(".staging-") { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func streamDownload(
        from url: URL,
        to partURL: URL,
        expectedBytes: UInt64,
        cancellation: AIModelInstallCancellation,
        onBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        let delegate = StreamingDownloadDelegate(
            partURL: partURL,
            expectedBytes: expectedBytes,
            allowLoopbackHTTP: allowLoopbackHTTP,
            cancellation: cancellation,
            onBytesWritten: onBytesWritten
        )
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "rawlab.ai.model.download"
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer {
            cancellation.attach(task: nil)
            session.invalidateAndCancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.setContinuation(continuation)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let task = session.dataTask(with: request)
            cancellation.attach(task: task)
            if cancellation.isCancelled {
                delegate.finish(with: .failure(AIModelPackageError.cancelled))
                task.cancel()
                return
            }
            task.resume()
        }
    }

    private func runTar(
        arguments: [String],
        cancellation: AIModelInstallCancellation
    ) throws {
        if cancellation.isCancelled { throw AIModelPackageError.cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.environment = [
            "LC_ALL": "C",
            "LANG": "C",
            "TZ": "UTC",
            "PATH": "/usr/bin:/bin",
        ]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        defer { cancellation.attach(process: nil) }

        do {
            try process.run()
        } catch {
            throw AIModelPackageError.fileSystemError(error.localizedDescription)
        }
        // 在子进程真正启动后挂载取消句柄：无论取消发生在 run() 之前还是之后，都能立即 terminate 运行中的 tar。
        cancellation.attach(process: process)

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if cancellation.isCancelled {
            throw AIModelPackageError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrData, encoding: .utf8) ?? ""
            if errText.localizedCaseInsensitiveContains("No space left on device") {
                throw AIModelPackageError.diskFull
            }
            throw AIModelPackageError.archiveExtractionFailed(process.terminationStatus)
        }
    }

    static func sha256File(at url: URL, cancellation: AIModelInstallCancellation) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw mapFileSystemError(error)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            if cancellation.isCancelled { throw AIModelPackageError.cancelled }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw mapFileSystemError(error)
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func matchesInstalledStructure(at directory: URL, descriptor: AIModelPackageDescriptor) -> Bool {
        var rootStat = stat()
        guard Darwin.lstat(directory.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        for entry in descriptor.entries {
            let item = directory.appendingPathComponent(entry.path, isDirectory: entry.kind == .directory)
            var st = stat()
            guard Darwin.lstat(item.path, &st) == 0 else { return false }
            let kind = st.st_mode & S_IFMT
            switch entry.kind {
            case .directory:
                if kind != S_IFDIR { return false }
            case .file:
                if kind != S_IFREG || st.st_nlink != 1 || UInt64(max(0, st.st_size)) != entry.bytes {
                    return false
                }
            }
        }
        return true
    }

    private static func hasManifestFile(at directory: URL) -> Bool {
        let manifest = directory.appendingPathComponent("manifest.json", isDirectory: false)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: manifest.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func nearestExistingDirectory(for url: URL) -> URL {
        var current = url.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return current
    }

    public static func volumeAvailableBytes(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let basic = values.volumeAvailableCapacity, basic >= 0 {
            return UInt64(basic)
        }
        throw AIModelPackageError.fileSystemError("Unable to query available disk space")
    }

    static func mapFileSystemError(_ error: Error) -> AIModelPackageError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return .diskFull
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC) {
            return .diskFull
        }
        return .fileSystemError(error.localizedDescription)
    }

    private static func mapErrno(_ code: Int32) -> AIModelPackageError {
        if code == ENOSPC { return .diskFull }
        return .fileSystemError(String(cString: strerror(code)))
    }
}

// MARK: - Streaming URLSession Delegate

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partURL: URL
    private let expectedBytes: UInt64
    private let allowLoopbackHTTP: Bool
    private let cancellation: AIModelInstallCancellation
    private let onBytesWritten: @Sendable (UInt64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileHandle: FileHandle?
    private var receivedBytes: UInt64 = 0
    private var lastReportedBytes: UInt64 = 0
    private var lastReportTime: TimeInterval = 0
    private var terminalError: AIModelPackageError?

    init(
        partURL: URL,
        expectedBytes: UInt64,
        allowLoopbackHTTP: Bool,
        cancellation: AIModelInstallCancellation,
        onBytesWritten: @escaping @Sendable (UInt64) -> Void
    ) {
        self.partURL = partURL
        self.expectedBytes = expectedBytes
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.cancellation = cancellation
        self.onBytesWritten = onBytesWritten
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        let handle = fileHandle
        fileHandle = nil
        let cont = continuation
        continuation = nil
        lock.unlock()
        try? handle?.close()
        guard let cont else { return }
        switch result {
        case .success:
            cont.resume()
        case .failure(let error):
            cont.resume(throwing: error)
        }
    }

    private func fail(_ error: AIModelPackageError, task: URLSessionTask) {
        lock.lock()
        if terminalError == nil {
            terminalError = error
        }
        let handle = fileHandle
        fileHandle = nil
        lock.unlock()
        try? handle?.close()
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              let scheme = target.scheme?.lowercased(),
              let host = target.host?.lowercased(),
              !host.isEmpty,
              (scheme == "https" || (allowLoopbackHTTP && scheme == "http" && AIModelPackageDescriptor.isLoopbackHost(host))) else {
            fail(.insecureURL, task: task)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if cancellation.isCancelled {
            fail(.cancelled, task: dataTask)
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            fail(.networkError("Non-HTTP response"), task: dataTask)
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            let error: AIModelPackageError = http.statusCode == 404 ? .httpNotFound : .httpStatus(http.statusCode)
            fail(error, task: dataTask)
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > 0 && UInt64(http.expectedContentLength) != expectedBytes {
            fail(.archiveSizeMismatch(expected: expectedBytes, actual: UInt64(http.expectedContentLength)), task: dataTask)
            completionHandler(.cancel)
            return
        }

        let fd = Darwin.open(partURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else {
            fail(errno == ENOSPC ? .diskFull : .fileSystemError(String(cString: strerror(errno))), task: dataTask)
            completionHandler(.cancel)
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lock.lock()
        fileHandle = handle
        receivedBytes = 0
        lastReportedBytes = 0
        lastReportTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if cancellation.isCancelled {
            fail(.cancelled, task: dataTask)
            return
        }
        lock.lock()
        let handle = fileHandle
        let nextTotal = receivedBytes &+ UInt64(data.count)
        let failedAlready = terminalError != nil
        lock.unlock()

        if failedAlready { return }
        guard let handle else {
            fail(.fileSystemError("Missing download file handle"), task: dataTask)
            return
        }
        if nextTotal > expectedBytes {
            fail(.archiveSizeMismatch(expected: expectedBytes, actual: nextTotal), task: dataTask)
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(AIModelPackageStore.mapFileSystemError(error), task: dataTask)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        var shouldReport = false
        lock.lock()
        receivedBytes = nextTotal
        if lastReportedBytes == 0
            || nextTotal == expectedBytes
            || nextTotal &- lastReportedBytes >= 256 * 1024
            || now - lastReportTime >= 0.1 {
            lastReportedBytes = nextTotal
            lastReportTime = now
            shouldReport = true
        }
        lock.unlock()

        if shouldReport {
            onBytesWritten(nextTotal)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let recorded = terminalError
        let handle = fileHandle
        fileHandle = nil
        let totalWritten = receivedBytes
        lock.unlock()

        do {
            try handle?.synchronize()
            try handle?.close()
        } catch {
            if recorded == nil {
                finish(with: .failure(AIModelPackageStore.mapFileSystemError(error)))
                return
            }
        }

        if let recorded {
            finish(with: .failure(recorded))
            return
        }
        if cancellation.isCancelled {
            finish(with: .failure(AIModelPackageError.cancelled))
            return
        }
        if let error {
            finish(with: .failure(Self.mapURLError(error)))
            return
        }
        if totalWritten != expectedBytes {
            finish(with: .failure(AIModelPackageError.archiveSizeMismatch(expected: expectedBytes, actual: totalWritten)))
            return
        }
        onBytesWritten(totalWritten)
        finish(with: .success(()))
    }

    private static func mapURLError(_ error: Error) -> AIModelPackageError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .networkError(error.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorTimedOut:
            return .networkTimeout
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return .networkUnavailable
        default:
            return .networkError(error.localizedDescription)
        }
    }
}

// MARK: - Observable State Machine (No AppKit/SwiftUI dependency)

public final class AIModelPackageManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var state: AIModelPackageState = .unavailable

    public let store: AIModelPackageStore
    private let isRuntimeSupported: () -> Bool
    private let isHardwareAvailable: () -> Bool
    private let overrideProvider: () -> URL?
    private let bundledProvider: () -> URL?
    public var onInstallStateChanged: (() -> Void)?

    private var activeTask: Task<Void, Never>?
    private var activeCancellation: AIModelInstallCancellation?

    public init(
        store: AIModelPackageStore,
        isRuntimeSupported: @escaping () -> Bool,
        isHardwareAvailable: @escaping () -> Bool = { true },
        overrideProvider: @escaping () -> URL? = { nil },
        bundledProvider: @escaping () -> URL? = { nil }
    ) {
        self.store = store
        self.isRuntimeSupported = isRuntimeSupported
        self.isHardwareAvailable = isHardwareAvailable
        self.overrideProvider = overrideProvider
        self.bundledProvider = bundledProvider
        refresh()
    }

    public func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !state.isBusy else { return }
        applyDiskState()
    }

    private func computeDiskState() -> AIModelPackageState {
        guard isRuntimeSupported() else {
            return .unavailable
        }
        let unpackedBytes = store.descriptor?.unpackedBytes ?? 0
        if let source = store.resolveModelDirectory(override: overrideProvider(), bundled: bundledProvider()) {
            return .installed(source, unpackedBytes: unpackedBytes)
        }
        guard isHardwareAvailable(), let descriptor = store.descriptor else {
            return .unavailable
        }
        return .notInstalled(downloadBytes: descriptor.archiveBytes, unpackedBytes: descriptor.unpackedBytes)
    }

    private func applyDiskState() {
        state = computeDiskState()
    }

    private static func installedSource(for state: AIModelPackageState) -> AIModelDirectorySource? {
        if case .installed(let source, _, _) = state { return source }
        return nil
    }

    /// 仅由用户显式点击“下载模型”或“重试”触发。
    public func startDownload() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !state.isBusy, !state.isInstalled, isRuntimeSupported(), let descriptor = store.descriptor else { return }
        guard isHardwareAvailable() else {
            applyDiskState()
            return
        }
        let wasInstalled = state.isInstalled
        let cancellation = AIModelInstallCancellation()
        activeCancellation = cancellation
        state = .downloading(completedBytes: 0, totalBytes: descriptor.archiveBytes)

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.store.downloadAndInstall(cancellation: cancellation) { [weak self] phase in
                    DispatchQueue.main.async {
                        guard let self, self.activeCancellation === cancellation, !cancellation.isCancelled else { return }
                        switch phase {
                        case .downloading(let done, let total):
                            self.state = .downloading(completedBytes: done, totalBytes: total)
                        case .verifying:
                            self.state = .verifying
                        case .installing:
                            self.state = .installing
                        }
                    }
                }
                await MainActor.run {
                    guard self.activeCancellation === cancellation else { return }
                    self.activeCancellation = nil
                    self.activeTask = nil
                    self.applyDiskState()
                    if self.state.isInstalled != wasInstalled || self.state.isInstalled {
                        self.onInstallStateChanged?()
                    }
                }
            } catch {
                let mapped: AIModelPackageError
                if let pkgError = error as? AIModelPackageError {
                    mapped = pkgError
                } else if error is CancellationError || cancellation.isCancelled {
                    mapped = .cancelled
                } else {
                    mapped = .fileSystemError(error.localizedDescription)
                }
                await MainActor.run {
                    guard self.activeCancellation === cancellation else { return }
                    self.activeCancellation = nil
                    self.activeTask = nil
                    if mapped == .cancelled || cancellation.isCancelled {
                        // 取消若发生在最终原子改名窗口内，以磁盘真实结果为准，不误报已取消。
                        if let resolved = self.store.resolveModelDirectory(
                            override: self.overrideProvider(),
                            bundled: self.bundledProvider()
                        ) {
                            self.state = .installed(resolved, unpackedBytes: descriptor.unpackedBytes)
                            if !wasInstalled {
                                self.onInstallStateChanged?()
                            }
                        } else {
                            self.state = .cancelled(
                                downloadBytes: descriptor.archiveBytes,
                                unpackedBytes: descriptor.unpackedBytes
                            )
                        }
                    } else {
                        self.state = .failed(
                            mapped,
                            downloadBytes: descriptor.archiveBytes,
                            unpackedBytes: descriptor.unpackedBytes
                        )
                    }
                }
            }
        }
    }

    public func cancelDownload() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let cancellation = activeCancellation else { return }
        cancellation.cancel()
        activeTask?.cancel()
    }

    public func removeDownloadedModel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !state.isBusy else { return }
        let previousSource = Self.installedSource(for: state)
        do {
            try store.removeInstalledPackages()
            applyDiskState()
            if Self.installedSource(for: state) != previousSource || previousSource != nil {
                onInstallStateChanged?()
            }
        } catch {
            let mapped: AIModelPackageError = (error as? AIModelPackageError) ?? .removeFailed(error.localizedDescription)
            let diskState = computeDiskState()
            if case .installed(let source, let unpackedBytes, _) = diskState {
                // 模型包仍在磁盘上：保留已安装状态以继续提供删除入口，不把“重试”接到重新下载，也不误报已卸载。
                state = .installed(source, unpackedBytes: unpackedBytes, removeError: mapped)
            } else if let descriptor = store.descriptor, isRuntimeSupported(), isHardwareAvailable() {
                state = .failed(mapped, downloadBytes: descriptor.archiveBytes, unpackedBytes: descriptor.unpackedBytes)
                if previousSource != nil {
                    onInstallStateChanged?()
                }
            } else {
                state = diskState
                if previousSource != nil {
                    onInstallStateChanged?()
                }
            }
        }
    }
}
#endif
