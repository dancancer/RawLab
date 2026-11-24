import RawLabKit
import CoreGraphics
import Foundation
import UIKit

extension RawEditorViewModel {
    func preflightCameraHDR(settings: RawSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        guard sourceSupportsCameraHDR, settings.isHDREditing, let sourceFile else {
            completion(.failure(HDRNativeError.invalidSettings))
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
                        previewLongEdge: previewLongEdge, processing: settings.processing)
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
        if let size = nativeImageSize, size.width > 0, size.height > 0 {
            return size
        }
        return viewportPreviewSourceSize
    }

    var viewportPreviewSourceSize: CGSize? {
        guard let image = hdrPresentation?.image else { return nil }
        // HDR 的长边请求缩放整张源图，按交付帧的旋转方向计算 Fit。
        let source = CGSize(width: image.nativeWidth, height: image.nativeHeight)
        return basePreviewGeometry.quarterTurns.isMultiple(of: 2)
            ? source : CGSize(width: source.height, height: source.width)
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
            self.onViewportResize?(true)
            defer { self.onViewportResize?(false) }
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
            // V-UIIOS P1-05：SDR 帧未出即早退，上一帧的缺资源警告必须经统一入口退役，
            // 否则同图切回 HDR 时相同警告被 change() 的 `.keep` 吞掉（docs/archive/architecture/remediation-plan-2026-11-13/b-task-table.md:17）。
            hdrResourceNotice = hdrResourceNotice.afterUndeliveredFrame
            statusMessage = L10n.text("所选外观不可用，请重新选择外观。")
            return
        }

