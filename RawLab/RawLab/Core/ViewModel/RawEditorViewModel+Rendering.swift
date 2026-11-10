import CoreGraphics
import Foundation
import UIKit

extension RawEditorViewModel {
    func preflightCameraHDR(settings: RawSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        guard sourceSupportsCameraHDR, settings.isHDREditing, let sourceFile else {
            completion(.failure(HDRRequestError.invalidSettings))
            return
        }
        let sourceRevision = self.sourceRevision
        let previewLongEdge = Int(previewMaxDimension)
        cameraHDRPreflight = true
        isBusy = true
        exportQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error>
            do {
                try sourceFile.withReadAccess { url in
                    _ = try self.processor.processHDR(url: url, settings: settings.hdr!,
                                                      previewLongEdge: previewLongEdge)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.resultDelivery {
                guard self.sourceRevision == sourceRevision else {
                    self.cameraHDRPreflight = false
                    self.isBusy = false
                    return
                }
                self.cameraHDRPreflight = false
                self.isBusy = false
                completion(result)
            }
        }
    }

    var viewportPreviewLimit: Int {
        // Keep the larger working image bounded on iPad, including at extreme zoom.
        if UIDevice.current.userInterfaceIdiom == .pad, sourceKind == .raster, !sourceIsHDR {
            return 4096
        }
        return Int(previewMaxDimension)
    }

    var viewportNativeSize: CGSize? {
        viewportPreviewLimit > Int(previewMaxDimension) ? nativeImageSize : nil
    }

    func updatePreviewSize(_ requestedEdge: Int, settings: RawSettings) {
        let edge = min(viewportPreviewLimit, requestedEdge)
        guard activeImportRevision == nil, hasImage, edge > 0,
              edge != requestedPreviewLongEdge || (edge != previewLongEdge && previewResizeWorkItem == nil) else { return }
        currentPreviewSettings = settings
        requestedPreviewLongEdge = edge
        guard !isBusy else { return }
        previewResizeWorkItem?.cancel()
        previewResizeWorkItem = nil
        previewResizePending = false
        guard requestedPreviewLongEdge != previewLongEdge else { return }
        let sourceRevision = self.sourceRevision
        let commit = DispatchWorkItem { [weak self] in
            guard let self, self.sourceRevision == sourceRevision, self.activeImportRevision == nil else { return }
            self.previewResizePending = false
            self.previewResizeWorkItem = nil
            guard !self.isBusy else { return }
            self.previewLongEdge = self.requestedPreviewLongEdge
            self.updatePreview(settings: self.currentPreviewSettings)
        }
        previewResizeWorkItem = commit
        if edge > Int(previewMaxDimension) || settings.denoise.enabled {
            previewResizePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: commit)
        } else {
            commit.perform()
        }
    }

