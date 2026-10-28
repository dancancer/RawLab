import Photos
import PhotosUI
import SwiftUI
import UIKit

extension BatchExportModel {
    func render(target: BatchTarget, settings: RawSettings, look: URL?, longEdge: Int?) throws -> Data {
        return try autoreleasepool {
            let processor = Sony2FujiProcessor()
            let result: Sony2FujiProcessor.ProcessResult
            if target.sourceKind == .raw {
                let raw = try processor.processRaw(url: target.sourceURL, settings: settings,
                                                    previewLongEdge: nil, lutURL: look,
                                                    exportLongEdge: longEdge)
                result = raw
            } else {
                let raster = try processor.loadRasterBuffer(url: target.sourceURL)
                let buffer = try processor.processBuffer(buffer: raster.buffer, settings: settings,
                                                         previewLongEdge: nil, lutURL: look,
                                                         exportLongEdge: longEdge)
                result = Sony2FujiProcessor.ProcessResult(buffer: buffer, orientation: .up,
                                                          rawWhiteBalance: nil)
            }
            return try processor.makeJPEGData(from: result.buffer, sourceURL: target.sourceURL,
                                              orientation: result.orientation, quality: 0.92)
        }
    }

    func renderDNG(target: BatchTarget, settings: RawSettings, look: URL?, longEdge: Int?, jobID: UUID) throws -> URL {
        return try autoreleasepool {
            let processor = Sony2FujiProcessor()
            let output = BatchFileOutputStore.temporaryURL(for: jobID, outputName: target.outputName)
            _ = try BatchFileOutputStore.directory(for: jobID)
            do {
                if target.sourceKind == .raw {
                    try processor.exportDNG(url: target.sourceURL, settings: settings, lutURL: look,
                                            outputURL: output, exportLongEdge: longEdge)
                } else {
                    let raster = try processor.loadRasterBuffer(url: target.sourceURL)
                    try processor.exportDNG(buffer: raster.buffer, settings: settings, lutURL: look,
                                            outputURL: output, exportLongEdge: longEdge)
                }
                return output
            } catch let error as Sony2FujiProcessor.ProcessorError {
                try? FileManager.default.removeItem(at: output)
                if case .outputIO = error {
                    throw BatchExportError.global(error.localizedDescription)
                }
                throw error
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
    }

    func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    func prepareTarget(_ source: PhotoImportSource, identity: PhotoIdentity, jobID: UUID,
                               journalStore: BatchJournalStore) async throws -> BatchTarget {
        let processing = job.source.settings.processing
        return try await perform {
            let owned = try BatchInputStore.copy(source.url, identity: identity, jobID: jobID,
                                                 root: journalStore.directory)
            let processor = Sony2FujiProcessor()
            var neutral = RawSettings.default
            neutral.processing = processing
            if source.isRaw {
                _ = try processor.processRaw(url: owned, settings: neutral,
                                             previewLongEdge: 160, lutURL: nil)
            } else {
                let raster = try processor.loadRasterBuffer(url: owned)
                _ = try processor.processBuffer(buffer: raster.buffer, settings: neutral,
                                                previewLongEdge: 160, lutURL: nil)
            }
            return BatchTarget(identity: identity, sourceURL: owned,
                               displayName: source.displayName,
                               sourceKind: source.isRaw ? .raw : .raster)
        }
    }
}
