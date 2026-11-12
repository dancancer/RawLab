import Foundation
import ImageIO
import UIKit

enum ImageSourceKind {
    case raw
    case raster
}

enum EditorError: LocalizedError {
    case noImageLoaded
    case renderFailed
    case sampleNotFound

    var errorDescription: String? {
        switch self {
        case .noImageLoaded:
            return L10n.text("No image loaded.")
        case .renderFailed:
            return L10n.text("Image render failed.")
        case .sampleNotFound:
            return L10n.text("Sample RAW not found.")
        }
    }
}

extension RawEditorViewModel {
    struct RawPreviewBase {
        let buffer: Sony2FujiProcessor.Buffer
        let previewBuffer: Sony2FujiProcessor.Buffer
        let basePreviewImage: UIImage?
        let baseHistogram: Sony2FujiProcessor.RGBHistogram?
        let lutID: String?
        let lutApplied: Bool
        let orientation: CGImagePropertyOrientation?
        let rawWhiteBalance: Sony2FujiProcessor.RawWhiteBalance?
    }

    struct RasterPreviewBase {
        let buffer: Sony2FujiProcessor.Buffer
        let previewBuffer: Sony2FujiProcessor.Buffer
        let basePreviewImage: UIImage?
        let baseHistogram: Sony2FujiProcessor.RGBHistogram?
        let orientation: CGImagePropertyOrientation?
    }

