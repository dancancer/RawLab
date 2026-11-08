import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers
import PhotosUI
import SwiftUI

struct PhotoImportSource {
    let url: URL
    let isRaw: Bool
    var originalName: String? = nil

    static func raw(_ url: URL) -> Self { Self(url: url, isRaw: true) }
    static func raster(_ url: URL) -> Self { Self(url: url, isRaw: false) }

    var displayName: String {
        let name = originalName ?? url.lastPathComponent
        return name.isEmpty ? (isRaw ? "RAW" : L10n.text("照片")) : name
    }
}

enum PhotoImportError: LocalizedError {
    case unsupportedItem
    case loadFailed
    case rawResourceUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem:
            return L10n.text("Selected item is not a supported image.")
        case .loadFailed:
            return L10n.text("Failed to load the selected photo.")
        case .rawResourceUnavailable:
            return L10n.text("无法取得 RAW 原片，请在系统设置中授权访问这张照片后重试。")
        }
    }
}

struct RawPhotoFile: Transferable {
    let source: PhotoImportSource

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { file in
            RawPhotoFile(source: try PhotoImportFile.retainSource(file.file))
        }
    }
}

struct ImagePhotoFile: Transferable {
    let source: PhotoImportSource

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            ImagePhotoFile(source: try PhotoImportFile.retainSource(file.file))
        }
    }
}

struct PhotoImportFile: Transferable {
    let source: PhotoImportSource

