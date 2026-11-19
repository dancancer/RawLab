import Foundation

/* 只在本文件内暴露所有者，读者通过 PhotoSourceFile 取得受保护的路径。 */
private final class CachedPhotoFile: @unchecked Sendable {
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

public struct PhotoSourceFile: Codable, Equatable, Sendable {
    private let url: URL
    private let owner: CachedPhotoFile?

    private init(url: URL, owner: CachedPhotoFile?) {
        self.url = url
        self.owner = owner
    }

    public static func copy(_ source: URL) throws -> Self {
        let owner = try CachedPhotoFile.copy(source)
        return Self(url: owner.url, owner: owner)
    }

    /* Bundle、测试素材和 batch journal 自行管理文件，本值不得删除它们。 */
    public static func externallyManaged(_ url: URL) -> Self { Self(url: url, owner: nil) }

    public var displayName: String { url.lastPathComponent }
    public func matches(_ url: URL) -> Bool { self.url == url }

    /* 应用缓存副本在进程内路径稳定（LUT 兼容向导据此只读引用原片）；外部托管 URL 保留拷贝语义。 */
    public var persistentLocalURL: URL? { owner == nil ? nil : url }

    /* 在后台闭包内调用；读取必须在闭包返回前完成，不能将裸路径交给另一个异步任务。 */
    public func withReadAccess<T>(_ read: (URL) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try read(url) }
    }

    /* Journal 只存原有 URL，恢复后的文件生命周期仍由 batch 存储管理。 */
    public init(from decoder: Decoder) throws {
        self = .externallyManaged(try decoder.singleValueContainer().decode(URL.self))
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(url)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
}
