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
        if !settings.isDenoiseEnabled { cancelViewportResize() }
        guard !missingFilm, !missingMasterRecipe else {
            result = nil
            error = missingMasterRecipe ? L10n.text("大师配方外观文件不可用。") : L10n.text("上次使用的外观不可用，请重新选择或导入外观。")
            return
        }
        let preview = geometryPreviewSettings
        let interactive = geometryDraft == nil && scheduler.interacting && !forceExact && preview.geometrySettings.isIdentity
        let effectiveLUT = settings.masterRecipe?.lutURL() ?? selectedFilm?.url
        let work = RenderWork(file: file, settings: preview, lut: effectiveLUT,
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
                if self.engine == nil { self.engine = try RenderEngine() }
                if self.originalCache?.file != work.file || self.originalCache?.processing != work.settings.processing {
                    self.originalCache = nil
                    self.geometryReferenceCache = nil
                    if let original = try self.engine!.render(work.file, settings: work.settings.neutralSettings, lut: nil, edge: nil) {
                        self.originalCache = (work.file, work.settings.processing, original)
                    }
                }
                let neutral: RenderedImage?
                if work.editingGeometry || work.settings.geometrySettings.isIdentity {
                    neutral = self.originalCache?.frame
                } else if let cached = self.geometryReferenceCache, cached.file == work.file,
                          cached.processing == work.settings.processing,
                          cached.geometry == work.settings.geometrySettings, cached.lens == work.settings.lensSettings {
                    neutral = cached.frame
                } else {
                    neutral = try self.engine!.render(work.file, settings: work.settings.neutralGeometrySettings,
                                                      lut: nil, edge: nil)
                    if let neutral {
                        self.geometryReferenceCache = (work.file, work.settings.processing, work.settings.geometrySettings, work.settings.lensSettings, neutral)
                    }
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
            guard sameFile, request.value.draftEpoch == geometryDraftEpoch,
                  !missingFilm, !missingMasterRecipe else { break }
            // 拖动仍可显示较早参数，但窗口尺寸变化后不能发布旧尺寸。
            if completion == .publishInteractive && request.value.edge != renderPreviewLongEdge { break }
            if let failure {
                if completion == .publishExact || scheduler.latest?.id == request.id {
                    self.result = nil
                    self.error = failure.localizedDescription
                }
            } else if let neutral, let result {
                let previousCanvas = geometryCanvasSize
                if !request.value.editingGeometry { pendingGeometryPresentation = nil }
                self.neutral = neutral
                self.result = result
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
