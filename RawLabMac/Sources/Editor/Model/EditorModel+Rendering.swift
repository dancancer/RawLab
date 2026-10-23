import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension EditorModel {
    func setInteracting(_ value: Bool) {
        guard scheduler.interacting != value else { return }
        scheduler.setInteracting(value)
        guard file != nil else { refreshBusy(); return }
        if geometryDraft != nil {
            // Focus and crop-only edits reuse the transformed canvas. Transform
            // updates schedule their own exact pass; ending a gesture flushes it.
            if !value && !geometryDraftPreviewReady { schedule(forceExact: true) }
            refreshBusy()
            return
        }
        if value { schedule() } else { schedule(forceExact: true) }
    }
    func schedule() {
        schedule(forceExact: false)
    }
    func updatePreviewLongEdge(_ edge: Int) {
        let edge = min(65535, max(1, edge))
        guard previewLongEdge != edge else { return }
        previewLongEdge = edge
        viewportResizeWork?.cancel()
        viewportResizeWork = nil
        let holdProxy = settings.isDenoiseEnabled && result?.isFullResolution == false && !fullResolution
        if holdProxy {
            // 连续改变布局时沿用当前降噪尺度，停稳后只计算最后一个尺寸。
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.viewportResizeWork = nil
                self.renderPreviewLongEdge = self.previewLongEdge
                self.schedule()
                self.refreshBusy()
            }
            viewportResizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            refreshBusy()
        } else {
            renderPreviewLongEdge = edge
            if !fullResolution || scheduler.interacting { schedule() }
        }
    }
    func cancelViewportResize() {
        viewportResizeWork?.cancel()
        viewportResizeWork = nil
        renderPreviewLongEdge = previewLongEdge
    }
    func schedule(forceExact: Bool) {
        guard let file else { return }
        synchronizeAI()
        if settings.aiDenoiseEnabled && (aiState.isRunning || aiRequiresExplicitRetry) {
            scheduler.invalidatePending()
            previewOutdated = true
            refreshBusy()
            return
        }
        if !settings.isDenoiseEnabled { cancelViewportResize() }
        guard !missingFilm, !missingMasterRecipe else {
            previewOutdated = true
            error = missingMasterRecipe ? L10n.text("大师配方外观文件不可用。") : L10n.text("上次使用的外观不可用，请重新选择或导入外观。")
            return
        }
        let preview = geometryPreviewSettings
        let interactive = geometryDraft == nil && scheduler.interacting && !forceExact && preview.geometrySettings.isIdentity
        let effectiveLUT = settings.masterRecipe?.lutURL() ?? selectedFilm?.url
        let work = RenderWork(file: file, settings: preview, source: MacReferenceSource(file, raster: RenderEngine.isRasterInput(file)), lut: effectiveLUT,
                              edge: interactive || !fullResolution ? renderPreviewLongEdge : nil,
                              pass: interactive ? .interactive : .exact,
                              draftEpoch: geometryDraftEpoch, editingGeometry: geometryDraft != nil)
        _ = scheduler.submit(work, fileID: file.standardizedFileURL.path, pass: work.pass)
        busy = true
        error = nil
        if interactive {
            // The serial worker is the throttle while dragging. Start the first
            // preview immediately; later slider events only replace `pending`.
            if !workerActive { launchNextRender() }
        } else {
            debounceTimer?.schedule(deadline: .now() + 0.15, repeating: .never, leeway: .milliseconds(5))
        }
    }

    func launchNextRender() {
        guard !workerActive, let request = scheduler.startNext() else {
            refreshBusy()
            return
        }
        workerActive = true
        let work = request.value
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if let previous = self.originalCache?.key.source,
                   previous.url == work.source.url, previous != work.source {
                    // The core RAW cache omits inode. A same-path replacement must
                    // cross a client session boundary even when size/mtime agree.
                    self.engine = try RenderEngine()
                }
                if self.engine == nil { self.engine = try RenderEngine() }
                // nil edge explicitly requests the existing immutable full-native baseline.
                let originalKey = MacNeutralReferenceKey(source: work.source, settings: work.settings.neutralSettings, edge: nil)
                if self.originalCache?.key != originalKey || self.originalCache?.frame.histogram.count != 3 {
                    self.originalCache = nil
                    self.geometryReferenceCache = nil
                    if let original = try self.engine!.render(work.file, settings: work.settings.neutralSettings, lut: nil, edge: nil) {
                        self.originalCache = (originalKey, original)
                    }
                }
                let neutral: RenderedImage?
                let key = MacNeutralReferenceKey(source: work.source, settings: work.settings, edge: work.edge)
                if work.editingGeometry || key.usesOriginal {
                    neutral = self.originalCache?.frame
                } else if let cached = self.geometryReferenceCache, cached.frame.histogram.count == 3,
                          cached.key.canServe(key, fullResolution: cached.frame.isFullResolution) {
                    neutral = cached.frame
                    self.geometryReferenceCache = (key, cached.frame)
                } else {
                    neutral = try self.engine!.render(work.file, settings: work.settings.neutralGeometrySettings,
                                                      lut: nil, edge: nil)
                    if let neutral { self.geometryReferenceCache = (key, neutral) }
                }
                let result = try self.engine!.render(work.file, settings: work.settings, lut: work.lut,
                                                     edge: work.edge, output: nil,
                                                     interactive: work.pass == .interactive,
                                                     viewportPreview: work.edge != nil)
                DispatchQueue.main.async {
                    self.finish(request, neutral: neutral, result: result, failure: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finish(request, neutral: nil, result: nil, failure: error)
                }
            }
        }
        refreshBusy()
    }

    private func finish(_ request: RenderRequest<RenderWork>, neutral: RenderedImage?, result: RenderedImage?, failure: Error?) {
        workerActive = false
        let completion = scheduler.finish(request)
        let sameFile = request.value.file.standardizedFileURL == file?.standardizedFileURL
        switch completion {
        case .publishInteractive, .publishExact:
            if sameFile, request.value.source != file.map({ MacReferenceSource($0, raster: RenderEngine.isRasterInput($0)) }) {
                if scheduler.latest?.id == request.id {
                    previewOutdated = true; error = L10n.text("预览未更新")
                }
                break
            }
            guard sameFile, request.value.draftEpoch == geometryDraftEpoch,
                  !missingFilm, !missingMasterRecipe else { break }
            // 拖动仍可显示较早参数，但窗口尺寸变化后不能发布旧尺寸。
            if completion == .publishInteractive && request.value.edge != renderPreviewLongEdge { break }
            if let failure {
                if completion == .publishExact || scheduler.latest?.id == request.id {
                    self.previewOutdated = true
                    self.error = failure.localizedDescription
                    self.handleAIFailure(failure)
                }
            } else if let neutral, let result {
                let previousCanvas = geometryCanvasSize
                if !request.value.editingGeometry { pendingGeometryPresentation = nil }
                self.neutral = neutral
                self.result = result
                if completion == .publishExact { previewOutdated = false }
                if request.value.settings.aiDenoiseEnabled && !self.aiState.isRunning {
                    self.aiState = .ready
                    self.aiIdentity = try? AIWorkIdentity(request.value.file, settings: request.value.settings)
                }
                if let draft = geometryDraft,
                   request.value.settings.geometrySettings == draft.previewGeometry,
                   request.value.settings.lensSettings == draft.lens {
                    // A new orientation/perspective/lens canvas can change its
                    // physical aspect. Keep the user's chosen ratio in that canvas.
                    if previousCanvas != geometryCanvasSize, let ratio = cropAspectRatio {
                        let rect = CropInteraction.dragging(CropInteraction.rect(from: draft.geometry), handle: .bottomRight,
                            translation: .zero, canvasSize: geometryCanvasSize, ratio: ratio)
                        updateGeometryDraft { $0 = CropInteraction.applying(rect: rect, to: $0) }
                    }
                    geometryDraftPreviewReady = true
                }
                if pendingImportEvent {
                    pendingImportEvent = false
                    onUsage(.photoImported)
                }
                updatingMetadata = true
                settings.resolveWhiteBalance(result.asShotWhiteBalance)
                settings.resolveRawNoiseReductionSupport(result.supportsRawNoiseReduction)
                updatingMetadata = false
                if completion == .publishInteractive {
                    statusState = .interactive(result.image.width, result.image.height)
                } else {
                    statusState = .preview(result.image.width, result.image.height, original: request.value.edge == nil)
                }
            }
        case .discard, .ignored:
            break
        }
        launchNextRender()
        refreshBusy()
    }

    func refreshBusy() {
        busy = workerActive || scheduler.isBusy || viewportResizeWork != nil
    }
}
