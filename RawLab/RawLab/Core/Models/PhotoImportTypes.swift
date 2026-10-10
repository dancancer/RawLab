import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import PhotosUI
import SwiftUI

enum PhotoImportSource {
    case raw(URL)
    case raster(URL)

    var url: URL {
        switch self {
        case .raw(let url), .raster(let url):
            return url
        }
    }

    var isRaw: Bool {
        switch self {
        case .raw:
            return true
        case .raster:
            return false
        }
    }

    var displayName: String {
        url.lastPathComponent.isEmpty ? (isRaw ? "RAW" : "照片") : url.lastPathComponent
    }
}

enum PhotoImportError: LocalizedError {
    case unsupportedItem
    case loadFailed
    case rawResourceUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem:
            return "Selected item is not a supported image."
        case .loadFailed:
            return "Failed to load the selected photo."
        case .rawResourceUnavailable:
            return "无法取得 RAW 原片，请在系统设置中授权访问这张照片后重试。"
        }
    }
}

struct RawPhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { file in
            RawPhotoFile(url: try PhotoImportFile.retain(file.file))
        }
    }
}

struct ImagePhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            ImagePhotoFile(url: try PhotoImportFile.retain(file.file))
        }
    }
}

enum PhotoImportFile {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("RawLabImports", isDirectory: true) }

    static func retain(_ source: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination); return destination }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    static func release(_ source: URL) {
        let folder = source.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func load(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        let supportsRaw = item.supportedContentTypes.contains(where: { $0.conforms(to: .rawImage) })
        var rawError: Error?
        if supportsRaw {
            do {
                if let raw = try await item.loadTransferable(type: RawPhotoFile.self) { return .raw(raw.url) }
            } catch { rawError = error }
        }
        if let identifier = item.itemIdentifier {
            var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if access == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            if access == .authorized || access == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
               let resource = PHAssetResource.assetResources(for: asset).first(where: {
                   UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
               }) {
                let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(resource.originalFilename)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                do {
                    try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
                    return .raw(url)
                } catch { release(url); throw error }
            }
        }
        if supportsRaw { throw rawError ?? PhotoImportError.rawResourceUnavailable }
        guard let image = try await item.loadTransferable(type: ImagePhotoFile.self) else { throw PhotoImportError.loadFailed }
        if UTType(filenameExtension: image.url.pathExtension)?.conforms(to: .rawImage) == true { return .raw(image.url) }
        return .raster(image.url)
    }
}
