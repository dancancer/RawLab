import Foundation

/* 异步读者必须与 URL 一起保留所有者，直到最后一次读取结束。 */
final class CachedPhotoFile {
    let url: URL

    private static let directoryLock = NSLock()
    private static var directory: URL?

    private static func prepareDirectory() throws -> URL {
        directoryLock.lock()
        defer { directoryLock.unlock() }
        if let directory { return directory }
        let manager = FileManager.default
        let root = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RawLab/ImportedPhotos", isDirectory: true)
        /* 首次使用时回收上次进程遗留的副本，不碰旧版 identity 文件。 */
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root
        return root
    }

    private init(url: URL) { self.url = url }

    static func copy(_ source: URL) throws -> CachedPhotoFile {
        let name = UUID().uuidString + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
        let file = CachedPhotoFile(url: try prepareDirectory().appendingPathComponent(name))
        try FileManager.default.copyItem(at: source, to: file.url)
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
