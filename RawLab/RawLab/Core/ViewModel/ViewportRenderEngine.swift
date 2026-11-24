import RawLabKit
import CoreGraphics
import Foundation
import UIKit

final class ViewportRenderEngine {
    private let processor: Sony2FujiProcessor
    private let renderQueue: DispatchQueue
    private let renderStateLock: NSLock
    private let resultDelivery: (@escaping () -> Void) -> Void
    private weak var viewModel: RawEditorViewModel?

    let tileCache = ViewportTileCache(byteBudget: 112 * 1024 * 1024, maxCount: 36)
    let detailBackingMaxLongEdge = 3072
    let fastMetalFullResMaxPixels = 28_000_000
    let completedPreviewCacheLimit = 3
    let hdrDetailMaxCount = 4

    var detailDebounceWorkItem: DispatchWorkItem?
    var detailRenderToken = UUID()
    var lastDetailRequest: PhotoDetailRequest?
    var detailPrewarmEnabled = true
    var detailNeedsBefore = false
    var desiredDetailSpecs: [PhotoDetailTileSpec] = []
    var desiredDetailKeys: Set<PhotoDetailTileKey> = []
    var desiredDetailVisibleKeys: Set<PhotoDetailTileKey> = []
    var desiredDetailRequiredKeys: Set<PhotoDetailTileKey> = []
    var inFlightDetailTileKey: PhotoDetailTileKey?
    var detailWorkerActive = false
    var detailWorkerFrameID: UUID?
    var detailBackingRenderedFrameID: UUID?
    var detailPrewarmScheduledFrameID: UUID?
    var detailMetalFullResFailedFrameID: UUID?
    var detailNeedsBeforeLocked = false
    var detailPrewarmPending = false
    var detailBeforeBackingPending = false
    var cachedDetailTileBeforeLocked: [PhotoDetailTileKey: Bool] = [:]
    var detailTileAfterLocked: [PhotoDetailTileKey: PhotoDetailOverlay] = [:]
    var detailDeliverySequence: UInt64 = 0
    var pendingDetailDeliveryKeys: [PhotoDetailTileKey: (hasBefore: Bool, seq: UInt64)] = [:]
    var hdrDetailCache: [PhotoDetailOverlay] = []

    var completedPreviewCache: [RawEditorViewModel.CompletedPreview] = []
    var completedPreviewCacheBytes = 0
    var fullRasterROIBuffer: Sony2FujiProcessor.Buffer?

    init(
        processor: Sony2FujiProcessor,
        renderQueue: DispatchQueue,
        renderStateLock: NSLock,
        resultDelivery: @escaping (@escaping () -> Void) -> Void
    ) {
        self.processor = processor
        self.renderQueue = renderQueue
        self.renderStateLock = renderStateLock
        self.resultDelivery = resultDelivery
    }

    func attach(_ viewModel: RawEditorViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        detailDebounceWorkItem?.cancel()
    }

    // MARK: - Preview Cache

