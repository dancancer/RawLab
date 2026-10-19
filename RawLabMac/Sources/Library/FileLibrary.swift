import SwiftUI
import AppKit
import ImageIO
import Combine

struct DirectoryContents {
    let folders: [URL]
    let photos: [URL]
    static let rawExtensions: Set<String> = ["arw", "arq", "dng", "nef", "nrw", "cr2", "cr3", "crw", "raf",
        "rw2", "rwl", "orf", "pef", "srw", "raw", "3fr", "fff", "iiq", "mos", "x3f"]
    static let supportedExtensions = rawExtensions.union(["jpg", "jpeg", "png", "tif", "tiff", "heif", "heic"])

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
    private var loaded = false
    private var folderSubscriptions: [AnyCancellable] = []
    init(_ url: URL) { self.url = url }

    func toggle() { expanded.toggle(); if expanded { load() } }
    func load() {
        guard !loaded, !loading else { return }
        loading = true; error = nil
        let url = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DirectoryContents.read(url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let contents):
                    self.folders = contents.folders.map(PhotoFolder.init)
                    self.photos = contents.photos; self.loaded = true
                case .failure(let error): self.error = error.localizedDescription
                }
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
    func remove(_ root: PhotoFolder) { roots.removeAll { $0.id == root.id }; persist() }
    private func persist() { defaults.set(roots.map { $0.url.path }, forKey: "photoFolders") }
}

// NSCache and OperationQueue are thread-safe; cached CGImage-backed images are immutable.
final class PhotoThumbnails: @unchecked Sendable {
    static let shared = PhotoThumbnails()
    private let cache = NSCache<NSURL, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility; return queue
    }()
    private init() { cache.countLimit = 300 }
    func image(for url: URL) async -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        return await withCheckedContinuation { continuation in
            queue.addOperation { [self] in
                let raster = !DirectoryContents.rawExtensions.contains(url.pathExtension.lowercased())
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                    kCGImageSourceCreateThumbnailFromImageAlways: raster,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 180,
                    kCGImageSourceShouldCache: false]
                var result: NSImage?
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    cache.setObject(result!, forKey: url as NSURL)
                }
                continuation.resume(returning: result)
            }
        }
    }
}
