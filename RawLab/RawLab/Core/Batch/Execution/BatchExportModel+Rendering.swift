import Photos
import PhotosUI
import SwiftUI
import UIKit

final class IOSHDRBatchPreparation {
    private let source: BatchSourceSnapshot
    private let store: EditPersistence?
    private let looks: [String:URL]
    init(source: BatchSourceSnapshot,editor: RawEditorViewModel) {
        self.source=source; store=editor.editPersistence
        looks=editor.lutMap.mapValues(\.sourceURL)
    }
    func prepare(_ target: BatchTarget,ordinal: Int,format: BatchOutputFormat,longEdge: Int?) throws -> BatchFrozenSettings {
        guard let store else { throw EditPersistenceError.corruptStore }
        let record=try store.versionedState(for:target.identity)
        let info=try HDRSourceInfo.probe(target.sourceURL)
        var defaults=RawSettings.default
        if info != nil { defaults.hdr=HDRSettings() }
        let previous=record.state ?? PhotoEditState(settings:defaults)
        let payload=try HDRAdjustmentTransfer.batchPayload(settings:source.settings.hdr!,identifier:source.identity.key,
            processingVersion:source.settings.processing.version,targetIsHDR:previous.settings.isHDREditing)
        let context=IOSAdjustmentTransferContext(identifier:target.id,isRaw:target.sourceKind == .raw,sourceIsHDR:info != nil)
        let prepared=try IOSAdjustmentTransfer.prepare(payload:payload,target:previous,context:context)
        let settings=prepared.settings
        let look: URL?
        if settings.isHDREditing { look=nil }
        else if let recipe=settings.masterRecipeID { look=MasterRecipe.recipe(for:recipe)?.lutURL() }
        else if let id=settings.lutID,id.hasPrefix("recipe-lut:") { look=MasterRecipe.recipe(for:String(id.dropFirst("recipe-lut:".count)))?.lutURL() }
        else { look=settings.lutID.flatMap { looks[$0] } }
        guard !settings.hasLook || look != nil else { throw BatchExportError.target(L10n.text("目标所需的外观不可用，请先导入外观。")) }
        let hash=try PhotoIdentity.fallback(for:target.sourceURL).contentIdentifier!
        return BatchFrozenSettings(ordinal:ordinal,settings:settings,inputSHA256:hash,lookURL:look,
            lookSHA256:try look.flatMap { try PhotoIdentity.fallback(for:$0).contentIdentifier },
            lookName:settings.isHDREditing ? "HDR" : settings.masterRecipe?.name,outputFormat:format,longEdge:longEdge)
    }
}

extension BatchExportModel {
    func render(target: BatchTarget, settings: RawSettings, look: URL?, longEdge: Int?, format: BatchOutputFormat = .jpeg) throws -> Data {
        return try autoreleasepool {
            let processor = Sony2FujiProcessor()
            if let hdr=settings.hdr,settings.isHDREditing {
                let pair=try processor.processHDR(url:target.sourceURL,settings:hdr,previewLongEdge:nil,exportLongEdge:longEdge)
                let output=FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-batch-\(UUID().uuidString).jpg")
                defer { try? FileManager.default.removeItem(at:output) }
                if format == .hdrJPEG { try pair.exportJPEG(to:output) }
                else { try pair.exportSDR(to:output,format:SONY2FUJI_OUTPUT_JPEG) }
                return try Data(contentsOf:output)
            }
            guard format != .hdrJPEG else { throw BatchExportError.target(L10n.text("HDR JPEG 需要启用 HDR 编辑。")) }
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
                if let hdr=settings.hdr,settings.isHDREditing {
                    let pair=try processor.processHDR(url:target.sourceURL,settings:hdr,previewLongEdge:nil,exportLongEdge:longEdge)
                    try pair.exportSDR(to:output,format:SONY2FUJI_OUTPUT_DNG)
                } else if target.sourceKind == .raw {
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
        let x3fMode = job.source.settings.x3fMode
        return try await perform {
            let inputDirectory=try BatchInputStore.directory(for:jobID,root:journalStore.directory)
            let existing=Set(try FileManager.default.contentsOfDirectory(at:inputDirectory,includingPropertiesForKeys:nil))
            let owned = try BatchInputStore.copy(source.url, identity: identity, jobID: jobID,
                                                 root: journalStore.directory)
            var accepted=false
            defer { if !accepted && !existing.contains(owned) { try? FileManager.default.removeItem(at:owned) } }
            let processor = Sony2FujiProcessor()
            var neutral = RawSettings.default
            neutral.processing = processing
            neutral.x3fMode = x3fMode
            if source.isRaw {
                _ = try processor.processRaw(url: owned, settings: neutral,
                                             previewLongEdge: 160, lutURL: nil)
            } else {
                if try HDRSourceInfo.probe(owned) != nil {
                    _ = try processor.processHDR(url:owned,settings:HDRSettings(),previewLongEdge:160)
                } else {
                    let raster=try processor.loadRasterBuffer(url:owned)
                    _ = try processor.processBuffer(buffer:raster.buffer,settings:neutral,previewLongEdge:160,lutURL:nil)
                }
            }
            let target=BatchTarget(identity: identity, sourceURL: owned,
                               displayName: source.displayName,
                               sourceKind: source.isRaw ? .raw : .raster)
            if let preparation=self.hdrPreparation {
                _ = try preparation.prepare(target,ordinal:0,format:.jpeg,longEdge:nil)
            }
            accepted=true
            return target
        }
    }
}