    func updatePreview(
        settings: RawSettings,
        includeHistogram: Bool = true,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        guard !isBusy else { return }
        currentPreviewSettings = settings
        if !settings.denoise.enabled, previewResizeWorkItem != nil {
            previewResizeWorkItem?.cancel()
            previewResizeWorkItem = nil
            previewResizePending = false
            previewLongEdge = requestedPreviewLongEdge
        }
        let isInteractiveDetail = quality == .interactive && previewLongEdge > Int(previewMaxDimension)
        let maxDimension = isInteractiveDetail ? Int(previewMaxDimension) : previewLongEdge
        let referenceSettings = committedPreviewSettings ?? settings
        let referenceEdge = isInteractiveDetail ? comparisonReferenceKey?.longEdge ?? maxDimension : maxDimension
        let referenceKey = comparisonKey(settings: referenceSettings, longEdge: referenceEdge)
        let comparisonChanged = comparisonReferenceKey != referenceKey
        let request = PreviewRequest(settings: settings, quality: quality,
                                     includeHistogram: includeHistogram, longEdge: maxDimension)
        if request == lastPreviewRequest, !previewRendering, !previewFailed, !comparisonChanged { return }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        let sourceRevision = self.sourceRevision
        let lutURL = lutURL(for: settings)
        let cacheKey = PreviewCacheKey(sourceRevision: sourceRevision, settings: settings,
                                       referenceKey: referenceKey, lut: previewLUTIdentity(for: lutURL),
                                       edge: maxDimension, quality: quality,
                                       includeHistogram: includeHistogram)
        if let previous = completedPreviewCache.last?.key,
           previous.settings != settings || previous.lut != cacheKey.lut {
            completedPreviewCache.removeAll()
            completedPreviewCacheBytes = 0
        }
        guard settings.isHDREditing || isLookAvailable(for: settings) else {
            setLatestRenderID(UUID())
            previewRendering = false
            previewFailed = true
            isBusy = false
            statusMessage = L10n.text("所选外观不可用，请重新选择外观。")
            return
        }

        lastPreviewRequest = request
        previewRendering = true
        previewFailed = false

        let renderID = UUID()
        setLatestRenderID(renderID)
        cancelHistogramWorkItem()

        let finalHistogramDelay = histogramDelay ?? ((includeHistogram && quality == .final) ? self.histogramDelay : 0)
        if let cached = completedPreview(for: cacheKey) {
            applyCachedPreview(cached, request: request, renderID: renderID)
            if let input = cached.histogramInput {
                scheduleHistogramUpdate(for: input, renderID: renderID, sourceRevision: sourceRevision,
                                        delay: finalHistogramDelay, cacheKey: cacheKey)
            }
            return
        }

        let existingDraftBuffer = draftBuffer
        let existingDraftPreview = draftPreviewBuffer
        let existingOrientation = sourceOrientation
        let usesRaw = sourceKind == .raw
        let sourceFile = self.sourceFile
        let previousHDRSettings = acceptedPreviewRequest?.settings
        let existingHDRReference = !comparisonChanged && previousHDRSettings?.hdr?.neutralGeometrySettings == settings.hdr?.neutralGeometrySettings &&
            previousHDRSettings?.proRAWDecodeVersion == settings.proRAWDecodeVersion ? hdrReference : nil
        let diagnosticContext = ["sourceKind": usesRaw ? "raw" : "raster",
                                 "mode": settings.isHDREditing ? "hdr" : "sdr",
                                 "longEdge": String(maxDimension), "quality": String(describing: quality)]

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer {
                self.resultDelivery {
                    if self.sourceRevision == sourceRevision && self.isLatestRenderID(renderID) {
                        self.previewRendering = false
                    }
                }
            }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            if settings.isHDREditing {
                guard let sourceFile,let hdr=settings.hdr else { return }
                sourceFile.withReadAccess { url in
                    do {
                        let cancelled = { !self.isLatestRenderID(renderID) }
                        let edited=try self.processor.processHDR(url:url,settings:hdr.previewSettings(),previewLongEdge:maxDimension,
                            proRAWDecodeVersion:settings.proRAWDecodeVersion,cancelled:cancelled)
                        let neutral = hdr.neutralGeometrySettings
                        let reference = try existingHDRReference ?? HDRPresentation(self.processor.processHDR(
                            url:url,settings:neutral,previewLongEdge:maxDimension,
                            proRAWDecodeVersion:settings.proRAWDecodeVersion,cancelled:cancelled))
                        let presentation=try HDRPresentation(edited)
                        self.resultDelivery {
                            guard self.sourceRevision==sourceRevision,self.isLatestRenderID(renderID) else { return }
                            self.hdrPresentation=presentation; self.hdrReference=reference
                            self.previewImage=UIImage(cgImage:presentation.sdrImage); self.basePreviewImage=UIImage(cgImage:reference.sdrImage)
                            self.histogram=nil; self.baseHistogram=nil
                            self.basePreviewGeometry=hdr.geometry; self.comparisonReferenceKey=referenceKey
                            self.acceptedPreviewRequest=request; self.acceptedPreviewFrameID=renderID; self.previewFailed=false
                            self.statusMessage = hdr.missingResourceMessage
                            self.nativeImageSize=CGSize(width:edited.outputNativeWidth,height:edited.outputNativeHeight)
                            self.cacheCompletedPreview(for: cacheKey)
                        }
                    } catch {
                        self.resultDelivery {
                            guard self.sourceRevision==sourceRevision,self.isLatestRenderID(renderID) else { return }
                            self.previewFailed = true
                            self.reportError(error, operation: .preview, stage: "renderHDR",
                                             attemptID: renderID, context: diagnosticContext)
                        }
                    }
                }
                return
            }

            if usesRaw {
                guard let sourceFile else {
                    self.resultDelivery {
                        guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else { return }
                        self.previewFailed = true
                    }
                    return
                }

                sourceFile.withReadAccess { sourceURL in
                    do {
                        let comparison = comparisonChanged ? try self.renderComparison(
                            url: sourceURL, buffer: nil, geometry: referenceSettings.geometrySettings, processing: referenceSettings.processing,
                            x3fMode: referenceSettings.x3fMode, lens: referenceSettings.lensSettings, longEdge: maxDimension) : nil
                        let result = try self.processor.processRaw(
                            url: sourceURL,
                            settings: settings,
                            previewLongEdge: CGFloat(maxDimension),
                            lutURL: lutURL,
                            interactive: quality == .interactive,
                            viewportPreview: true
                        )
                        let previewImage = self.processor.makeUIImage(
                            from: result.buffer,
                            orientation: result.orientation ?? existingOrientation
                        )

                        self.resultDelivery {
                            guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                                return
                            }
                            self.previewImage = previewImage
                            self.hdrPresentation = nil; self.hdrReference = nil
                            self.acceptedPreviewFrameID = renderID
                            self.acceptedPreviewRequest = request
                            self.histogram = nil
                            self.nativeImageSize = result.buffer.nativeSize
                            if let comparison {
                                self.applyComparison(comparison, geometry: referenceSettings.geometrySettings, processing: referenceSettings.processing,
                                                     lens: referenceSettings.lensSettings, key: referenceKey)
                            }
                            self.lensInfo = result.lensInfo
                            self.rawWhiteBalance = result.rawWhiteBalance
                            if self.sourceOrientation == nil {
                                self.sourceOrientation = result.orientation
                            }
                            self.cacheCompletedPreview(for: cacheKey, histogramInput: includeHistogram ? result.buffer : nil)
                        }

                        if includeHistogram {
                            self.scheduleHistogramUpdate(
                                for: result.buffer,
                                renderID: renderID,
                                sourceRevision: sourceRevision,
                                delay: finalHistogramDelay,
                                cacheKey: cacheKey
                            )
                        }
                    } catch {
                        self.resultDelivery {
                            guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                                return
                            }
                            self.previewFailed = true
                            self.reportError(error, operation: .preview, stage: "renderRAW",
                                             attemptID: renderID, context: diagnosticContext)
                        }
                    }
                }
                return
            }

            var inputBuffer = existingDraftBuffer ?? existingDraftPreview
            if let existing=inputBuffer,existing.isProxy,let native=existing.nativeSize,
               max(existing.width,existing.height)<min(maxDimension,Int(max(native.width,native.height))) {
                inputBuffer=nil
            }
            if inputBuffer==nil,let sourceFile {
                do { inputBuffer=try sourceFile.withReadAccess {
                    try self.processor.loadRasterBuffer(url:$0,previewLongEdge:maxDimension).buffer
                } }
                catch {
                    self.resultDelivery {
                        guard self.sourceRevision==sourceRevision,self.isLatestRenderID(renderID) else { return }
                        self.previewFailed = true
                        self.reportError(error, operation: .preview, stage: "decodeRaster",
                                         attemptID: renderID, context: diagnosticContext)
                    }
                    return
                }
            }
            guard let inputBuffer else {
                self.resultDelivery {
                    guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else { return }
                    self.previewFailed = true
                }
                return
            }

            let outputBuffer: Sony2FujiProcessor.Buffer
            let comparison: (UIImage?, Sony2FujiProcessor.RGBHistogram?)?
            do {
                comparison = comparisonChanged ? try self.renderComparison(
                    url: nil, buffer: inputBuffer, geometry: referenceSettings.geometrySettings, processing: referenceSettings.processing,
                            x3fMode: referenceSettings.x3fMode, lens: referenceSettings.lensSettings, longEdge: referenceEdge) : nil
                outputBuffer = try self.processor.processBuffer(
                    buffer: inputBuffer,
                    settings: settings,
                    previewLongEdge: CGFloat(maxDimension),
                    lutURL: lutURL,
                    interactive: quality == .interactive,
                    viewportPreview: true
                )
            } catch {
                self.resultDelivery {
                    guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                        return
                    }
                    self.previewFailed = true
                    self.reportError(error, operation: .preview, stage: "renderRaster",
                                     attemptID: renderID, context: diagnosticContext)
                }
                return
            }

            let previewImage = self.processor.makeUIImage(from: outputBuffer, orientation: .up)

            self.resultDelivery {
                guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID) else {
                    return
                }
                self.previewImage = previewImage
                self.hdrPresentation=nil; self.hdrReference=nil; self.draftBuffer=inputBuffer
                self.acceptedPreviewFrameID = renderID
                self.acceptedPreviewRequest = request
                self.histogram = nil
                self.nativeImageSize = outputBuffer.nativeSize
                if let comparison {
                    self.applyComparison(comparison, geometry: referenceSettings.geometrySettings, processing: referenceSettings.processing,
                                         lens: referenceSettings.lensSettings, key: referenceKey)
                }
                self.lensInfo = outputBuffer.lensInfo
                self.cacheCompletedPreview(for: cacheKey, histogramInput: includeHistogram ? outputBuffer : nil)
            }

            if includeHistogram {
                self.scheduleHistogramUpdate(
                    for: outputBuffer,
                    renderID: renderID,
                    sourceRevision: sourceRevision,
                    delay: finalHistogramDelay,
                    cacheKey: cacheKey
                )
            }
        }
        previewWorkItem = workItem
        renderQueue.async(execute: workItem)
    }

    func previewLUTIdentity(for url: URL?) -> PreviewLUTFileIdentity? {
        guard let url else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return PreviewLUTFileIdentity(
            url: url.standardizedFileURL,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    func completedPreview(for key: PreviewCacheKey) -> CompletedPreview? {
        guard let index = completedPreviewCache.firstIndex(where: { $0.key == key }) else { return nil }
        let cached = completedPreviewCache.remove(at: index)
        completedPreviewCache.append(cached)
        return cached
    }

    func applyCachedPreview(_ cached: CompletedPreview, request: PreviewRequest, renderID: UUID) {
        previewImage = cached.previewImage
        basePreviewImage = cached.basePreviewImage
        hdrPresentation = cached.hdrPresentation
        hdrReference = cached.hdrReference
        histogram = request.includeHistogram ? cached.histogram : nil
        baseHistogram = cached.baseHistogram
        nativeImageSize = cached.nativeImageSize
        basePreviewGeometry = cached.basePreviewGeometry
        basePreviewProcessing = cached.basePreviewProcessing
        basePreviewLens = cached.basePreviewLens
        comparisonReferenceKey = cached.comparisonReferenceKey
        rawWhiteBalance = cached.rawWhiteBalance
        lensInfo = cached.lensInfo
        if sourceOrientation == nil { sourceOrientation = cached.sourceOrientation }
        acceptedPreviewRequest = request
        acceptedPreviewFrameID = renderID
        previewFailed = false
        previewRendering = false
    }

    func cacheCompletedPreview(for key: PreviewCacheKey, histogramInput: Sony2FujiProcessor.Buffer? = nil) {
        guard key.quality == .final, previewImage != nil, comparisonReferenceKey == key.referenceKey,
              !key.settings.isHDREditing || key.settings.hdr?.missingResourceMessage == nil else { return }
        let entry = CompletedPreview(
            key: key,
            previewImage: previewImage,
            basePreviewImage: basePreviewImage,
            histogram: key.includeHistogram ? histogram : nil,
            histogramInput: histogramInput,
            baseHistogram: baseHistogram,
            nativeImageSize: nativeImageSize,
            hdrPresentation: hdrPresentation,
            hdrReference: hdrReference,
            basePreviewGeometry: basePreviewGeometry,
            basePreviewProcessing: basePreviewProcessing,
            basePreviewLens: basePreviewLens,
            comparisonReferenceKey: comparisonReferenceKey,
            rawWhiteBalance: rawWhiteBalance,
            lensInfo: lensInfo,
            sourceOrientation: sourceOrientation
        )
        let entryBytes = entry.estimatedMemoryBytes
        let budget = key.settings.isHDREditing ? 128 * 1024 * 1024 : 64 * 1024 * 1024
        guard entryBytes <= budget else { return }
        if let existingIndex = completedPreviewCache.firstIndex(where: { $0.key == key }) {
            completedPreviewCacheBytes -= completedPreviewCache[existingIndex].estimatedMemoryBytes
            completedPreviewCache.remove(at: existingIndex)
        }
        while completedPreviewCacheBytes + entryBytes > budget,
              !completedPreviewCache.isEmpty {
            completedPreviewCacheBytes -= completedPreviewCache.removeFirst().estimatedMemoryBytes
        }
        completedPreviewCache.append(entry)
        completedPreviewCacheBytes += entryBytes
        while completedPreviewCache.count > completedPreviewCacheLimit {
            completedPreviewCacheBytes -= completedPreviewCache.removeFirst().estimatedMemoryBytes
        }
    }

    func updateCachedPreviewHistogram(_ histogram: Sony2FujiProcessor.RGBHistogram?,
                                      for key: PreviewCacheKey) {
        guard let index = completedPreviewCache.firstIndex(where: { $0.key == key }) else { return }
        completedPreviewCache[index].histogram = histogram
        completedPreviewCache[index].histogramInput = nil
    }

    func renderComparison(url: URL?, buffer: Sony2FujiProcessor.Buffer?,
                          geometry: GeometrySettings, processing: ProcessingIdentity,
                          x3fMode: X3fMode = .normal, lens: LensCorrectionSettings = LensCorrectionSettings(), longEdge: Int? = nil) throws -> (UIImage?, Sony2FujiProcessor.RGBHistogram?) {
        var neutral = RawSettings.default
        neutral.geometry = geometry
        neutral.processing = processing
        neutral.x3fMode = x3fMode
        neutral.lensCorrection = lens
        let output: Sony2FujiProcessor.Buffer
        if let url {
            output = try processor.processRaw(url: url, settings: neutral,
                previewLongEdge: CGFloat(longEdge ?? Int(previewMaxDimension)), lutURL: nil, viewportPreview: true).buffer
        } else if let buffer {
            output = try processor.processBuffer(buffer: buffer, settings: neutral,
                previewLongEdge: CGFloat(longEdge ?? Int(previewMaxDimension)), lutURL: nil, viewportPreview: true)
        } else { throw EditorError.noImageLoaded }
        return (processor.makeUIImage(from: output, orientation: .up),
                processor.computeRGBHistogram(from: output))
    }

    func applyComparison(_ comparison: (UIImage?, Sony2FujiProcessor.RGBHistogram?), geometry: GeometrySettings, processing: ProcessingIdentity,
                         lens: LensCorrectionSettings = LensCorrectionSettings(), key: ComparisonReferenceKey? = nil) {
        basePreviewImage = comparison.0
        baseHistogram = comparison.1
        basePreviewGeometry = geometry
        basePreviewProcessing = processing
        basePreviewLens = lens
        comparisonReferenceKey = key
    }

    func comparisonKey(settings: RawSettings, longEdge: Int) -> ComparisonReferenceKey {
        ComparisonReferenceKey(sourceRevision: sourceRevision, file: sourceFile, identity: sourceIdentity,
                               kind: sourceKind, processing: settings.processing, x3fMode: settings.x3fMode, geometry: settings.geometrySettings,
                               lens: settings.lensSettings, longEdge: longEdge,hdrMode:settings.hdr?.mode,
                               hdrCamera: settings.isHDREditing ? settings.hdr?.neutralGeometrySettings.cameraDevelopmentSettings : nil)
    }

    func retryPreview(settings: RawSettings) {
        guard !isBusy, !previewRendering, !previewResizePending else { return }
        lastPreviewRequest = nil
        updatePreview(settings: settings)
    }

    func recordImportedComparison(settings: RawSettings) {
        committedPreviewSettings = settings
        basePreviewLens = settings.lensSettings
        let edge = Int(previewMaxDimension)
        let reference = comparisonKey(settings: settings, longEdge: edge)
        comparisonReferenceKey = reference
        acceptedPreviewFrameID = UUID()
        acceptedPreviewRequest = PreviewRequest(settings: settings, quality: .final, includeHistogram: true, longEdge: edge)
        previewFailed = false
        cacheCompletedPreview(for: PreviewCacheKey(sourceRevision: sourceRevision, settings: settings,
            referenceKey: reference, lut: previewLUTIdentity(for: lutURL(for: settings)),
            edge: edge, quality: .final, includeHistogram: true))
    }

    func schedulePreviewUpdate(
        settings: RawSettings,
        delay: TimeInterval,
        includeHistogram: Bool,
        quality: PreviewQuality = .final,
        histogramDelay: TimeInterval? = nil
    ) {
        guard !isBusy else { return }
        currentPreviewSettings = settings
        previewWorkItem?.cancel()
        setLatestRenderID(UUID())
        previewRendering = true

        let sourceRevision = self.sourceRevision
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.sourceRevision == sourceRevision, !self.isBusy else { return }
            self.updatePreview(
                settings: settings,
                includeHistogram: includeHistogram,
                quality: quality,
                histogramDelay: histogramDelay
            )
        }
        previewWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }
}