    func previewLUTIdentity(for url: URL?) -> RawEditorViewModel.PreviewLUTFileIdentity? {
        guard let url else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return RawEditorViewModel.PreviewLUTFileIdentity(
            url: url.standardizedFileURL,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    func clearPreviewCache() {
        completedPreviewCache.removeAll()
        completedPreviewCacheBytes = 0
    }

    func setCompletedPreviewCache(_ entries: [RawEditorViewModel.CompletedPreview]) {
        completedPreviewCache = entries
        completedPreviewCacheBytes = entries.reduce(0) { $0 + $1.estimatedMemoryBytes }
    }

    func sourceDidChange() {
        clearPreviewCache()
        fullRasterROIBuffer = nil
    }

    func invalidatePreviewCacheIfLookChanged(settings: RawSettings, lut: RawEditorViewModel.PreviewLUTFileIdentity?) {
        if let previous = completedPreviewCache.last?.key,
           previous.settings != settings || previous.lut != lut {
            clearPreviewCache()
        }
    }

    func completedPreview(for key: RawEditorViewModel.PreviewCacheKey) -> RawEditorViewModel.CompletedPreview? {
        guard let index = completedPreviewCache.firstIndex(where: { $0.key == key }) else { return nil }
        let cached = completedPreviewCache.remove(at: index)
        completedPreviewCache.append(cached)
        return cached
    }

    func cacheCompletedPreview(
        for key: RawEditorViewModel.PreviewCacheKey,
        histogramInput: Sony2FujiProcessor.Buffer? = nil
    ) {
        guard let vm = viewModel else { return }
        guard key.quality == .final, vm.previewImage != nil, vm.comparisonReferenceKey == key.referenceKey,
              !key.settings.isHDREditing || key.settings.hdr?.missingResourceMessage == nil else { return }
        let entry = RawEditorViewModel.CompletedPreview(
            key: key,
            previewImage: vm.previewImage,
            basePreviewImage: vm.basePreviewImage,
            histogram: key.includeHistogram ? vm.histogram : nil,
            histogramInput: histogramInput,
            baseHistogram: vm.baseHistogram,
            nativeImageSize: vm.nativeImageSize,
            hdrPresentation: vm.hdrPresentation,
            hdrReference: vm.hdrReference,
            basePreviewGeometry: vm.basePreviewGeometry,
            basePreviewProcessing: vm.basePreviewProcessing,
            basePreviewLens: vm.basePreviewLens,
            comparisonReferenceKey: vm.comparisonReferenceKey,
            rawWhiteBalance: vm.rawWhiteBalance,
            lensInfo: vm.lensInfo,
            sourceOrientation: vm.sourceOrientation
        )
        let entryBytes = entry.estimatedMemoryBytes
        let budget = key.settings.isHDREditing ? 128 * 1024 * 1024 : 64 * 1024 * 1024
        guard entryBytes <= budget else { return }
        if let existingIndex = completedPreviewCache.firstIndex(where: { $0.key == key }) {
            completedPreviewCacheBytes -= completedPreviewCache[existingIndex].estimatedMemoryBytes
            completedPreviewCache.remove(at: existingIndex)
        }
        while completedPreviewCacheBytes + entryBytes > budget, !completedPreviewCache.isEmpty {
            completedPreviewCacheBytes -= completedPreviewCache.removeFirst().estimatedMemoryBytes
        }
        completedPreviewCache.append(entry)
        completedPreviewCacheBytes += entryBytes
        while completedPreviewCache.count > completedPreviewCacheLimit {
            completedPreviewCacheBytes -= completedPreviewCache.removeFirst().estimatedMemoryBytes
        }
    }

    func updateCachedPreviewHistogram(
        _ histogram: Sony2FujiProcessor.RGBHistogram?,
        for key: RawEditorViewModel.PreviewCacheKey
    ) {
        guard let index = completedPreviewCache.firstIndex(where: { $0.key == key }) else { return }
        completedPreviewCache[index].histogram = histogram
        completedPreviewCache[index].histogramInput = nil
    }

    // MARK: - Detail Lifecycle & Memory Reclamation

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

    func reclaimMemory(
        releaseRaster: Bool = false,
        keepRequest: Bool = false,
        preservePrewarmFrameID: UUID? = nil
    ) {
        detailDebounceWorkItem?.cancel()
        detailDebounceWorkItem = nil
        if let vm = viewModel {
            vm.detailOverlay = nil
            if !vm.detailTiles.isEmpty {
                vm.detailTiles = []
            }
            if vm.detailBacking != nil {
                vm.detailBacking = nil
            }
        }
        tileCache.reclaimMemory()
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
        detailPrewarmScheduledFrameID = preservePrewarmFrameID
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

    func toggleCompare(needsBefore needed: Bool) {
        guard detailNeedsBefore != needed, let vm = viewModel else { return }
        detailNeedsBefore = needed
        var needsWorkerKick = false
        renderStateLock.lock()
        detailNeedsBeforeLocked = needed
        if needed,
           vm.detailBacking != nil,
           vm.detailBacking?.beforeCGImage == nil,
           vm.basePreviewImage != nil,
           !vm.currentPreviewSettings.isHDREditing {
            detailBeforeBackingPending = true
            needsWorkerKick = true
        }
        renderStateLock.unlock()
        if needed, !vm.currentPreviewSettings.isHDREditing {
            if let req = lastDetailRequest {
                updateViewport(req)
            }
            if needsWorkerKick, let frameID = vm.acceptedPreviewFrameID {
                ensureDetailWorkerRunning(for: frameID)
            }
        }
    }

    func triggerPrewarmIfEligible() {
        guard let vm = viewModel,
              detailPrewarmEnabled,
              !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
              !vm.currentPreviewSettings.isHDREditing,
              vm.acceptedPreviewRequest?.quality == .final,
              let frameID = vm.acceptedPreviewFrameID,
              let native = vm.viewportNativeSize,
              Int(max(native.width, native.height).rounded()) > vm.previewLongEdge else {
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

    func updateViewport(_ request: PhotoDetailRequest?) {
        guard let vm = viewModel else { return }
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
            if vm.detailOverlay != nil { vm.detailOverlay = nil }
            if !vm.detailTiles.isEmpty { vm.detailTiles = [] }
            return
        }
        lastDetailRequest = request
        if !vm.currentPreviewSettings.isHDREditing, let frameID = vm.acceptedPreviewFrameID {
            if tileCache.resetIfFrameChanged(frameID) {
                renderStateLock.lock()
                cachedDetailTileBeforeLocked.removeAll()
                detailTileAfterLocked.removeAll()
                pendingDetailDeliveryKeys.removeAll()
                renderStateLock.unlock()
            }
            if let native = vm.viewportNativeSize, native.width > 0, native.height > 0 {
                guard ViewportNative.pyramidLevel(zoomScale: request.zoomScale, baseScale: request.baseScale) != nil else {
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
                let hitKeys = allSpecs.map(\.key).filter { tileCache.tiles[$0] != nil }
                if !hitKeys.isEmpty {
                    tileCache.touch(hitKeys)
                }
                let active = tileCache.activeTiles(allSpecs: allSpecs, visibleSpecs: visibleSpecs)
                if !detailTileListMatches(vm.detailTiles, active) {
                    vm.detailTiles = active
                    vm.detailOverlay = active.last
                }
                let needsBefore = detailNeedsBefore && vm.basePreviewImage != nil
                let missing = allSpecs.filter { spec in
                    guard let existing = tileCache.tiles[spec.key] else { return true }
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
        if let frameID = vm.acceptedPreviewFrameID {
            hdrDetailCache.removeAll { $0.renderID != frameID }
            if let hitIdx = hdrDetailCache.lastIndex(where: {
                $0.renderID == frameID &&
                ViewportNative.detailOverlayCovers(
                    $0,
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
                if !vm.detailTiles.isEmpty { vm.detailTiles = [] }
                if vm.detailOverlay?.renderID != hit.renderID ||
                   vm.detailOverlay?.normalizedRect != hit.normalizedRect ||
                   vm.detailOverlay?.pixelSize != hit.pixelSize {
                    vm.detailOverlay = hit
                }
                return
            }
        }
        scheduleDetailRender(for: request)
    }

    // MARK: - Tile Grid & Store Helpers

    private func tileSpecs(for request: PhotoDetailRequest?) -> (visible: [PhotoDetailTileSpec], all: [PhotoDetailTileSpec]) {
        guard let request, let native = viewModel?.viewportNativeSize, native.width > 0, native.height > 0 else {
            return ([], [])
        }
        let visible = ViewportNative.pyramidTiles(
            visibleRect: request.visibleRect,
            fullNativeSize: native,
            zoomScale: request.zoomScale,
            baseScale: request.baseScale,
            overscanRing: 0
        )
        let all = ViewportNative.pyramidTiles(
            visibleRect: request.visibleRect,
            fullNativeSize: native,
            zoomScale: request.zoomScale,
            baseScale: request.baseScale,
            overscanRing: 1
        )
        return (visible, all)
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

    private func storeDetailTile(_ overlay: PhotoDetailOverlay, keepKeys: Set<PhotoDetailTileKey>) {
        if tileCache.frameID != overlay.renderID {
            _ = tileCache.resetIfFrameChanged(overlay.renderID)
            renderStateLock.lock()
            cachedDetailTileBeforeLocked.removeAll()
            detailTileAfterLocked.removeAll()
            pendingDetailDeliveryKeys.removeAll()
            renderStateLock.unlock()
        }
        guard let key = overlay.tileKey else { return }
        let evictedKeys = tileCache.store(overlay, keepKeys: keepKeys)
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

    private func settingsHDRDetailLimit(_ request: PhotoDetailRequest) -> Int {
        (viewModel?.currentPreviewSettings.isHDREditing == true)
            ? min(1280, request.maxOutputLongEdge)
            : min(2048, request.maxOutputLongEdge)
    }

    private func makeNeutralSettings(from referenceSettings: RawSettings) -> RawSettings {
        var neutral = RawSettings.default
        neutral.geometrySettings = referenceSettings.geometrySettings
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
        lhs.geometry = lhs.geometrySettings
        rhs.geometry = rhs.geometrySettings
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
        self.resultDelivery { [weak self] in
            guard let self, let vm = self.viewModel, vm.sourceRevision == expectedSourceRevision else { return }
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

    // MARK: - Background Tile / Backing Worker

    private func ensureDetailWorkerRunning(for expectedFrameID: UUID) {
        guard let vm = viewModel,
              !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
              !vm.currentPreviewSettings.isHDREditing,
              vm.acceptedPreviewRequest?.quality == .final,
              vm.acceptedPreviewFrameID == expectedFrameID,
              let sourceFile = vm.sourceFile, let sourceKind = vm.sourceKind else {
            return
        }
        let expectedSourceRevision = vm.sourceRevision
        let settings = vm.currentPreviewSettings
        let referenceSettings = vm.committedPreviewSettings ?? settings
        let lutURL = vm.lutURL(for: settings)
        let draftBuffer = vm.draftBuffer
        var cachedFullRaster = self.fullRasterROIBuffer
        let hasReference = vm.basePreviewImage != nil
        let fallbackNative = vm.viewportNativeSize
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

        renderQueue.async { [weak self, weak vm] in
            guard let self, let vm else { return }
            defer {
                self.renderStateLock.lock()
                if self.detailRenderToken == token {
                    self.detailWorkerActive = false
                    self.detailWorkerFrameID = nil
                    self.inFlightDetailTileKey = nil
                }
                self.renderStateLock.unlock()
            }

            let frameCancelled = { [weak self, weak vm] () -> Bool in
                guard let self, let vm else { return true }
                return !self.isLatestDetailToken(token) || !vm.isLatestRenderID(expectedFrameID)
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
                let specs = ViewportNative.pyramidLevel0Grid(fullNativeSize: fullNativeSize)
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
                let canGpu = sourceFile.withReadAccess { url in
                    self.processor.supportsFastFullResGpu(
                        url: url,
                        settings: settings,
                        lutURL: lutURL,
                        nativeSize: fallbackSize,
                        maxPixels: metalMaxPixels
                    )
                }
                guard canGpu else { return false }

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

                    self.resultDelivery { [weak self, weak vm] in
                        guard let self else { return }
                        defer {
                            self.renderStateLock.lock()
                            for tile in tiles {
                                if let key = tile.tileKey, self.pendingDetailDeliveryKeys[key]?.seq == seq {
                                    self.pendingDetailDeliveryKeys.removeValue(forKey: key)
                                }
                            }
                            self.renderStateLock.unlock()
                        }
                        guard let vm,
                              !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                              vm.sourceRevision == expectedSourceRevision,
                              vm.acceptedPreviewFrameID == expectedFrameID else {
                            return
                        }
                        vm.detailBacking = backing
                        let currentAllSpecs = self.tileSpecs(for: self.lastDetailRequest)
                        let keepKeys = Set(currentAllSpecs.all.map(\.key))
                        for tile in tiles.reversed() {
                            self.storeDetailTile(tile, keepKeys: keepKeys)
                        }
                        if !currentAllSpecs.all.isEmpty {
                            self.tileCache.touch(currentAllSpecs.all.map(\.key))
                        }
                        if self.lastDetailRequest != nil {
                            let active = self.tileCache.activeTiles(allSpecs: currentAllSpecs.all, visibleSpecs: currentAllSpecs.visible)
                            if !self.detailTileListMatches(vm.detailTiles, active) {
                                vm.detailTiles = active
                            }
                            vm.detailOverlay = active.last ?? tiles.first
                        }
                        if self.detailNeedsBefore,
                           backing.beforeCGImage == nil,
                           vm.basePreviewImage != nil,
                           !vm.currentPreviewSettings.isHDREditing {
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

                    self.resultDelivery { [weak self, weak vm] in
                        guard let self else { return }
                        defer {
                            self.renderStateLock.lock()
                            if self.pendingDetailDeliveryKeys[spec.key]?.seq == seq {
                                self.pendingDetailDeliveryKeys.removeValue(forKey: spec.key)
                            }
                            self.renderStateLock.unlock()
                        }
                        guard let vm,
                              !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                              vm.sourceRevision == expectedSourceRevision,
                              vm.acceptedPreviewFrameID == expectedFrameID else {
                            return
                        }
                        let current = self.tileSpecs(for: self.lastDetailRequest)
                        self.storeDetailTile(tile, keepKeys: Set(current.all.map(\.key)))
                        guard self.lastDetailRequest != nil else { return }
                        let active = self.tileCache.activeTiles(allSpecs: current.all, visibleSpecs: current.visible)
                        if !self.detailTileListMatches(vm.detailTiles, active) {
                            vm.detailTiles = active
                        }
                        vm.detailOverlay = active.last ?? (trackInFlight ? tile : vm.detailOverlay)
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
                                self.resultDelivery { [weak vm] in
                                    guard let vm,
                                          !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                                          vm.sourceRevision == expectedSourceRevision,
                                          vm.acceptedPreviewFrameID == expectedFrameID,
                                          let current = vm.detailBacking,
                                          current.renderID == expectedFrameID,
                                          current.beforeCGImage == nil else {
                                        return
                                    }
                                    vm.detailBacking = PhotoDetailBacking(
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
                        self.resultDelivery { [weak vm] in
                            guard let vm,
                                  !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                                  vm.sourceRevision == expectedSourceRevision,
                                  vm.acceptedPreviewFrameID == expectedFrameID,
                                  let current = vm.detailBacking,
                                  current.renderID == expectedFrameID,
                                  current.beforeCGImage == nil else {
                                return
                            }
                            vm.detailBacking = PhotoDetailBacking(
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
                            prewarmCenterSpecs = ViewportNative.pyramidTiles(
                                visibleRect: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30),
                                fullNativeSize: out.nativeSize,
                                zoomScale: 1.0,
                                baseScale: CGFloat(backingEdge) / max(1, actualLong),
                                overscanRing: 0
                            )
                        }

                        self.resultDelivery { [weak self, weak vm] in
                            guard let self, let vm,
                                  !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                                  vm.sourceRevision == expectedSourceRevision,
                                  vm.acceptedPreviewFrameID == expectedFrameID else {
                                return
                            }
                            vm.detailBacking = backing
                            if self.detailNeedsBefore,
                               backing.beforeCGImage == nil,
                               vm.basePreviewImage != nil,
                               !vm.currentPreviewSettings.isHDREditing {
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
        guard let vm = viewModel,
              !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
              let sourceFile = vm.sourceFile, let sourceKind = vm.sourceKind,
              let expectedFrameID = vm.acceptedPreviewFrameID,
              vm.acceptedPreviewRequest?.quality == .final else {
            return
        }
        let token = UUID()
        setLatestDetailToken(token)
        detailDebounceWorkItem?.cancel()
        let expectedSourceRevision = vm.sourceRevision
        let settings = vm.currentPreviewSettings
        let referenceSettings = vm.committedPreviewSettings ?? settings
        let lutURL = settings.isHDREditing ? nil : vm.lutURL(for: settings)
        let draftBuffer = vm.draftBuffer
        var cachedFullRaster = self.fullRasterROIBuffer
        let baseHeadroom = vm.hdrPresentation?.statistics.headroom ?? 0
        let refHeadroom = vm.hdrReference?.statistics.headroom ?? 0
        let hasReference = vm.basePreviewImage != nil || vm.hdrReference != nil
        let fallbackNative = vm.viewportNativeSize
        let needsBefore = detailNeedsBefore

        let workItem = DispatchWorkItem { [weak self, weak vm] in
            guard let self, let vm else { return }
            if self.isLatestDetailToken(token) {
                self.detailDebounceWorkItem = nil
            }
            guard self.isLatestDetailToken(token),
                  !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                  vm.sourceRevision == expectedSourceRevision,
                  vm.acceptedPreviewFrameID == expectedFrameID else {
                return
            }
            self.renderQueue.async { [weak self, weak vm] in
                guard let self, let vm else { return }
                let cancelled = { [weak self, weak vm] () -> Bool in
                    guard let self, let vm else { return true }
                    return !self.isLatestDetailToken(token) || !vm.isLatestRenderID(expectedFrameID)
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
                    self.resultDelivery { [weak self, weak vm] in
                        guard let self, let vm,
                              self.isLatestDetailToken(token),
                              !vm.isBusy, !vm.previewRendering, !vm.previewResizePending,
                              vm.sourceRevision == expectedSourceRevision,
                              vm.acceptedPreviewFrameID == expectedFrameID else {
                            return
                        }
                        if !vm.detailTiles.isEmpty { vm.detailTiles = [] }
                        if overlay.hdr != nil {
                            self.storeHDRDetail(overlay)
                        }
                        vm.detailOverlay = overlay
                    }
                } catch {
                    // ROI errors, cancellation, or OOM degrade quietly to the base preview.
                }
            }
        }
        detailDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}