    // 系统拖放统一走一个 FileRepresentation，避免同一画布注册两个 dropDestination 后互相覆盖。
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { file in
            PhotoImportFile(source: try retainSource(file.file))
        }
    }

    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("RawLabImports", isDirectory: true) }
    // Files may advertise an arbitrary type for a renamed photo.
    static let photoPickerContentTypes: [UTType] = [.data]
    static let supportedLookContentTypes: [UTType] = ["cube", "vlt", "rlook", "dcp"].compactMap {
        UTType(filenameExtension: $0)
    }

    static func fileURLs(from urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter {
            $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true &&
                seen.insert($0.standardizedFileURL).inserted
        }
    }

    static func appendSystemPhotoEvent(_ urls: [URL], to pending: [[URL]]) -> [[URL]] {
        let files = fileURLs(from: urls)
        return files.isEmpty ? pending : pending + [files]
    }

    static func consumeSystemPhotoEvent(from pending: [[URL]]) -> (current: [URL], remaining: [[URL]])? {
        guard let current = pending.first else { return nil }
        return (current, Array(pending.dropFirst()))
    }

    static func retainSource(_ source: URL) throws -> PhotoImportSource {
        try retainSource(source, documentsDirectory: applicationDocumentsDirectory)
    }

    static func retainSource(_ source: URL, documentsDirectory: URL) throws -> PhotoImportSource {
        let retained = try retain(source, filename: "source")
        let originalName = source.lastPathComponent
        let identified = try identifyRetainedSource(retained, originalName: originalName)
        if isApplicationInboxFile(source, documentsDirectory: documentsDirectory) {
            // iOS 在 LSSupportsOpeningDocumentsInPlace=false 时把原文件放进应用 Inbox；确认副本可读后再清理它。
            try? FileManager.default.removeItem(at: source)
        }
        return identified
    }

    static func isApplicationInboxFile(_ source: URL, documentsDirectory: URL) -> Bool {
        let expectedInbox = documentsDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        let inbox = expectedInbox.resolvingSymlinksInPath().standardizedFileURL
        guard inbox == expectedInbox else { return false }
        let candidate = source.resolvingSymlinksInPath().standardizedFileURL
        return candidate.path.hasPrefix(inbox.path + "/")
    }

    // Transferable 已完成私有副本；队列接管同一临时目录，只改文件名，不再复制整张 RAW。
    static func renameRetainedSource(_ source: URL, filename: String) throws -> URL {
        let folder = source.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else {
            throw PhotoImportError.unsupportedItem
        }
        let destination = folder.appendingPathComponent(filename)
        guard destination.standardizedFileURL != source.standardizedFileURL else { return source }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private static var applicationDocumentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
    }

    static func load(fromFile url: URL) async throws -> PhotoImportSource {
        try await loadSource {
            try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try retainSource(url)
            }.value
        }
    }

    private static func identifyRetainedSource(_ url: URL, originalName: String) throws -> PhotoImportSource {
        do {
            let format = try detectFormat(at: url)
            var suffix = format.suffix
            if suffix == "raw" {
                // Keep an ImageIO decoder hint for RAW formats whose container alone is ambiguous.
                let hint = (originalName as NSString).pathExtension.lowercased()
                if !["arw", "dng", "x3f"].contains(hint),
                   UTType(filenameExtension: hint)?.conforms(to: .rawImage) == true {
                    suffix = hint
                }
            }
            let normalized = url.appendingPathExtension(suffix)
            try FileManager.default.moveItem(at: url, to: normalized)
            return PhotoImportSource(url: normalized, isRaw: format.isRaw, originalName: originalName)
        } catch {
            release(url)
            throw error
        }
    }

    private static func detectFormat(at url: URL) throws -> (isRaw: Bool, suffix: String) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 8) ?? Data()
        if header.starts(with: "FOVb".utf8) { return (true, "x3f") }
        if try containsDNGVersion(header, in: file) { return (true, "dng") }

        // The retained input has no extension while ImageIO inspects the container.
        let type = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceGetType($0) as String? }
            .flatMap { UTType($0) }
        if let type, let suffix = type.preferredFilenameExtension {
            if type.conforms(to: .rawImage) { return (true, suffix) }
            if [.jpeg, .png, .heic, .heif].contains(type) { return (false, suffix) }
        }

        #if os(iOS)
        // TIFF can contain a sensor RAW, and ImageIO can identify a renamed ARW only as TIFF.
        switch url.path.withCString({ rawlab_probe_raw_file($0) }) {
        case RAWLAB_FILE_SONY_RAW: return (true, "arw")
        case RAWLAB_FILE_RAW: return (true, "raw")
        default: break
        }
        #endif

        if type == .tiff { return (false, "tiff") }
        throw PhotoImportError.unsupportedItem
    }

    private static func containsDNGVersion(_ header: Data, in file: FileHandle) throws -> Bool {
        guard header.count == 8 else { return false }
        let littleEndian = header.starts(with: [0x49, 0x49, 42, 0])
        guard littleEndian || header.starts(with: [0x4d, 0x4d, 0, 42]) else { return false }

        func number<T: FixedWidthInteger>(_ bytes: Data, at offset: Int, as type: T.Type) -> T {
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
            return littleEndian ? T(littleEndian: value) : T(bigEndian: value)
        }

        // DNGVersion is a four-byte field in the first TIFF directory.
        let directoryOffset = number(header, at: 4, as: UInt32.self)
        guard directoryOffset >= 8 else { return false }
        try file.seek(toOffset: UInt64(directoryOffset))
        guard let count = try file.read(upToCount: 2), count.count == 2 else { return false }
        let entrySize = 12
        let length = Int(number(count, at: 0, as: UInt16.self)) * entrySize
        guard length > 0, let entries = try file.read(upToCount: length), entries.count == length else { return false }
        return stride(from: 0, to: length, by: entrySize).contains { offset in
            number(entries, at: offset, as: UInt16.self) == 50706 &&
                number(entries, at: offset + 2, as: UInt16.self) == 1 &&
                number(entries, at: offset + 4, as: UInt32.self) == 4
        }
    }

    static func retain(_ source: URL, filename: String? = nil) throws -> URL {
        guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
            throw PhotoImportError.unsupportedItem
        }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(filename ?? source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination); return destination }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    static func release(_ source: URL) {
        let folder = source.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func loadSource(using load: () async throws -> PhotoImportSource) async throws -> PhotoImportSource {
        try Task.checkCancellation()
        let source = try await load()
        do {
            try Task.checkCancellation()
            return source
        } catch {
            release(source.url)
            throw error
        }
    }

    static func load(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        try await loadSource { try await loadOriginal(from:item) }
    }

    private static func loadOriginal(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        let supportsRaw = item.supportedContentTypes.contains(where: { $0.conforms(to: .rawImage) })
        var rawError: Error?
        if supportsRaw {
            do {
                if let raw = try await item.loadTransferable(type: RawPhotoFile.self) { return raw.source }
            } catch { rawError = error }
        }
        if let identifier = item.itemIdentifier {
            var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if access == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            if access == .authorized || access == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                let resources=PHAssetResource.assetResources(for:asset)
                let raw=resources.first { UTType($0.uniformTypeIdentifier)?.conforms(to:.rawImage) == true }
                // .photo 是相册保留的原容器；已调整的 fullSizePhoto 可能丢失增益图。
                let resource=raw ?? (!supportsRaw ? resources.first { $0.type == .photo } : nil)
                if let resource {
                    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("source")
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true
                    do {
                        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
                        try Task.checkCancellation()
                    } catch { release(url); throw error }
                    return try identifyRetainedSource(url, originalName: resource.originalFilename)
                }
            }
        }
        if supportsRaw { throw rawError ?? PhotoImportError.rawResourceUnavailable }
        guard let image = try await item.loadTransferable(type: ImagePhotoFile.self) else { throw PhotoImportError.loadFailed }
        return image.source
    }
}