    func buildRawPreviewBase(url: URL, geometry: GeometrySettings = GeometrySettings(),
                             processing: ProcessingIdentity = .current, x3fMode: X3fMode = .normal,
                             lens: LensCorrectionSettings = LensCorrectionSettings()) throws -> RawPreviewBase {
        var neutral = RawSettings.default
        neutral.processing = processing
        neutral.x3fMode = x3fMode
        let rawBase = try processor.processRaw(
            url: url,
            settings: neutral,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        let previewBuffer = try processor.processBuffer(
            buffer: rawBase.buffer,
            settings: neutral,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
        neutral.geometry = geometry
        neutral.lensCorrection = lens
        let comparison = geometry.isIdentity && !lens.isEnabled ? rawBase : try processor.processRaw(
            url: url, settings: neutral, previewLongEdge: previewMaxDimension, lutURL: nil)
        let basePreviewImage = processor.makeUIImage(from: comparison.buffer, orientation: .up)
        let baseHistogram = processor.computeRGBHistogram(from: comparison.buffer)

        return RawPreviewBase(
            buffer: rawBase.buffer,
            previewBuffer: previewBuffer,
            basePreviewImage: basePreviewImage,
            baseHistogram: baseHistogram,
            lutID: nil,
            lutApplied: false,
            orientation: rawBase.orientation,
            rawWhiteBalance: rawBase.rawWhiteBalance
        )
    }

    func buildRasterPreviewBase(url: URL, geometry: GeometrySettings = GeometrySettings(),
                                processing: ProcessingIdentity = .current, lens: LensCorrectionSettings = LensCorrectionSettings()) throws -> RasterPreviewBase {
        var neutral = RawSettings.default
        neutral.processing = processing
        let rasterBase = try processor.loadRasterBuffer(url: url, applyingOrientation: true,
                                                        previewLongEdge:Int(previewMaxDimension))
        let baseBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: neutral,
            previewLongEdge: previewMaxDimension,
            lutURL: nil
        )
        var previewBuffer = try processor.processBuffer(
            buffer: rasterBase.buffer,
            settings: neutral,
            previewLongEdge: interactivePreviewMaxDimension,
            lutURL: nil
        )
        previewBuffer.sourceLensMetadata = rasterBase.buffer.sourceLensMetadata
        neutral.geometry = geometry
        neutral.lensCorrection = lens
        let comparison = geometry.isIdentity && !lens.isEnabled ? baseBuffer : try processor.processBuffer(
            buffer: rasterBase.buffer, settings: neutral, previewLongEdge: previewMaxDimension, lutURL: nil)
        let basePreviewImage = processor.makeUIImage(from: comparison, orientation: .up)
        let baseHistogram = processor.computeRGBHistogram(from: comparison)

        return RasterPreviewBase(
            buffer: rasterBase.buffer,
            previewBuffer: previewBuffer,
            basePreviewImage: basePreviewImage,
            baseHistogram: baseHistogram,
            orientation: rasterBase.orientation
        )
    }
}

extension RawEditorViewModel {
    @discardableResult
    func importImage(
        from source: PhotoImportSource,
        identity: PhotoIdentity? = nil,
        settings: RawSettings = .default,
        x3fModeOverride: X3fMode? = nil,
        retainedInput: PhotoSourceFile? = nil,
        diagnosticContext: [String: String] = [:],
        onImported: (() -> Void)? = nil,
        onSettingsRestored: ((RawSettings) -> Void)? = nil
    ) -> UUID {
        cancelQueuedSettingsSave()
        adjustmentInteraction = nil
        adjustmentInteractionRejected = false
        statusMessage = nil
        isBusy = true
        let importRevision = UUID()
        if activeImportRevision==nil { importPreviousRevision=sourceRevision }
        activeImportRevision = importRevision
        sourceRevision = importRevision
        invalidatePreviewRequests()
        previewLongEdge = Int(previewMaxDimension)
        requestedPreviewLongEdge = previewLongEdge

        let sourceKind: ImageSourceKind = source.isRaw ? .raw : .raster
        let input = retainedInput ?? sourceFile.flatMap { $0.matches(source.url) ? $0 : nil }
            ?? .externallyManaged(source.url)

        importQueue.async {
            input.withReadAccess { inputURL in
                defer { PhotoImportFile.release(inputURL) }
                let didStart = inputURL.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        inputURL.stopAccessingSecurityScopedResource()
                    }
                }

                var failedSource: PhotoSourceFile?
                var importIdentity = identity
                var attemptedX3fMode = X3fMode.legacy
                var stage = "restoreEdits"
                var context = diagnosticContext
                context["sourceKind"] = source.isRaw ? "raw" : "raster"
                do {
                    let resolvedIdentity = identity ?? (try? PhotoIdentity.fallback(for: inputURL))
                    importIdentity = resolvedIdentity
                    let record = try resolvedIdentity.flatMap { try self.editPersistence?.readState(for: $0) }
                    if record?.state == nil, let resolvedIdentity {
                        _ = try self.editPersistence?.unverifiedAssetEdit(for: resolvedIdentity)
                    }
                    let state = record?.state
                    var restoredSettings = try state?.settings ?? self.processor.defaultSettings(
                        for: inputURL, isRaw: source.isRaw, x3fModeOverride: x3fModeOverride)
                    if let x3fModeOverride { restoredSettings.x3fMode = x3fModeOverride }
                    attemptedX3fMode = restoredSettings.x3fMode
                    context["restoredEdits"] = String(state != nil)
                    context["mode"] = restoredSettings.isHDREditing ? "hdr" : "sdr"
                    if inputURL.pathExtension.lowercased() == "x3f" { context["x3fMode"] = attemptedX3fMode.rawValue }
                    stage = "cacheSource"
                    let sourceFile = try PhotoSourceFile.copy(inputURL)
                    failedSource = sourceFile
                    try sourceFile.withReadAccess { localURL in
                        stage = "probeHDR"
                        let hdrInfo = sourceKind == .raster
                            ? try HDRSourceInfo.probe(localURL)
                            : try HDRSourceInfo.probeRAW(localURL, processing: restoredSettings.processing.core)
                        let proRAW = hdrInfo?.proRAW
                        if state != nil, restoredSettings.isHDREditing, let hdrInfo {
                            try hdrInfo.validateEditDecodeVersion(restoredSettings.proRAWDecodeVersion)
                        } else if proRAW != nil, restoredSettings.isHDREditing {
                            try ProRAWSource.validatedDecodeVersion(restoredSettings.proRAWDecodeVersion)
                        }
                        let cameraHDR = hdrInfo?.isDevelopedRAW == true
                        let rasterHDR = hdrInfo != nil && !cameraHDR
                        if rasterHDR && state == nil { restoredSettings.hdr=HDRSettings() }
                        context["mode"] = restoredSettings.isHDREditing ? "hdr" : "sdr"
                        stage = "renderPreview"
                        let importContext = context.merging(ErrorDiagnostics.fileContext(localURL)) { first, _ in first }
                        let restoredSettings=restoredSettings
                        let missingLook = !self.isLookAvailable(for: restoredSettings)
                        if let hdr=restoredSettings.hdr,restoredSettings.isHDREditing {
                            let edited=try self.processor.processHDR(url:localURL,settings:hdr.previewSettings(),
                                previewLongEdge:Int(self.previewMaxDimension), processing:restoredSettings.processing)
                            let neutral = hdr.neutralGeometrySettings
                            let original=try self.processor.processHDR(url:localURL,settings:neutral,
                                previewLongEdge:Int(self.previewMaxDimension), processing:restoredSettings.processing)
                            let presentation=try HDRPresentation(edited), reference=try HDRPresentation(original)
                            self.resultDelivery {
                                guard self.activeImportRevision==importRevision else { return }
                                self.invalidatePreviewRequests(); self.activeImportRevision=nil; self.importPreviousRevision=nil
                                self.sourceFile=sourceFile; self.sourceKind=sourceKind; self.sourceIdentity=resolvedIdentity
                                self.sourceDisplayName=source.displayName; self.sourceIsHDR=rasterHDR
                                self.rawHDRSource = cameraHDR ? hdrInfo : nil
                                self.restoredSettings=restoredSettings; self.currentPreviewSettings=restoredSettings; self.pendingSettings=nil
                                self.sourceOrientation = .up; self.draftBuffer=nil; self.draftPreviewBuffer=nil
                                self.hdrPresentation=presentation; self.hdrReference=reference
                                self.previewImage=UIImage(cgImage:presentation.sdrImage); self.basePreviewImage=UIImage(cgImage:reference.sdrImage)
                                self.histogram=nil; self.baseHistogram=nil
                                self.basePreviewGeometry=hdr.geometry; self.basePreviewProcessing=restoredSettings.processing
                                self.rawLUTID=nil; self.rawLUTApplied=false; self.rawWhiteBalance=nil; self.lensInfo=nil
                                self.nativeImageSize=CGSize(width:edited.outputNativeWidth,height:edited.outputNativeHeight)
                                self.hasImage=true; self.isBusy=false; self.sourceRevision=UUID()
                                self.statusMessage = hdr.missingResourceMessage
                                self.recordImportedComparison(settings:restoredSettings)
                                self.acceptImportedEditRecord(record,settings:restoredSettings)
                                self.persistedEditorSettings=nil; self.failedDraftSource=nil
                                if self.editPersistence != nil { self.setEditNotice(state == nil ? .idle : .restored) }
                                ErrorDiagnostics.app.recordImportSuccess(attemptID: importRevision, context: importContext)
                                onSettingsRestored?(restoredSettings); self.importedPhotoRevision = UUID(); onImported?()
                            }
                        } else if sourceKind == .raw {
                            let rawBase = try self.buildRawPreviewBase(url: localURL, geometry: restoredSettings.geometrySettings, processing: restoredSettings.processing, x3fMode: restoredSettings.x3fMode, lens: restoredSettings.lensSettings)
                            let lutURL = self.lutURL(for: restoredSettings)
                            let previewResult = try self.processor.processRaw(
                                url: localURL,
                                settings: restoredSettings,
                                previewLongEdge: self.previewMaxDimension,
                                lutURL: lutURL,
                                viewportPreview: true
                            )
                            let adjustedImage = self.processor.makeUIImage(
                                from: previewResult.buffer,
                                orientation: previewResult.orientation ?? rawBase.orientation
                            )
                            let adjustedHistogram = self.processor.computeRGBHistogram(from: previewResult.buffer)

                            self.resultDelivery {
                                guard self.activeImportRevision == importRevision else { return }
                                self.invalidatePreviewRequests()
                                self.activeImportRevision = nil
                                self.importPreviousRevision=nil
                                self.hdrPresentation=nil; self.hdrReference=nil; self.sourceIsHDR=rasterHDR
                                self.rawHDRSource = cameraHDR ? hdrInfo : nil
                                self.sourceFile = sourceFile
                                self.sourceKind = sourceKind
                                self.sourceIdentity = resolvedIdentity
                                self.sourceDisplayName = source.displayName
                                self.restoredSettings = restoredSettings
                                self.currentPreviewSettings = restoredSettings
                                self.pendingSettings = nil
                                self.sourceOrientation = previewResult.orientation ?? rawBase.orientation
                                self.draftBuffer = rawBase.buffer
                                self.draftPreviewBuffer = rawBase.previewBuffer
                                self.basePreviewImage = rawBase.basePreviewImage
                                self.baseHistogram = rawBase.baseHistogram
                                self.basePreviewGeometry = restoredSettings.geometrySettings
                                self.basePreviewProcessing = restoredSettings.processing
                                self.rawWhiteBalance = previewResult.rawWhiteBalance ?? rawBase.rawWhiteBalance
                                self.lensInfo = previewResult.lensInfo
                                self.rawLUTID = restoredSettings.lutID
                                self.rawLUTApplied = restoredSettings.lutID != nil && restoredSettings.lutStrength > 0
                                self.previewImage = adjustedImage
                                self.nativeImageSize = previewResult.buffer.nativeSize
                                self.histogram = adjustedHistogram
                                self.hasImage = rawBase.basePreviewImage != nil || adjustedImage != nil
                                self.isBusy = false
                                self.sourceRevision = UUID()
                                self.recordImportedComparison(settings: restoredSettings)
                                self.acceptImportedEditRecord(record, settings: restoredSettings)
                                self.persistedEditorSettings = nil
                                self.failedDraftSource = nil
                                if self.editPersistence != nil { self.setEditNotice(state == nil ? .idle : .restored) }
                                onSettingsRestored?(restoredSettings)
                                self.startProcessingMigrationIfNeeded(settings: restoredSettings)
                                if x3fModeOverride != nil { self.queueSettingsSave(restoredSettings) }
                                if self.hasImage && adjustedImage != nil {
                                    ErrorDiagnostics.app.recordImportSuccess(attemptID: importRevision, context: importContext)
                                    self.importedPhotoRevision = UUID()
                                    onImported?()
                                }
                                if missingLook { self.statusMessage = L10n.text("上次使用的外观不可用，请重新选择或导入外观。") }
                                if adjustedImage == nil {
                                    self.reportError(EditorError.renderFailed, operation: .photoImport, stage: "renderPreview",
                                                     attemptID: importRevision, context: importContext, message: L10n.text("无法生成预览"))
                                }
                            }
                        } else {
                            let rasterBase = try self.buildRasterPreviewBase(url: localURL, geometry: restoredSettings.geometrySettings, processing: restoredSettings.processing, lens: restoredSettings.lensSettings)
                            let adjustedBuffer = try self.processor.processBuffer(
                                buffer: rasterBase.buffer,
                                settings: restoredSettings,
                                previewLongEdge: self.previewMaxDimension,
                                lutURL: self.lutURL(for: restoredSettings)
                            )
                            let adjustedImage = self.processor.makeUIImage(
                                from: adjustedBuffer,
                                orientation: rasterBase.orientation
                            )
                            let adjustedHistogram = self.processor.computeRGBHistogram(from: adjustedBuffer)

                            self.resultDelivery {
                                guard self.activeImportRevision == importRevision else { return }
                                self.invalidatePreviewRequests()
                                self.activeImportRevision = nil
                                self.importPreviousRevision=nil
                                self.hdrPresentation=nil; self.hdrReference=nil; self.sourceIsHDR=rasterHDR
                                self.rawHDRSource = cameraHDR ? hdrInfo : nil
                                self.sourceFile = sourceFile
                                self.sourceKind = sourceKind
                                self.sourceIdentity = resolvedIdentity
                                self.sourceDisplayName = source.displayName
                                self.restoredSettings = restoredSettings
                                self.currentPreviewSettings = restoredSettings
                                self.pendingSettings = nil
                                self.sourceOrientation = rasterBase.orientation
                                self.draftBuffer = rasterBase.buffer
                                self.draftPreviewBuffer = rasterBase.previewBuffer
                                self.basePreviewImage = rasterBase.basePreviewImage
                                self.baseHistogram = rasterBase.baseHistogram
                                self.basePreviewGeometry = restoredSettings.geometrySettings
                                self.basePreviewProcessing = restoredSettings.processing
                                self.rawLUTID = nil
                                self.rawLUTApplied = false
                                self.rawWhiteBalance = nil
                                self.lensInfo = adjustedBuffer.lensInfo
                                self.previewImage = adjustedImage
                                self.nativeImageSize = adjustedBuffer.nativeSize
                                self.histogram = adjustedHistogram
                                self.hasImage = rasterBase.basePreviewImage != nil || adjustedImage != nil
                                self.isBusy = false
                                self.sourceRevision = UUID()
                                self.recordImportedComparison(settings: restoredSettings)
                                self.acceptImportedEditRecord(record, settings: restoredSettings)
                                self.persistedEditorSettings = nil
                                self.failedDraftSource = nil
                                if self.editPersistence != nil { self.setEditNotice(state == nil ? .idle : .restored) }
                                onSettingsRestored?(restoredSettings)
                                self.startProcessingMigrationIfNeeded(settings: restoredSettings)
                                if self.hasImage && adjustedImage != nil {
                                    ErrorDiagnostics.app.recordImportSuccess(attemptID: importRevision, context: importContext)
                                    self.importedPhotoRevision = UUID()
                                    onImported?()
                                }
                                if missingLook { self.statusMessage = L10n.text("上次使用的外观不可用，请重新选择或导入外观。") }
                                if adjustedImage == nil {
                                    self.reportError(EditorError.renderFailed, operation: .photoImport, stage: "renderPreview",
                                                     attemptID: importRevision, context: importContext, message: L10n.text("无法生成预览"))
                                }
                            }
                        }
                    }
                } catch {
                    let isUnusableRecord: Bool
                    if error is UnusableEditRecordError {
                        isUnusableRecord = true
                    } else if case HDRSettings.ModeError.invalidSettings = error, context["restoredEdits"] == "true" {
                        isUnusableRecord = true
                    } else {
                        isUnusableRecord = false
                    }
                    if isUnusableRecord, failedSource == nil {
                        failedSource = try? PhotoSourceFile.copy(inputURL)
                    }
                    let failureStage = stage
                    let content = failedSource?.withReadAccess { ErrorDiagnostics.fileContext($0, inspectContent: true) }
                        ?? ErrorDiagnostics.fileContext(inputURL)
                    let failureContext = context.merging(content) { first, _ in first }
                    self.resultDelivery {
                        guard self.activeImportRevision == importRevision else { return }
                        self.invalidatePreviewRequests()
                        self.activeImportRevision = nil
                        let canRecover = isUnusableRecord && importIdentity != nil && failedSource != nil && self.editPersistence != nil
                        let customMessage = canRecover
                            ? "\(error.localizedDescription)\n\n\(L10n.text("恢复当前照片的全部调整，不改写原始照片。"))"
                            : nil
                        let presented = self.reportError(error, operation: .photoImport, stage: failureStage,
                                                         attemptID: importRevision, context: failureContext,
                                                         message: customMessage)
                        self.isBusy = false
                        if let previous=self.importPreviousRevision { self.sourceRevision=previous }
                        self.importPreviousRevision=nil
                        if presented, canRecover, let targetIdentity = importIdentity, let retainedSource = failedSource {
                            self.resetUnusableImportRecord = { [weak self] restored in
                                guard let self else { return }
                                do {
                                    if let session = self.adjustmentSession {
                                        _ = try session.resetToUnmodified(targetIdentity)
                                    } else if let store = self.editPersistence {
                                        _ = try store.resetToUnmodified(targetIdentity)
                                    }
                                    self.adjustmentHistoryRevision = UUID()
                                    let mergedRestore: ((RawSettings) -> Void)? = (onSettingsRestored == nil && restored == nil) ? nil : { restoredSettings in
                                        onSettingsRestored?(restoredSettings)
                                        restored?(restoredSettings)
                                    }
                                    self.importImage(from: source, identity: targetIdentity, settings: settings,
                                        x3fModeOverride: x3fModeOverride, retainedInput: retainedSource,
                                        diagnosticContext: diagnosticContext, onImported: onImported,
                                        onSettingsRestored: mergedRestore)
                                } catch {
                                    _ = self.reportError(error, operation: .editPersistence, stage: "resetUnusableRecord")
                                }
                            }
                        } else if presented, source.isRaw, source.url.pathExtension.lowercased() == "x3f",
                           attemptedX3fMode == .normal, let failedSource {
                            self.retryLegacyX3fImport = { [weak self] restored in
                                self?.importImage(from: source, identity: importIdentity, settings: settings,
                                    x3fModeOverride: .legacy, retainedInput: failedSource, diagnosticContext: diagnosticContext,
                                    onImported: onImported, onSettingsRestored: restored)
                            }
                        }
                    }
                }
            }
        }
        return importRevision
    }

    func cancelImageImport(_ requestID: UUID? = nil) {
        if requestID == nil {
            retryLegacyX3fImport = nil
            resetUnusableImportRecord = nil
        }
        guard let activeImportRevision,
              requestID == nil || requestID == activeImportRevision else { return }
        self.activeImportRevision = nil
        invalidatePreviewRequests()
        sourceRevision = importPreviousRevision ?? UUID()
        importPreviousRevision=nil
        isBusy = false
        if var metadata = editRecordMetadata, let source = editorEditSource,
           metadata.source.file == source.file, metadata.source.identity == source.identity {
            // 取消的是尚未发布的新导入；当前照片及其完整 metadata 仍归旧记录所有。
            metadata.source = source
            editRecordMetadata = metadata
        }
    }
}