extension RawEditorViewModel {
    func invalidatePreviewRequests() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        previewResizeWorkItem?.cancel()
        previewResizeWorkItem = nil
        previewResizePending = false
        cancelHistogramWorkItem()
        setLatestRenderID(UUID())
        lastPreviewRequest = nil
        previewRendering = false
        previewFailed = false
        comparisonReferenceKey = nil
        acceptedPreviewFrameID = nil
        acceptedPreviewRequest = nil
        completedPreviewCache.removeAll()
        completedPreviewCacheBytes = 0
    }

    func setLatestRenderID(_ renderID: UUID) {
        renderStateLock.lock()
        latestRenderID = renderID
        renderStateLock.unlock()
    }

    func isLatestRenderID(_ renderID: UUID) -> Bool {
        renderStateLock.lock()
        let isLatest = latestRenderID == renderID
        renderStateLock.unlock()
        return isLatest
    }

    func cancelHistogramWorkItem() {
        renderStateLock.lock()
        histogramWorkItem?.cancel()
        histogramWorkItem = nil
        renderStateLock.unlock()
    }

    func setHistogramWorkItem(_ workItem: DispatchWorkItem, renderID: UUID) -> Bool {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        guard latestRenderID == renderID else { return false }
        histogramWorkItem?.cancel()
        histogramWorkItem = workItem
        return true
    }

    func scheduleHistogramUpdate(
        for buffer: Sony2FujiProcessor.Buffer,
        renderID: UUID,
        sourceRevision: UUID,
        delay: TimeInterval,
        cacheKey: PreviewCacheKey
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isLatestRenderID(renderID) else {
                return
            }

            let histogram = self.processor.computeRGBHistogram(from: buffer)
            self.resultDelivery {
                guard self.sourceRevision == sourceRevision, self.isLatestRenderID(renderID),
                      self.acceptedPreviewFrameID == renderID else {
                    return
                }
                self.histogram = histogram
                self.updateCachedPreviewHistogram(histogram, for: cacheKey)
            }
        }

        guard setHistogramWorkItem(workItem, renderID: renderID) else { return }

        if delay > 0 {
            renderQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            renderQueue.async(execute: workItem)
        }
    }
}