        onPreviewRequest?(request, sourceRevision)
        lastPreviewRequest = request
        clearDetailState(releaseRaster: false, keepRequest: true)
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
                        if quality == .final, !self.previewFailed,
                           self.acceptedPreviewFrameID == renderID {
                            self.triggerDetailPrewarmIfEligible()
                            if let detailRequest = self.lastDetailRequest {
                                self.updateDetailRequest(detailRequest)
                            }
                        }
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
                            processing:settings.processing,proRAWDecodeVersion:settings.proRAWDecodeVersion,cancelled:cancelled)
                        let neutral = hdr.neutralGeometrySettings
                        let reference = try existingHDRReference ?? HDRPresentation(self.processor.processHDR(
                            url:url,settings:neutral,previewLongEdge:maxDimension,
                            processing:settings.processing,proRAWDecodeVersion:settings.proRAWDecodeVersion,cancelled:cancelled))
                        let presentation=try HDRPresentation(edited)
                        self.resultDelivery {
                            guard self.sourceRevision==sourceRevision,self.isLatestRenderID(renderID) else { return }
                            self.hdrPresentation=presentation; self.hdrReference=reference
                            self.previewImage=UIImage(cgImage:presentation.sdrImage); self.basePreviewImage=UIImage(cgImage:reference.sdrImage)
                            self.histogram=nil; self.baseHistogram=nil
                            self.basePreviewGeometry=hdr.geometry; self.comparisonReferenceKey=referenceKey
                            self.acceptedPreviewRequest=request; self.acceptedPreviewFrameID=renderID; self.previewFailed=false
                            self.updateHDRResourceNotice(hdr.missingResourceMessage)
                            self.nativeImageSize=CGSize(width:edited.outputNativeWidth,height:edited.outputNativeHeight)
                            if settings.geometrySettings.isIdentity {
                                self.sourceNativeSize = self.nativeImageSize
                            }
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
                            self.updateHDRResourceNotice(nil)
                            self.acceptedPreviewFrameID = renderID
                            self.acceptedPreviewRequest = request
                            self.histogram = nil
                            self.nativeImageSize = result.buffer.nativeSize
                            if settings.geometrySettings.isIdentity {
                                self.sourceNativeSize = result.buffer.nativeSize
                            }
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
                            self.hdrResourceNotice = self.hdrResourceNotice.afterUndeliveredFrame
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
                        self.hdrResourceNotice = self.hdrResourceNotice.afterUndeliveredFrame
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
                    self.hdrResourceNotice = self.hdrResourceNotice.afterUndeliveredFrame
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
                self.updateHDRResourceNotice(nil)
                self.acceptedPreviewFrameID = renderID
                self.acceptedPreviewRequest = request
                self.histogram = nil
                self.nativeImageSize = outputBuffer.nativeSize
                if settings.geometrySettings.isIdentity {
                    self.sourceNativeSize = outputBuffer.nativeSize
                }
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

    func updateHDRResourceNotice(_ message: String?) {
        switch hdrResourceNotice.change(to: message, status: statusMessage) {
        case .show(let message): statusMessage = message
        case .clear: statusMessage = nil
        case .keep: break
        }
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
        if !request.settings.isHDREditing { updateHDRResourceNotice(nil) }
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
        if request.quality == .final {
            triggerDetailPrewarmIfEligible()
            if let detailRequest = lastDetailRequest {
                updateDetailRequest(detailRequest)
            }
        }
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
        let frameID = UUID()
        setLatestRenderID(frameID)
        acceptedPreviewFrameID = frameID
        acceptedPreviewRequest = PreviewRequest(settings: settings, quality: .final, includeHistogram: true, longEdge: edge)
        previewFailed = false
        cacheCompletedPreview(for: PreviewCacheKey(sourceRevision: sourceRevision, settings: settings,
            referenceKey: reference, lut: previewLUTIdentity(for: lutURL(for: settings)),
            edge: edge, quality: .final, includeHistogram: true))
        triggerDetailPrewarmIfEligible()
        if let detailRequest = lastDetailRequest {
            updateDetailRequest(detailRequest)
        }
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
        clearDetailState(releaseRaster: false, keepRequest: true)
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
        clearDetailState(releaseRaster: false, keepRequest: true)
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

    func setLatestDetailToken(_ token: UUID) {
        renderStateLock.lock()
        detailRenderToken = token
        renderStateLock.unlock()
    }

    func isLatestDetailToken(_ token: UUID) -> Bool {
        renderStateLock.lock()
        let isLatest = detailRenderToken == token
        renderStateLock.unlock()
        return isLatest
    }

    private func isTileStillDesired(_ key: PhotoDetailTileKey) -> Bool {
        renderStateLock.lock()
        let desired = desiredDetailKeys.contains(key)
        renderStateLock.unlock()
        return desired
    }

    private func hasPendingLiveDetailSpecs() -> Bool {
        renderStateLock.lock()
        let hasLive = !desiredDetailSpecs.isEmpty
        renderStateLock.unlock()
        return hasLive
    }

    private func detailTileBytes(_ overlay: PhotoDetailOverlay) -> Int {
        var bytes = overlay.cgImage.map { $0.width * $0.height * 4 } ?? 0
        if let before = overlay.beforeCGImage, before !== overlay.cgImage {
            bytes += before.width * before.height * 4
        }
        return bytes
    }

    private func sortedTiles(_ tiles: [PhotoDetailOverlay]) -> [PhotoDetailOverlay] {
        tiles.sorted { a, b in
            let la = a.tileKey?.level ?? 0
            let lb = b.tileKey?.level ?? 0
            if la != lb { return la > lb }
            let ra = a.tileKey?.row ?? 0
            let rb = b.tileKey?.row ?? 0
            if ra != rb { return ra < rb }
            return (a.tileKey?.col ?? 0) < (b.tileKey?.col ?? 0)
        }
    }

    private func tileSpecs(for request: PhotoDetailRequest?) -> (visible: [PhotoDetailTileSpec], all: [PhotoDetailTileSpec]) {
        guard let request, let native = viewportNativeSize, native.width > 0, native.height > 0 else {
            return ([], [])
        }
        let visible = PhotoDetailTilePlan.tiles(
            visibleRect: request.visibleRect,
            fullNativeSize: native,
            zoomScale: request.zoomScale,
            baseScale: request.baseScale,
            overscanRing: 0
        )
        let all = PhotoDetailTilePlan.tiles(
            visibleRect: request.visibleRect,
            fullNativeSize: native,
            zoomScale: request.zoomScale,
            baseScale: request.baseScale,
            overscanRing: 1
        )
        return (visible, all)
    }

    private func activeDetailTiles(
        for specs: [PhotoDetailTileSpec],
        visibleSpecs: [PhotoDetailTileSpec]
    ) -> [PhotoDetailOverlay] {
        var selected: [PhotoDetailTileKey: PhotoDetailOverlay] = [:]
        for spec in specs {
            if let tile = detailTileCache[spec.key] {
                selected[spec.key] = tile
            }
        }
        let uncachedVisible = visibleSpecs.filter { selected[$0.key] == nil }
        if !uncachedVisible.isEmpty {
            let targetLevel = visibleSpecs.first?.key.level ?? 0
            for (key, tile) in detailTileCache where key.level > targetLevel && selected[key] == nil {
                if uncachedVisible.contains(where: { $0.normalizedRect.intersects(tile.normalizedRect) }) {
                    selected[key] = tile
                }
            }
        }
        return sortedTiles(Array(selected.values))
    }

    private func detailTileListMatches(_ lhs: [PhotoDetailOverlay], _ rhs: [PhotoDetailOverlay]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.renderID != b.renderID ||
               a.tileKey != b.tileKey ||
               a.cgImage !== b.cgImage ||
               a.beforeCGImage !== b.beforeCGImage {
                return false
            }
        }
        return true
    }

    private func touchDetailTileKeys(_ keys: [PhotoDetailTileKey]) {
        for key in keys where detailTileCache[key] != nil {
            if let idx = detailTileLRU.firstIndex(of: key) {
                detailTileLRU.remove(at: idx)
            }
            detailTileLRU.append(key)
        }
    }

    private func storeDetailTile(_ overlay: PhotoDetailOverlay, keepKeys: Set<PhotoDetailTileKey>) {
        if detailTileFrameID != overlay.renderID {
            detailTileCache.removeAll()
            detailTileLRU.removeAll()
            detailTileCacheBytes = 0
            detailTileFrameID = overlay.renderID
            renderStateLock.lock()
            cachedDetailTileBeforeLocked.removeAll()
            detailTileAfterLocked.removeAll()
            pendingDetailDeliveryKeys.removeAll()
            renderStateLock.unlock()
        }
        guard let key = overlay.tileKey else { return }
        if let old = detailTileCache.removeValue(forKey: key) {
            detailTileCacheBytes = max(0, detailTileCacheBytes - detailTileBytes(old))
        }
        if let idx = detailTileLRU.firstIndex(of: key) {
            detailTileLRU.remove(at: idx)
        }
        detailTileCache[key] = overlay
        detailTileLRU.append(key)
        detailTileCacheBytes += detailTileBytes(overlay)
        var evictedKeys: [PhotoDetailTileKey] = []

        while detailTileCacheBytes > detailTileByteBudget || detailTileCache.count > detailTileMaxCount {
            let victimIdx = detailTileLRU.firstIndex(where: { !keepKeys.contains($0) }) ?? 0
            let victim = detailTileLRU.remove(at: victimIdx)
            if let removed = detailTileCache.removeValue(forKey: victim) {
                detailTileCacheBytes = max(0, detailTileCacheBytes - detailTileBytes(removed))
                evictedKeys.append(victim)
            }
        }

        renderStateLock.lock()
        for evicted in evictedKeys {
            cachedDetailTileBeforeLocked.removeValue(forKey: evicted)
            detailTileAfterLocked.removeValue(forKey: evicted)
        }
        cachedDetailTileBeforeLocked[key] = (overlay.beforeCGImage != nil)
        detailTileAfterLocked[key] = overlay
        renderStateLock.unlock()
    }

    private func storeHDRDetail(_ overlay: PhotoDetailOverlay) {
        hdrDetailCache.removeAll { $0.renderID != overlay.renderID }
        hdrDetailCache.removeAll {
            $0.normalizedRect == overlay.normalizedRect && $0.pixelSize == overlay.pixelSize
        }
        hdrDetailCache.append(overlay)
        while hdrDetailCache.count > hdrDetailMaxCount {
            hdrDetailCache.removeFirst()
        }
    }

    func clearDetailState(releaseRaster: Bool = false, keepRequest: Bool = false) {
        detailDebounceWorkItem?.cancel()
        detailDebounceWorkItem = nil
        detailOverlay = nil
        if !detailTiles.isEmpty {
            detailTiles = []
        }
        if detailBacking != nil {
            detailBacking = nil
        }
        detailTileCache.removeAll()
        detailTileLRU.removeAll()
        detailTileCacheBytes = 0
        detailTileFrameID = nil
        hdrDetailCache.removeAll()
        renderStateLock.lock()
        detailRenderToken = UUID()
        desiredDetailSpecs.removeAll()
        desiredDetailKeys.removeAll()
        desiredDetailVisibleKeys.removeAll()
        desiredDetailRequiredKeys.removeAll()
        inFlightDetailTileKey = nil
        detailWorkerActive = false
        detailWorkerFrameID = nil
        detailBackingRenderedFrameID = nil
        detailPrewarmScheduledFrameID = nil
        detailMetalFullResFailedFrameID = nil
        detailPrewarmPending = false
        detailBeforeBackingPending = false
        cachedDetailTileBeforeLocked.removeAll()
        detailTileAfterLocked.removeAll()
        pendingDetailDeliveryKeys.removeAll()
        renderStateLock.unlock()
        if !keepRequest {
            lastDetailRequest = nil
        }
        if releaseRaster {
            fullRasterROIBuffer = nil
        }
    }

    func setDetailNeedsBefore(_ needed: Bool) {
        guard detailNeedsBefore != needed else { return }
        detailNeedsBefore = needed
        var needsWorkerKick = false
        renderStateLock.lock()
        detailNeedsBeforeLocked = needed
        if needed,
           detailBacking != nil,
           detailBacking?.beforeCGImage == nil,
           basePreviewImage != nil,
           !currentPreviewSettings.isHDREditing {
            detailBeforeBackingPending = true
            needsWorkerKick = true
        }
        renderStateLock.unlock()
        if needed, !currentPreviewSettings.isHDREditing {
            if let req = lastDetailRequest {
                updateDetailRequest(req)
            }
            if needsWorkerKick, let frameID = acceptedPreviewFrameID {
                ensureDetailWorkerRunning(for: frameID)
            }
        }
    }

    func triggerDetailPrewarmIfEligible() {
        guard detailPrewarmEnabled,
              !isBusy, !previewRendering, !previewResizePending,
              !currentPreviewSettings.isHDREditing,
              acceptedPreviewRequest?.quality == .final,
              let frameID = acceptedPreviewFrameID,
              let native = viewportNativeSize,
              Int(max(native.width, native.height).rounded()) > previewLongEdge else {
            return
        }
        renderStateLock.lock()
        if detailPrewarmScheduledFrameID == frameID {
            renderStateLock.unlock()
            return
        }
        detailPrewarmScheduledFrameID = frameID
        detailPrewarmPending = true
        renderStateLock.unlock()
        ensureDetailWorkerRunning(for: frameID)
    }

    func updateDetailRequest(_ request: PhotoDetailRequest?) {
        guard let request else {
            detailDebounceWorkItem?.cancel()
            detailDebounceWorkItem = nil
            lastDetailRequest = nil
            renderStateLock.lock()
            desiredDetailSpecs.removeAll()
            desiredDetailKeys.removeAll()
            desiredDetailVisibleKeys.removeAll()
            desiredDetailRequiredKeys.removeAll()
            renderStateLock.unlock()
            if detailOverlay != nil { detailOverlay = nil }
            if !detailTiles.isEmpty { detailTiles = [] }
            return
        }
        lastDetailRequest = request
        if !currentPreviewSettings.isHDREditing, let frameID = acceptedPreviewFrameID {
            if detailTileFrameID != frameID {
                detailTileCache.removeAll()
                detailTileLRU.removeAll()
                detailTileCacheBytes = 0
                detailTileFrameID = frameID
                renderStateLock.lock()
                cachedDetailTileBeforeLocked.removeAll()
                detailTileAfterLocked.removeAll()
                pendingDetailDeliveryKeys.removeAll()
                renderStateLock.unlock()
            }
            if let native = viewportNativeSize, native.width > 0, native.height > 0 {
                guard PhotoDetailTilePlan.level(forZoomScale: request.zoomScale, baseScale: request.baseScale) != nil else {
                    detailDebounceWorkItem?.cancel()
                    detailDebounceWorkItem = nil
                    renderStateLock.lock()
                    desiredDetailSpecs.removeAll()
                    desiredDetailKeys.removeAll()
                    desiredDetailVisibleKeys.removeAll()
                    desiredDetailRequiredKeys.removeAll()
                    renderStateLock.unlock()
                    return
                }
                let (visibleSpecs, allSpecs) = tileSpecs(for: request)
                let hitKeys = allSpecs.map(\.key).filter { detailTileCache[$0] != nil }
                if !hitKeys.isEmpty {
                    touchDetailTileKeys(hitKeys)
                }
                let active = activeDetailTiles(for: allSpecs, visibleSpecs: visibleSpecs)
                if !detailTileListMatches(detailTiles, active) {
                    detailTiles = active
                    detailOverlay = active.last
                }
                let needsBefore = detailNeedsBefore && basePreviewImage != nil
                let missing = allSpecs.filter { spec in
                    guard let existing = detailTileCache[spec.key] else { return true }
                    return needsBefore && existing.beforeCGImage == nil
                }
                let visibleKeys = Set(visibleSpecs.map(\.key))
                let allKeys = Set(allSpecs.map(\.key))

                detailDebounceWorkItem?.cancel()
                detailDebounceWorkItem = nil
                renderStateLock.lock()
                desiredDetailSpecs = missing
                desiredDetailKeys = Set(missing.map(\.key))
                desiredDetailVisibleKeys = visibleKeys
                desiredDetailRequiredKeys = allKeys
                let workerRunning = detailWorkerActive && detailWorkerFrameID == frameID
                let inFlightKey = inFlightDetailTileKey
                renderStateLock.unlock()

                if !missing.isEmpty && (!workerRunning || (inFlightKey != nil && !visibleKeys.isEmpty && !allKeys.contains(inFlightKey!))) {
                    ensureDetailWorkerRunning(for: frameID)
                }
                return
            }
        }
        if let frameID = acceptedPreviewFrameID {
            hdrDetailCache.removeAll { $0.renderID != frameID }
            if let hitIdx = hdrDetailCache.lastIndex(where: {
                $0.renderID == frameID &&
                $0.covers(
                    visibleRect: request.visibleRect,
                    requiredZoomScale: request.zoomScale,
                    maxOutputLongEdge: settingsHDRDetailLimit(request)
                )
            }) {
                let hit = hdrDetailCache.remove(at: hitIdx)
                hdrDetailCache.append(hit)
                detailDebounceWorkItem?.cancel()
                detailDebounceWorkItem = nil
                setLatestDetailToken(UUID())
                if !detailTiles.isEmpty { detailTiles = [] }
                if detailOverlay?.renderID != hit.renderID ||
                   detailOverlay?.normalizedRect != hit.normalizedRect ||
                   detailOverlay?.pixelSize != hit.pixelSize {
                    detailOverlay = hit
                }
                return
            }
        }
        scheduleDetailRender(for: request)
    }

    private func settingsHDRDetailLimit(_ request: PhotoDetailRequest) -> Int {
        currentPreviewSettings.isHDREditing ? min(1280, request.maxOutputLongEdge) : min(2048, request.maxOutputLongEdge)
    }

    private func makeNeutralSettings(from referenceSettings: RawSettings) -> RawSettings {
        var neutral = RawSettings.default
        neutral.geometry = referenceSettings.geometrySettings
        neutral.processing = referenceSettings.processing
        neutral.x3fMode = referenceSettings.x3fMode
        neutral.lensCorrection = referenceSettings.lensSettings
        return neutral
    }

    private func canReuseAfterAsBefore(
        settings: RawSettings,
        neutral: RawSettings,
        sourceKind: ImageSourceKind,
        lutURL: URL?
    ) -> Bool {
        guard lutURL == nil else { return false }
        var lhs = settings
        var rhs = neutral
        lhs.lensCorrection = lhs.lensSettings
        rhs.lensCorrection = rhs.lensSettings
        lhs.toneCurveConfig = lhs.curveSettings
        rhs.toneCurveConfig = rhs.curveSettings
        lhs.colorGrading = lhs.gradingSettings
        rhs.colorGrading = rhs.gradingSettings
        lhs.atmosphere = lhs.atmosphereSettings
        rhs.atmosphere = rhs.atmosphereSettings
        lhs.toneControls = lhs.toneSettings
        rhs.toneControls = rhs.toneSettings
        if sourceKind != .raw {
            lhs.exposureMode = .sensor
            rhs.exposureMode = .sensor
            lhs.whiteBalanceMode = .camera
            rhs.whiteBalanceMode = .camera
            lhs.temperature = 6500
            rhs.temperature = 6500
            lhs.tint = 0
            rhs.tint = 0
        } else if lhs.masterRecipeID == nil && lhs.whiteBalanceMode == .camera && rhs.whiteBalanceMode == .camera {
            lhs.temperature = 6500
            rhs.temperature = 6500
            lhs.tint = 0
            rhs.tint = 0
        }
        return lhs == rhs
    }

    private func resolveRasterROISourceBuffer(
        sourceFile: PhotoSourceFile,
        expectedSourceRevision: UUID,
        draftBuffer: Sony2FujiProcessor.Buffer?,
        cachedFullRaster: inout Sony2FujiProcessor.Buffer?
    ) throws -> Sony2FujiProcessor.Buffer {
        if let existing = cachedFullRaster, !existing.isProxy {
            return existing
        }
        if let draft = draftBuffer, !draft.isProxy {
            return draft
        }
        let loaded = try sourceFile.withReadAccess { url in
            try self.processor.loadRasterBuffer(url: url, applyingOrientation: true, previewLongEdge: nil).buffer
        }
        cachedFullRaster = loaded
        self.resultDelivery {
            guard self.sourceRevision == expectedSourceRevision else { return }
            self.fullRasterROIBuffer = loaded
        }
        return loaded
    }

    private func renderSDRDetailTile(
        sourceFile: PhotoSourceFile,
        sourceKind: ImageSourceKind,
        expectedSourceRevision: UUID,
        expectedFrameID: UUID,
        settings: RawSettings,
        referenceSettings: RawSettings,
        lutURL: URL?,
        draftBuffer: Sony2FujiProcessor.Buffer?,
        cachedFullRaster: inout Sony2FujiProcessor.Buffer?,
        hasReference: Bool,
        includeBefore: Bool,
        fallbackNative: CGSize?,
        normalizedRect: CGRect,
        maxOutputLongEdge: Int,
        tileKey: PhotoDetailTileKey?,
        existingAfter: PhotoDetailOverlay? = nil,
        cancelled: () -> Bool
    ) throws -> PhotoDetailOverlay {
        let edgeLimit = min(2048, maxOutputLongEdge)
        let roi = Sony2FujiProcessor.ViewportROI(normalizedRect: normalizedRect, maxOutputLongEdge: edgeLimit)
        let neutral = makeNeutralSettings(from: referenceSettings)
        let reuseAsBefore = hasReference && canReuseAfterAsBefore(
            settings: settings,
            neutral: neutral,
            sourceKind: sourceKind,
            lutURL: lutURL
        )
        if let existing = existingAfter, existing.renderID == expectedFrameID, let existingCG = existing.cgImage {
            guard hasReference, includeBefore else { return existing }
            if reuseAsBefore {
                return PhotoDetailOverlay(
                    cgImage: existingCG,
                    beforeCGImage: existingCG,
                    hdr: nil,
                    beforeHDR: nil,
                    normalizedRect: existing.normalizedRect,
                    pixelSize: existing.pixelSize,
                    fullNativeSize: existing.fullNativeSize,
                    renderID: expectedFrameID,
                    tileKey: tileKey ?? existing.tileKey
                )
            }
            if cancelled() { throw CancellationError() }
            let beforeOut: Sony2FujiProcessor.ViewportROIRenderOutput
            if sourceKind == .raw {
                beforeOut = try sourceFile.withReadAccess { url in
                    try self.processor.processRawROI(url: url, settings: neutral, lutURL: nil, roi: roi, cancelled: cancelled)
                }
            } else {
                let sourceBuffer = try resolveRasterROISourceBuffer(
                    sourceFile: sourceFile,
                    expectedSourceRevision: expectedSourceRevision,
                    draftBuffer: draftBuffer,
                    cachedFullRaster: &cachedFullRaster
                )
                if cancelled() { throw CancellationError() }
                beforeOut = try self.processor.processBufferROI(
                    buffer: sourceBuffer,
                    settings: neutral,
                    lutURL: nil,
                    roi: roi,
                    cancelled: cancelled
                )
            }
            if cancelled() { throw CancellationError() }
            return PhotoDetailOverlay(
                cgImage: existingCG,
                beforeCGImage: beforeOut.image.cgImage,
                hdr: nil,
                beforeHDR: nil,
                normalizedRect: existing.normalizedRect,
                pixelSize: existing.pixelSize,
                fullNativeSize: existing.fullNativeSize,
                renderID: expectedFrameID,
                tileKey: tileKey ?? existing.tileKey
            )
        }
        if sourceKind == .raw {
            let afterOut = try sourceFile.withReadAccess { url in
                try self.processor.processRawROI(url: url, settings: settings, lutURL: lutURL, roi: roi, cancelled: cancelled)
            }
            if cancelled() { throw CancellationError() }
            var beforeImage: UIImage? = nil
            if reuseAsBefore {
                beforeImage = afterOut.image
            } else if hasReference && includeBefore && !cancelled() {
                beforeImage = try? sourceFile.withReadAccess { url in
                    try self.processor.processRawROI(url: url, settings: neutral, lutURL: nil, roi: roi, cancelled: cancelled).image
                }
            }
            let fullSize = (afterOut.roi.fullNativeWidth > 0 && afterOut.roi.fullNativeHeight > 0)
                ? CGSize(width: afterOut.roi.fullNativeWidth, height: afterOut.roi.fullNativeHeight)
                : (fallbackNative ?? afterOut.image.size)
            return PhotoDetailOverlay(
                cgImage: afterOut.image.cgImage,
                beforeCGImage: beforeImage?.cgImage,
                hdr: nil,
                beforeHDR: nil,
                normalizedRect: afterOut.roi.normalizedRect,
                pixelSize: CGSize(
                    width: afterOut.image.size.width * afterOut.image.scale,
                    height: afterOut.image.size.height * afterOut.image.scale
                ),
                fullNativeSize: fullSize,
                renderID: expectedFrameID,
                tileKey: tileKey
            )
        }

        let sourceBuffer = try resolveRasterROISourceBuffer(
            sourceFile: sourceFile,
            expectedSourceRevision: expectedSourceRevision,
            draftBuffer: draftBuffer,
            cachedFullRaster: &cachedFullRaster
        )
        if cancelled() { throw CancellationError() }
        let afterOut = try self.processor.processBufferROI(
            buffer: sourceBuffer,
            settings: settings,
            lutURL: lutURL,
            roi: roi,
            cancelled: cancelled
        )
        if cancelled() { throw CancellationError() }
        var beforeImage: UIImage? = nil
        if reuseAsBefore {
            beforeImage = afterOut.image
        } else if hasReference && includeBefore && !cancelled() {
            beforeImage = try? self.processor.processBufferROI(
                buffer: sourceBuffer,
                settings: neutral,
                lutURL: nil,
                roi: roi,
                cancelled: cancelled
            ).image
        }
        let fullSize = (afterOut.roi.fullNativeWidth > 0 && afterOut.roi.fullNativeHeight > 0)
            ? CGSize(width: afterOut.roi.fullNativeWidth, height: afterOut.roi.fullNativeHeight)
            : (fallbackNative ?? afterOut.image.size)
        return PhotoDetailOverlay(
            cgImage: afterOut.image.cgImage,
            beforeCGImage: beforeImage?.cgImage,
            hdr: nil,
            beforeHDR: nil,
            normalizedRect: afterOut.roi.normalizedRect,
            pixelSize: CGSize(
                width: afterOut.image.size.width * afterOut.image.scale,
                height: afterOut.image.size.height * afterOut.image.scale
            ),
            fullNativeSize: fullSize,
            renderID: expectedFrameID,
            tileKey: tileKey
        )
    }

    private func renderBackingPair(
        sourceFile: PhotoSourceFile,
        sourceKind: ImageSourceKind,
        expectedSourceRevision: UUID,
        settings: RawSettings,
        referenceSettings: RawSettings,
        lutURL: URL?,
        draftBuffer: Sony2FujiProcessor.Buffer?,
        cachedFullRaster: inout Sony2FujiProcessor.Buffer?,
        hasReference: Bool,
        includeBefore: Bool,
        longEdge: Int,
        viewportPreview: Bool,
        cancelled: () -> Bool
    ) throws -> (afterCG: CGImage, beforeCG: CGImage?, nativeSize: CGSize) {
        let neutral = makeNeutralSettings(from: referenceSettings)
        let reuseAsBefore = hasReference && canReuseAfterAsBefore(
            settings: settings,
            neutral: neutral,
            sourceKind: sourceKind,
            lutURL: lutURL
        )
        if sourceKind == .raw {
            let afterOut = try sourceFile.withReadAccess { url in
                try self.processor.processRawDisplayBacking(
                    url: url,
                    settings: settings,
                    lutURL: lutURL,
                    longEdge: longEdge,
                    viewportPreview: viewportPreview,
                    cancelled: cancelled
                )
            }
            if cancelled() { throw CancellationError() }
            var beforeCG: CGImage? = nil
            if reuseAsBefore {
                beforeCG = afterOut.cgImage
            } else if hasReference && includeBefore && !cancelled() {
                beforeCG = try? sourceFile.withReadAccess { url in
                    try self.processor.processRawDisplayBacking(
                        url: url,
                        settings: neutral,
                        lutURL: nil,
                        longEdge: min(longEdge, self.detailBackingMaxLongEdge),
                        viewportPreview: true,
                        cancelled: cancelled
                    ).cgImage
                }
            }
            return (afterOut.cgImage, beforeCG, afterOut.nativeSize)
        }

        let sourceBuffer = try resolveRasterROISourceBuffer(
            sourceFile: sourceFile,
            expectedSourceRevision: expectedSourceRevision,
            draftBuffer: draftBuffer,
            cachedFullRaster: &cachedFullRaster
        )
        if cancelled() { throw CancellationError() }
        let afterOut = try self.processor.processBufferDisplayBacking(
            buffer: sourceBuffer,
            settings: settings,
            lutURL: lutURL,
            longEdge: longEdge,
            cancelled: cancelled
        )
        if cancelled() { throw CancellationError() }
        var beforeCG: CGImage? = nil
        if reuseAsBefore {
            beforeCG = afterOut.cgImage
        } else if hasReference && includeBefore && !cancelled() {
            beforeCG = try? self.processor.processBufferDisplayBacking(
                buffer: sourceBuffer,
                settings: neutral,
                lutURL: nil,
                longEdge: min(longEdge, self.detailBackingMaxLongEdge),
                cancelled: cancelled
            ).cgImage
        }
        return (afterOut.cgImage, beforeCG, afterOut.nativeSize)
    }

    private func ensureDetailWorkerRunning(for expectedFrameID: UUID) {
        guard !isBusy, !previewRendering, !previewResizePending,
              !currentPreviewSettings.isHDREditing,
              acceptedPreviewRequest?.quality == .final,
              acceptedPreviewFrameID == expectedFrameID,
              let sourceFile, let sourceKind else {
            return
        }
        let expectedSourceRevision = self.sourceRevision
        let settings = currentPreviewSettings
        let referenceSettings = committedPreviewSettings ?? settings
        let lutURL = self.lutURL(for: settings)
        let draftBuffer = self.draftBuffer
        var cachedFullRaster = self.fullRasterROIBuffer
        let hasReference = basePreviewImage != nil
        let fallbackNative = viewportNativeSize
        let backingMaxEdge = detailBackingMaxLongEdge
        let metalMaxPixels = fastMetalFullResMaxPixels

        renderStateLock.lock()
        if detailWorkerActive && detailWorkerFrameID == expectedFrameID {
            renderStateLock.unlock()
            return
        }
        let token = UUID()
        detailRenderToken = token
        detailWorkerActive = true
        detailWorkerFrameID = expectedFrameID
        inFlightDetailTileKey = nil
        renderStateLock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.renderStateLock.lock()
                if self.detailRenderToken == token {
                    self.detailWorkerActive = false
                    self.detailWorkerFrameID = nil
                    self.inFlightDetailTileKey = nil
                }
                self.renderStateLock.unlock()
            }

            let frameCancelled = {
                !self.isLatestDetailToken(token) || !self.isLatestRenderID(expectedFrameID)
            }
            let neutral = self.makeNeutralSettings(from: referenceSettings)
            let reuseNeutralAsBefore = hasReference && self.canReuseAfterAsBefore(
                settings: settings,
                neutral: neutral,
                sourceKind: sourceKind,
                lutURL: lutURL
            )
            var prewarmCenterSpecs: [PhotoDetailTileSpec] = []
            var failedAfterKeys: Set<PhotoDetailTileKey> = []
            var failedBeforeKeys: Set<PhotoDetailTileKey> = []

            func sliceLevel0Tiles(from fullCG: CGImage, fullNativeSize: CGSize) -> [PhotoDetailOverlay] {
                let specs = PhotoDetailTilePlan.level0Grid(fullNativeSize: fullNativeSize)
                var slices: [PhotoDetailOverlay] = []
                slices.reserveCapacity(specs.count)
                for spec in specs {
                    let rx0 = Int((spec.normalizedRect.minX * CGFloat(fullCG.width)).rounded())
                    let ry0 = Int((spec.normalizedRect.minY * CGFloat(fullCG.height)).rounded())
                    let rx1 = Int((spec.normalizedRect.maxX * CGFloat(fullCG.width)).rounded())
                    let ry1 = Int((spec.normalizedRect.maxY * CGFloat(fullCG.height)).rounded())
                    let px0 = max(0, min(fullCG.width - 1, rx0))
                    let py0 = max(0, min(fullCG.height - 1, ry0))
                    let px1 = max(px0 + 1, min(fullCG.width, rx1))
                    let py1 = max(py0 + 1, min(fullCG.height, ry1))
                    let cropRect = CGRect(x: px0, y: py0, width: px1 - px0, height: py1 - py0)
                    guard let tileCG = fullCG.cropping(to: cropRect) else { continue }
                    slices.append(PhotoDetailOverlay(
                        cgImage: tileCG,
                        beforeCGImage: reuseNeutralAsBefore ? tileCG : nil,
                        hdr: nil,
                        beforeHDR: nil,
                        normalizedRect: spec.normalizedRect,
                        pixelSize: CGSize(width: tileCG.width, height: tileCG.height),
                        fullNativeSize: fullNativeSize,
                        renderID: expectedFrameID,
                        tileKey: spec.key
                    ))
                }
                return slices
            }

            func tryRunPathA(fallbackSize: CGSize?) -> Bool {
                guard sourceKind == .raw, let fallbackSize,
                      fallbackSize.width > 0, fallbackSize.height > 0 else {
                    return false
                }
                let fullW = Int(fallbackSize.width.rounded())
                let fullH = Int(fallbackSize.height.rounded())
                let nativePixels = fullW * fullH
                guard nativePixels > 0, nativePixels <= metalMaxPixels else {
                    return false
                }
                let canMetal = sourceFile.withReadAccess { url in
                    self.processor.canFastMetalFullRes(url: url, settings: settings, lutURL: lutURL)
                }
                guard canMetal else { return false }

                do {
                    let nativeLong = max(fullW, fullH)
                    let out = try sourceFile.withReadAccess { url in
                        try self.processor.processRawDisplayBacking(
                            url: url,
                            settings: settings,
                            lutURL: lutURL,
                            longEdge: nativeLong,
                            viewportPreview: false,
                            cancelled: frameCancelled
                        )
                    }
                    if frameCancelled() { return true }
                    let backingCG = self.processor.downscaleDisplayCGImage(out.cgImage, maxLongEdge: backingMaxEdge) ?? out.cgImage
                    let backing = PhotoDetailBacking(
                        cgImage: backingCG,
                        beforeCGImage: reuseNeutralAsBefore ? backingCG : nil,
                        pixelSize: CGSize(width: backingCG.width, height: backingCG.height),
                        fullNativeSize: out.nativeSize,
                        renderID: expectedFrameID
                    )
                    let tiles = sliceLevel0Tiles(from: out.cgImage, fullNativeSize: out.nativeSize)

                    self.renderStateLock.lock()
                    self.detailBackingRenderedFrameID = expectedFrameID
                    self.detailPrewarmPending = false
                    self.detailDeliverySequence &+= 1
                    let seq = self.detailDeliverySequence
                    for tile in tiles {
                        if let key = tile.tileKey {
                            self.pendingDetailDeliveryKeys[key] = (hasBefore: tile.beforeCGImage != nil, seq: seq)
                            self.detailTileAfterLocked[key] = tile
                        }
                    }
                    self.renderStateLock.unlock()

                    self.resultDelivery {
                        defer {
                            self.renderStateLock.lock()
                            for tile in tiles {
                                if let key = tile.tileKey, self.pendingDetailDeliveryKeys[key]?.seq == seq {
                                    self.pendingDetailDeliveryKeys.removeValue(forKey: key)
                                }
                            }
                            self.renderStateLock.unlock()
                        }
                        guard !self.isBusy, !self.previewRendering, !self.previewResizePending,
                              self.sourceRevision == expectedSourceRevision,
                              self.acceptedPreviewFrameID == expectedFrameID else {
                            return
                        }
                        self.detailBacking = backing
                        let currentAllSpecs = self.tileSpecs(for: self.lastDetailRequest)
                        let keepKeys = Set(currentAllSpecs.all.map(\.key))
                        for tile in tiles.reversed() {
                            self.storeDetailTile(tile, keepKeys: keepKeys)
                        }
                        if !currentAllSpecs.all.isEmpty {
                            self.touchDetailTileKeys(currentAllSpecs.all.map(\.key))
                        }
                        if self.lastDetailRequest != nil {
                            let active = self.activeDetailTiles(for: currentAllSpecs.all, visibleSpecs: currentAllSpecs.visible)
                            if !self.detailTileListMatches(self.detailTiles, active) {
                                self.detailTiles = active
                            }
                            self.detailOverlay = active.last ?? tiles.first
                        }
                        if self.detailNeedsBefore,
                           backing.beforeCGImage == nil,
                           self.basePreviewImage != nil,
                           !self.currentPreviewSettings.isHDREditing {
                            self.renderStateLock.lock()
                            self.detailBeforeBackingPending = true
                            self.renderStateLock.unlock()
                            self.ensureDetailWorkerRunning(for: expectedFrameID)
                        }
                    }
                    return true
                } catch is CancellationError {
                    return true
                } catch {
                    self.renderStateLock.lock()
                    self.detailMetalFullResFailedFrameID = expectedFrameID
                    self.renderStateLock.unlock()
                    return false
                }
            }

            func runTileSpec(
                _ spec: PhotoDetailTileSpec,
                existingAfter: PhotoDetailOverlay?,
                includeBefore: Bool,
                trackInFlight: Bool,
                cancelled: @escaping () -> Bool
            ) -> Bool {
                if trackInFlight {
                    self.renderStateLock.lock()
                    self.inFlightDetailTileKey = spec.key
                    self.renderStateLock.unlock()
                }
                defer {
                    if trackInFlight {
                        self.renderStateLock.lock()
                        if self.inFlightDetailTileKey == spec.key { self.inFlightDetailTileKey = nil }
                        self.renderStateLock.unlock()
                    }
                }
                do {
                    let tile = try self.renderSDRDetailTile(
                        sourceFile: sourceFile,
                        sourceKind: sourceKind,
                        expectedSourceRevision: expectedSourceRevision,
                        expectedFrameID: expectedFrameID,
                        settings: settings,
                        referenceSettings: referenceSettings,
                        lutURL: lutURL,
                        draftBuffer: draftBuffer,
                        cachedFullRaster: &cachedFullRaster,
                        hasReference: hasReference,
                        includeBefore: includeBefore,
                        fallbackNative: fallbackNative,
                        normalizedRect: spec.normalizedRect,
                        maxOutputLongEdge: spec.maxOutputLongEdge,
                        tileKey: spec.key,
                        existingAfter: existingAfter,
                        cancelled: cancelled
                    )
                    if frameCancelled() { return false }
                    if trackInFlight && !self.isTileStillDesired(spec.key) { return true }
                    if !trackInFlight && self.hasPendingLiveDetailSpecs() { return true }

                    self.renderStateLock.lock()
                    self.detailDeliverySequence &+= 1
                    let seq = self.detailDeliverySequence
                    self.pendingDetailDeliveryKeys[spec.key] = (hasBefore: tile.beforeCGImage != nil, seq: seq)
                    self.detailTileAfterLocked[spec.key] = tile
                    self.renderStateLock.unlock()

                    self.resultDelivery {
                        defer {
                            self.renderStateLock.lock()
                            if self.pendingDetailDeliveryKeys[spec.key]?.seq == seq {
                                self.pendingDetailDeliveryKeys.removeValue(forKey: spec.key)
                            }
                            self.renderStateLock.unlock()
                        }
                        guard !self.isBusy, !self.previewRendering, !self.previewResizePending,
                              self.sourceRevision == expectedSourceRevision,
                              self.acceptedPreviewFrameID == expectedFrameID else {
                            return
                        }
                        let current = self.tileSpecs(for: self.lastDetailRequest)
                        self.storeDetailTile(tile, keepKeys: Set(current.all.map(\.key)))
                        guard self.lastDetailRequest != nil else { return }
                        let active = self.activeDetailTiles(for: current.all, visibleSpecs: current.visible)
                        if !self.detailTileListMatches(self.detailTiles, active) {
                            self.detailTiles = active
                        }
                        self.detailOverlay = active.last ?? (trackInFlight ? tile : self.detailOverlay)
                    }
                    return true
                } catch is CancellationError {
                    return !frameCancelled()
                } catch {
                    if existingAfter != nil {
                        failedBeforeKeys.insert(spec.key)
                    } else {
                        failedAfterKeys.insert(spec.key)
                    }
                    return true
                }
            }

            while !frameCancelled() {
                self.renderStateLock.lock()
                let desiredSpecs = self.desiredDetailSpecs
                let visibleKeys = self.desiredDetailVisibleKeys
                let needsBefore = self.detailNeedsBeforeLocked
                let prewarmPending = self.detailPrewarmPending
                let beforeBackingPending = self.detailBeforeBackingPending
                let backingDone = self.detailBackingRenderedFrameID == expectedFrameID
                let metalFailed = self.detailMetalFullResFailedFrameID == expectedFrameID

                func hasAnyTile(_ key: PhotoDetailTileKey) -> Bool {
                    self.pendingDetailDeliveryKeys[key] != nil || self.cachedDetailTileBeforeLocked[key] != nil
                }

                func hasBeforeTile(_ key: PhotoDetailTileKey) -> Bool {
                    self.pendingDetailDeliveryKeys[key]?.hasBefore ?? self.cachedDetailTileBeforeLocked[key] ?? false
                }

                func needsAfter(_ spec: PhotoDetailTileSpec) -> Bool {
                    !failedAfterKeys.contains(spec.key) && !hasAnyTile(spec.key)
                }

                func needsBeforeOnly(_ spec: PhotoDetailTileSpec) -> Bool {
                    needsBefore && hasReference && !reuseNeutralAsBefore &&
                        !failedBeforeKeys.contains(spec.key) &&
                        hasAnyTile(spec.key) &&
                        !hasBeforeTile(spec.key) &&
                        self.detailTileAfterLocked[spec.key]?.cgImage != nil
                }

                let liveVisibleAfter = desiredSpecs.first { visibleKeys.contains($0.key) && needsAfter($0) }
                let liveVisibleBefore: (spec: PhotoDetailTileSpec, existing: PhotoDetailOverlay)? = {
                    guard liveVisibleAfter == nil, !beforeBackingPending else { return nil }
                    for spec in desiredSpecs where visibleKeys.contains(spec.key) && needsBeforeOnly(spec) {
                        if let existing = self.detailTileAfterLocked[spec.key] {
                            return (spec, existing)
                        }
                    }
                    return nil
                }()
                let liveOverscanAfter: PhotoDetailTileSpec? = {
                    guard liveVisibleAfter == nil, !beforeBackingPending, liveVisibleBefore == nil,
                          !(prewarmPending && !backingDone) else {
                        return nil
                    }
                    return desiredSpecs.first { !visibleKeys.contains($0.key) && needsAfter($0) }
                }()
                let liveOverscanBefore: (spec: PhotoDetailTileSpec, existing: PhotoDetailOverlay)? = {
                    guard liveVisibleAfter == nil, !beforeBackingPending, liveVisibleBefore == nil,
                          !(prewarmPending && !backingDone), liveOverscanAfter == nil else {
                        return nil
                    }
                    for spec in desiredSpecs where !visibleKeys.contains(spec.key) && needsBeforeOnly(spec) {
                        if let existing = self.detailTileAfterLocked[spec.key] {
                            return (spec, existing)
                        }
                    }
                    return nil
                }()
                let prewarmSpec: PhotoDetailTileSpec? = {
                    guard liveVisibleAfter == nil, !beforeBackingPending, liveVisibleBefore == nil,
                          !(prewarmPending && !backingDone), liveOverscanAfter == nil, liveOverscanBefore == nil else {
                        return nil
                    }
                    return prewarmCenterSpecs.first(where: needsAfter)
                }()
                self.renderStateLock.unlock()

                if let spec = liveVisibleAfter {
                    if !backingDone && !metalFailed && !needsBefore && tryRunPathA(fallbackSize: fallbackNative) {
                        if frameCancelled() { break }
                        continue
                    }
                    if !runTileSpec(
                        spec,
                        existingAfter: nil,
                        includeBefore: false,
                        trackInFlight: true,
                        cancelled: { frameCancelled() || !self.isTileStillDesired(spec.key) }
                    ) {
                        break
                    }
                    continue
                }

                if beforeBackingPending {
                    self.renderStateLock.lock()
                    self.detailBeforeBackingPending = false
                    self.renderStateLock.unlock()
                    if hasReference, !reuseNeutralAsBefore {
                        let nativeLong = Int(max(fallbackNative?.width ?? 0, fallbackNative?.height ?? 0).rounded())
                        let backingEdge = min(backingMaxEdge, max(1, nativeLong))
                        if backingEdge > 0 {
                            do {
                                let out = try self.renderBackingPair(
                                    sourceFile: sourceFile,
                                    sourceKind: sourceKind,
                                    expectedSourceRevision: expectedSourceRevision,
                                    settings: neutral,
                                    referenceSettings: referenceSettings,
                                    lutURL: nil,
                                    draftBuffer: draftBuffer,
                                    cachedFullRaster: &cachedFullRaster,
                                    hasReference: false,
                                    includeBefore: false,
                                    longEdge: backingEdge,
                                    viewportPreview: true,
                                    cancelled: frameCancelled
                                )
                                if frameCancelled() { break }
                                self.resultDelivery {
                                    guard !self.isBusy, !self.previewRendering, !self.previewResizePending,
                                          self.sourceRevision == expectedSourceRevision,
                                          self.acceptedPreviewFrameID == expectedFrameID,
                                          let current = self.detailBacking,
                                          current.renderID == expectedFrameID,
                                          current.beforeCGImage == nil else {
                                        return
                                    }
                                    self.detailBacking = PhotoDetailBacking(
                                        cgImage: current.cgImage,
                                        beforeCGImage: out.afterCG,
                                        pixelSize: current.pixelSize,
                                        fullNativeSize: current.fullNativeSize,
                                        renderID: expectedFrameID
                                    )
                                }
                            } catch is CancellationError {
                                break
                            } catch {
                                // Ignore; individual before tiles remain available on zoom.
                            }
                        }
                    } else if hasReference, reuseNeutralAsBefore {
                        self.resultDelivery {
                            guard !self.isBusy, !self.previewRendering, !self.previewResizePending,
                                  self.sourceRevision == expectedSourceRevision,
                                  self.acceptedPreviewFrameID == expectedFrameID,
                                  let current = self.detailBacking,
                                  current.renderID == expectedFrameID,
                                  current.beforeCGImage == nil else {
                                return
                            }
                            self.detailBacking = PhotoDetailBacking(
                                cgImage: current.cgImage,
                                beforeCGImage: current.cgImage,
                                pixelSize: current.pixelSize,
                                fullNativeSize: current.fullNativeSize,
                                renderID: expectedFrameID
                            )
                        }
                    }
                    continue
                }

                if let entry = liveVisibleBefore {
                    if !runTileSpec(
                        entry.spec,
                        existingAfter: entry.existing,
                        includeBefore: true,
                        trackInFlight: true,
                        cancelled: { frameCancelled() || !self.isTileStillDesired(entry.spec.key) }
                    ) {
                        break
                    }
                    continue
                }

                if prewarmPending && !backingDone {
                    if !metalFailed && !needsBefore && tryRunPathA(fallbackSize: fallbackNative) {
                        if frameCancelled() { break }
                        continue
                    }

                    let nativeLong = Int(max(fallbackNative?.width ?? 0, fallbackNative?.height ?? 0).rounded())
                    let backingEdge = min(backingMaxEdge, max(1, nativeLong))
                    guard backingEdge > 0 else {
                        self.renderStateLock.lock()
                        self.detailPrewarmPending = false
                        self.renderStateLock.unlock()
                        continue
                    }
                    do {
                        let out = try self.renderBackingPair(
                            sourceFile: sourceFile,
                            sourceKind: sourceKind,
                            expectedSourceRevision: expectedSourceRevision,
                            settings: settings,
                            referenceSettings: referenceSettings,
                            lutURL: lutURL,
                            draftBuffer: draftBuffer,
                            cachedFullRaster: &cachedFullRaster,
                            hasReference: hasReference,
                            includeBefore: needsBefore,
                            longEdge: backingEdge,
                            viewportPreview: true,
                            cancelled: frameCancelled
                        )
                        if frameCancelled() { break }
                        let backing = PhotoDetailBacking(
                            cgImage: out.afterCG,
                            beforeCGImage: out.beforeCG,
                            pixelSize: CGSize(width: out.afterCG.width, height: out.afterCG.height),
                            fullNativeSize: out.nativeSize,
                            renderID: expectedFrameID
                        )
                        self.renderStateLock.lock()
                        self.detailBackingRenderedFrameID = expectedFrameID
                        self.detailPrewarmPending = false
                        self.renderStateLock.unlock()

                        let actualLong = max(out.nativeSize.width, out.nativeSize.height)
                        if Int(actualLong.rounded()) > backingMaxEdge {
                            prewarmCenterSpecs = PhotoDetailTilePlan.tiles(
                                visibleRect: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30),
                                fullNativeSize: out.nativeSize,
                                zoomScale: 1.0,
                                baseScale: CGFloat(backingEdge) / max(1, actualLong),
                                overscanRing: 0
                            )
                        }

                        self.resultDelivery {
                            guard !self.isBusy, !self.previewRendering, !self.previewResizePending,
                                  self.sourceRevision == expectedSourceRevision,
                                  self.acceptedPreviewFrameID == expectedFrameID else {
                                return
                            }
                            self.detailBacking = backing
                            if self.detailNeedsBefore,
                               backing.beforeCGImage == nil,
                               self.basePreviewImage != nil,
                               !self.currentPreviewSettings.isHDREditing {
                                self.renderStateLock.lock()
                                self.detailBeforeBackingPending = true
                                self.renderStateLock.unlock()
                                self.ensureDetailWorkerRunning(for: expectedFrameID)
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        self.renderStateLock.lock()
                        self.detailPrewarmPending = false
                        self.renderStateLock.unlock()
                    }
                    continue
                }

                if let spec = liveOverscanAfter {
                    if !runTileSpec(
                        spec,
                        existingAfter: nil,
                        includeBefore: false,
                        trackInFlight: true,
                        cancelled: { frameCancelled() || !self.isTileStillDesired(spec.key) }
                    ) {
                        break
                    }
                    continue
                }

                if let entry = liveOverscanBefore {
                    if !runTileSpec(
                        entry.spec,
                        existingAfter: entry.existing,
                        includeBefore: true,
                        trackInFlight: true,
                        cancelled: { frameCancelled() || !self.isTileStillDesired(entry.spec.key) }
                    ) {
                        break
                    }
                    continue
                }

                if let spec = prewarmSpec {
                    if !runTileSpec(
                        spec,
                        existingAfter: nil,
                        includeBefore: false,
                        trackInFlight: false,
                        cancelled: { frameCancelled() || self.hasPendingLiveDetailSpecs() }
                    ) {
                        break
                    }
                    continue
                }

                self.renderStateLock.lock()
                let moreLive = self.desiredDetailSpecs.contains { needsAfter($0) || needsBeforeOnly($0) }
                let morePrewarm = self.detailPrewarmPending && self.detailBackingRenderedFrameID != expectedFrameID
                let moreBeforeBacking = self.detailBeforeBackingPending
                if !moreLive && !morePrewarm && !moreBeforeBacking {
                    if self.detailRenderToken == token {
                        self.detailWorkerActive = false
                        self.detailWorkerFrameID = nil
                        self.inFlightDetailTileKey = nil
                    }
                    self.renderStateLock.unlock()
                    return
                }
                self.renderStateLock.unlock()
            }
        }
    }

    func scheduleDetailRender(for request: PhotoDetailRequest) {
        guard !isBusy, !previewRendering, !previewResizePending,
              let sourceFile, let sourceKind,
              let expectedFrameID = acceptedPreviewFrameID,
              acceptedPreviewRequest?.quality == .final else {
            return
        }
        let token = UUID()
        setLatestDetailToken(token)
        detailDebounceWorkItem?.cancel()
        let expectedSourceRevision = self.sourceRevision
        let settings = currentPreviewSettings
        let referenceSettings = committedPreviewSettings ?? settings
        let lutURL = settings.isHDREditing ? nil : self.lutURL(for: settings)
        let draftBuffer = self.draftBuffer
        var cachedFullRaster = self.fullRasterROIBuffer
        let baseHeadroom = hdrPresentation?.statistics.headroom ?? 0
        let refHeadroom = hdrReference?.statistics.headroom ?? 0
        let hasReference = basePreviewImage != nil || hdrReference != nil
        let fallbackNative = viewportNativeSize
        let needsBefore = detailNeedsBefore

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isLatestDetailToken(token) {
                self.detailDebounceWorkItem = nil
            }
            guard self.isLatestDetailToken(token),
                  !self.isBusy, !self.previewRendering, !self.previewResizePending,
                  self.sourceRevision == expectedSourceRevision,
                  self.acceptedPreviewFrameID == expectedFrameID else {
                return
            }
            self.renderQueue.async { [weak self] in
                guard let self else { return }
                let cancelled = {
                    !self.isLatestDetailToken(token) || !self.isLatestRenderID(expectedFrameID)
                }
                if cancelled() { return }
                do {
                    let overlay: PhotoDetailOverlay
                    if let hdr = settings.hdr, settings.isHDREditing {
                        let edgeLimit = min(1280, request.maxOutputLongEdge)
                        let afterOut: Sony2FujiProcessor.HDRROIRenderOutput = try sourceFile.withReadAccess { url in
                            try self.processor.processHDRROI(
                                url: url,
                                settings: hdr.previewSettings(),
                                roi: HDRViewportROI(
                                    normX0: Double(request.overscanRect.minX),
                                    normY0: Double(request.overscanRect.minY),
                                    normX1: Double(request.overscanRect.maxX),
                                    normY1: Double(request.overscanRect.maxY),
                                    maxOutputLongEdge: edgeLimit,
                                    baseContentHeadroom: baseHeadroom
                                ),
                                processing: settings.processing,
                                proRAWDecodeVersion: settings.proRAWDecodeVersion,
                                cancelled: cancelled
                            )
                        }
                        if cancelled() { return }
                        let afterHDR = try HDRPresentation(
                            afterOut.image,
                            headroomOverride: baseHeadroom >= 1 ? baseHeadroom : nil
                        )
                        var beforeHDR: HDRPresentation? = nil
                        if hasReference, !cancelled() {
                            let neutralHDR = hdr.neutralGeometrySettings
                            if hdr.previewSettings() == neutralHDR {
                                beforeHDR = afterHDR
                            } else if let refOut = try? sourceFile.withReadAccess({ url in
                                try self.processor.processHDRROI(
                                    url: url,
                                    settings: neutralHDR,
                                    roi: HDRViewportROI(
                                        normX0: Double(request.overscanRect.minX),
                                        normY0: Double(request.overscanRect.minY),
                                        normX1: Double(request.overscanRect.maxX),
                                        normY1: Double(request.overscanRect.maxY),
                                        maxOutputLongEdge: edgeLimit,
                                        baseContentHeadroom: refHeadroom
                                    ),
                                    processing: settings.processing,
                                    proRAWDecodeVersion: settings.proRAWDecodeVersion,
                                    cancelled: cancelled
                                )
                            }), !cancelled() {
                                beforeHDR = try? HDRPresentation(
                                    refOut.image,
                                    headroomOverride: refHeadroom >= 1 ? refHeadroom : nil
                                )
                            }
                        }
                        let r = afterOut.roi
                        let rect = (r.fullNativeWidth > 0 && r.fullNativeHeight > 0)
                            ? CGRect(
                                x: CGFloat(r.nativeX0) / CGFloat(r.fullNativeWidth),
                                y: CGFloat(r.nativeY0) / CGFloat(r.fullNativeHeight),
                                width: CGFloat(r.nativeX1 - r.nativeX0) / CGFloat(r.fullNativeWidth),
                                height: CGFloat(r.nativeY1 - r.nativeY0) / CGFloat(r.fullNativeHeight)
                            )
                            : request.overscanRect
                        let fullSize = (r.fullNativeWidth > 0 && r.fullNativeHeight > 0)
                            ? CGSize(width: r.fullNativeWidth, height: r.fullNativeHeight)
                            : (fallbackNative ?? CGSize(width: afterOut.image.width, height: afterOut.image.height))
                        overlay = PhotoDetailOverlay(
                            cgImage: nil,
                            beforeCGImage: nil,
                            hdr: afterHDR,
                            beforeHDR: beforeHDR,
                            normalizedRect: rect,
                            pixelSize: CGSize(width: afterOut.image.width, height: afterOut.image.height),
                            fullNativeSize: fullSize,
                            renderID: expectedFrameID
                        )
                    } else {
                        overlay = try self.renderSDRDetailTile(
                            sourceFile: sourceFile,
                            sourceKind: sourceKind,
                            expectedSourceRevision: expectedSourceRevision,
                            expectedFrameID: expectedFrameID,
                            settings: settings,
                            referenceSettings: referenceSettings,
                            lutURL: lutURL,
                            draftBuffer: draftBuffer,
                            cachedFullRaster: &cachedFullRaster,
                            hasReference: hasReference,
                            includeBefore: needsBefore,
                            fallbackNative: fallbackNative,
                            normalizedRect: request.overscanRect,
                            maxOutputLongEdge: request.maxOutputLongEdge,
                            tileKey: nil,
                            cancelled: cancelled
                        )
                    }
                    if cancelled() { return }
                    self.resultDelivery {
                        guard self.isLatestDetailToken(token),
                              !self.isBusy, !self.previewRendering, !self.previewResizePending,
                              self.sourceRevision == expectedSourceRevision,
                              self.acceptedPreviewFrameID == expectedFrameID else {
                            return
                        }
                        if !self.detailTiles.isEmpty { self.detailTiles = [] }
                        if overlay.hdr != nil {
                            self.storeHDRDetail(overlay)
                        }
                        self.detailOverlay = overlay
                    }
                } catch {
                    // ROI errors, cancellation, or OOM degrade quietly to the base preview.
                }
            }
        }
        detailDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
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
