import CryptoKit
import Darwin
import Foundation

struct PhotoPreviewCacheKey: Hashable, Sendable {
    let digest: String

    static var rendererVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "development")-\(info["CFBundleVersion"] as? String ?? "0")"
    }
    init(identity: Data, adjustments: Data, resources: Data = Data(), edge: Int, rendererVersion: String = Self.rendererVersion) {
        var hash = SHA256()
        // 长度前缀避免不同字段在拼接边界上生成相同输入。
        for component in [Data("edited-photo-preview-v1".utf8), Data(rendererVersion.utf8), identity, adjustments, resources, Data(String(edge).utf8)] {
            var length = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: component)
        }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 缓存文件操作观测点（测试 seam，沿用 MacResourceDigestCache `onHash` 计数惯例）。
/// `atomicWrite` 是被替换掉的旧路径：Foundation 原子写自带强制落盘语义（WriteThrough/fsync 档）；
/// 新路径为 `plainWrite`（普通缓冲写临时文件）+ `rename`（原子替换正式文件），崩溃不会留下半张正式文件。
enum EditedPhotoPreviewFileOperation: Equatable, Sendable {
    case scan, plainWrite, atomicWrite, rename
}

final class EditedPhotoPreviewCache: @unchecked Sendable {
    private let directory: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let lock = NSLock()
    // 进程内 LRU 索引（digest→字节数，order 由旧到新）：淘汰只查索引，不再每写一次
    // 全目录枚举 + stat（256 张约 3.3 万次）。仅首次访问加载一次；索引命中即视为
    // 文件存在，外部删除（系统缓存清理）在读取失败时剔除并按 miss 重渲染自愈。
    // 跨进程共享目录时每实例各自加载一次，并发双开时配额为软上限。
    private var order: [String]?
    private var sizes: [String: Int] = [:]
    private var indexedBytes = 0
    var observeFileOperation: ((EditedPhotoPreviewFileOperation) -> Void)?

    init(directory: URL, maximumEntries: Int = 256, maximumBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    func read(_ key: PhotoPreviewCacheKey) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        ensureLoaded()
        guard sizes[key.digest] != nil else { return nil }
        do {
            let data = try Data(contentsOf: location(key))
            touch(key.digest)
            return data
        } catch {
            // 文件已被外部删除：索引条目剔除，本张按 miss 重渲染并回写。
            removeIndexed(key.digest)
            return nil
        }
    }

    func write(_ data: Data, for key: PhotoPreviewCacheKey) throws {
        guard data.count <= maximumBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        ensureLoaded()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = location(key)
        let temporary = directory.appendingPathComponent("\(key.digest).\(UUID().uuidString).tmp")
        do {
            observeFileOperation?(.plainWrite)
            try data.write(to: temporary)
            observeFileOperation?(.rename)
            // 同目录 rename(2)：原子替换正式文件（Darwin moveItem 撞名会报错），读侧永不看到半张文件。
            guard rename(temporary.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "Preview rename failed with errno \(errno): \(target.path)"])
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        removeIndexed(key.digest)
        insertTail(key.digest, size: data.count)
        while let order, order.count > maximumEntries || indexedBytes > maximumBytes, let victim = order.first {
            evict(victim, manager: manager)
        }
    }

    private func location(_ key: PhotoPreviewCacheKey) -> URL {
        directory.appendingPathComponent(key.digest).appendingPathExtension("preview")
    }

    private func location(_ digest: String) -> URL {
        directory.appendingPathComponent(digest).appendingPathExtension("preview")
    }

    // 首次访问加载磁盘现状：一次枚举按 mtime 排出淘汰次序（与旧的每次全扫排序等价），
    // 目录缺失或不可读按空索引处理（读取 miss、写入前 createDirectory 负责真实报错）。
    private func ensureLoaded() {
        guard order == nil else { return }
        observeFileOperation?(.scan)
        var entries: [(digest: String, modified: Date)] = []
        var loadedSizes: [String: Int] = [:]
        var bytes = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        if let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) {
            for url in urls where url.pathExtension == "preview" {
                let values = try? url.resourceValues(forKeys: keys)
                let digest = url.deletingPathExtension().lastPathComponent
                let size = values?.fileSize ?? 0
                loadedSizes[digest] = size
                bytes += size
                entries.append((digest, values?.contentModificationDate ?? .distantPast))
            }
        }
        order = entries.sorted {
            $0.modified == $1.modified ? $0.digest < $1.digest : $0.modified < $1.modified
        }.map(\.digest)
        sizes = loadedSizes
        indexedBytes = bytes
    }

    private func touch(_ digest: String) {
        guard order != nil, let position = order?.firstIndex(of: digest) else { return }
        order?.remove(at: position)
        order?.append(digest)
    }

    private func insertTail(_ digest: String, size: Int) {
        sizes[digest] = size
        indexedBytes += size
        order?.append(digest)
    }

    private func removeIndexed(_ digest: String) {
        guard let size = sizes.removeValue(forKey: digest) else { return }
        indexedBytes -= size
        if let position = order?.firstIndex(of: digest) { order?.remove(at: position) }
    }

    // 外部已删除的文件也必须从索引剔除，保证清退循环必定收敛。
    private func evict(_ digest: String, manager: FileManager) {
        try? manager.removeItem(at: location(digest))
        removeIndexed(digest)
    }
}
