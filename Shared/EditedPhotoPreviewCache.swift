import CryptoKit
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

final class EditedPhotoPreviewCache: @unchecked Sendable {
    private let directory: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let lock = NSLock()

    init(directory: URL, maximumEntries: Int = 256, maximumBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    func read(_ key: PhotoPreviewCacheKey) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let url = location(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, for key: PhotoPreviewCacheKey) throws {
        guard data.count <= maximumBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = location(key)
        try data.write(to: target, options: .atomic)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "preview" }
            .compactMap { url -> (URL, Int, Date)? in
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
            .sorted { lhs, rhs in
                // 文件系统时间精度相同时也保留刚完成的这张预览。
                if lhs.0 == target { return false }
                if rhs.0 == target { return true }
                return lhs.2 == rhs.2 ? lhs.0.lastPathComponent < rhs.0.lastPathComponent : lhs.2 < rhs.2
            }
        var remaining = entries.count
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where remaining > maximumEntries || bytes > maximumBytes {
            try manager.removeItem(at: url)
            remaining -= 1
            bytes -= size
        }
    }

    private func location(_ key: PhotoPreviewCacheKey) -> URL {
        directory.appendingPathComponent(key.digest).appendingPathExtension("preview")
    }
}
