import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension EditorModel {
    func setInteracting(_ value: Bool) {
        guard scheduler.interacting != value else { return }
        if value { beginAdjustmentInteraction() }
        scheduler.setInteracting(value)
        guard file != nil else { refreshBusy(); return }
        if geometryDraft != nil {
            // Focus and crop-only edits reuse the transformed canvas. Transform
            // updates schedule their own exact pass; ending a gesture flushes it.
            if !value && !geometryDraftPreviewReady { schedule(forceExact: true) }
            refreshBusy()
            return
        }
        if value { schedule() } else { finishAdjustmentInteraction(); schedule(forceExact: true) }
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
        if settings.activeAIDenoise && (aiState.isRunning || aiRequiresExplicitRetry) {
            scheduler.invalidatePending()
            previewOutdated = true
            refreshBusy()
            return
        }
        if !settings.isDenoiseEnabled { cancelViewportResize() }
        guard !missingFilm, !missingMasterRecipe else {
            previewOutdated = true
            error = missingMasterRecipe ? L10n.text("大师配方外观文件不可用。") : L10n.text("上次使用的外观不可用，请重新选择或导入外观。")
            invalidateEditedThumbnail(for: file)
            return
        }
        let preview = geometryPreviewSettings
        let interactive = geometryDraft == nil && scheduler.interacting && !forceExact && preview.geometrySettings.isIdentity
        let work = renderWork(file: file, preview: preview,
                              edge: interactive || !fullResolution ? renderPreviewLongEdge : nil,
                              pass: interactive ? .interactive : .exact)
        exactPreviewCache.useScope(work.previewScope)
        _ = scheduler.submit(work, fileID: file.standardizedFileURL.path, pass: work.pass)
        error = nil
        if interactive || exactPreviewCache.frames(for: work) != nil {
            // 拖动时由串行队列限流。命中精确帧时也可以直接发布。
            if !workerActive { launchNextRender() }
            else { refreshBusy() }
        } else {
            busy = true
            debounceTimer?.schedule(deadline: .now() + 0.15, repeating: .never, leeway: .milliseconds(5))
        }
    }

    func renderWork(file: URL, preview: Adjustments, edge: Int?, pass: RenderPass,
                    verifiedSource: MacReferenceSource? = nil) -> RenderWork {
        let effectiveLUT = settings.masterRecipe?.lutURL() ?? selectedFilm?.url
        let source = verifiedSource ?? referenceSource(file)
        let lookIdentity = effectiveLUT.flatMap { try? OriginalFileIdentity($0) }
        // AI 降噪仍需由原生层校验模型和磁盘缓存。
        let scope: MacExactPreviewCache.Scope? = geometryDraft == nil && !scheduler.interacting && !preview.activeAIDenoise &&
            (!preview.isHDREditing || preview.hdr?.missingResourceMessage == nil) &&
            source.modified != nil && source.size != nil && (effectiveLUT == nil || lookIdentity != nil)
            ? .init(source: source, editRevision: editRevision, look: lookIdentity) : nil
        return RenderWork(file: file, settings: preview, source: source, lut: effectiveLUT,
                          edge: edge, pass: pass,
                          draftEpoch: geometryDraftEpoch, editingGeometry: geometryDraft != nil, previewScope: scope)
    }

    func launchNextRender() {
        guard !workerActive, let request = scheduler.startNext() else {
            refreshBusy()
            return
        }
        workerActive = true
        let work = request.value
        if let cached = exactPreviewCache.frames(for: work) {
            finish(request, neutral: cached.neutral, result: cached.result, failure: nil)
            return
        }
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
                if work.settings.isHDREditing {
                    self.originalCache = nil
                    let neutralSettings = work.settings.neutralGeometrySettings
                    let neutralEdge = work.edge ?? 2000
                    let key = MacNeutralReferenceKey(source: work.source, settings: neutralSettings, edge: neutralEdge)
                    let neutral: RenderedImage?
                    if let cached = self.geometryReferenceCache, cached.key == key, cached.frame.hdr != nil {
                        neutral = cached.frame
                    } else {
                        neutral = try self.engine!.render(work.file, settings: neutralSettings, lut: nil, edge: neutralEdge)
                        self.geometryReferenceCache = neutral.map { (key, $0) }
                    }
                    var preview = work.settings
                    preview.hdr = work.settings.hdr?.previewSettings()
                    let result=try self.engine!.render(work.file,settings:preview,lut:nil,edge:work.edge,
                        interactive:work.pass == .interactive)
                    DispatchQueue.main.async { self.finish(request,neutral:neutral,result:result,failure:nil) }
                    return
                }
                // nil edge requests the immutable baseline; Q8 caps its long edge (never enlarges).
                let originalKey = MacNeutralReferenceKey(source: work.source, settings: work.settings.neutralSettings, edge: nil)
                if self.originalCache?.key != originalKey || self.originalCache?.frame.histogram.count != 3 {
                    self.originalCache = nil
                    self.geometryReferenceCache = nil
                    if let original = try self.engine!.render(work.file, settings: work.settings.neutralSettings, lut: nil, edge: nil,
                                                              referenceLongEdge: MacReferenceFramePolicy.longEdgeCap) {
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
                                                      lut: nil, edge: nil,
                                                      referenceLongEdge: MacReferenceFramePolicy.longEdgeCap)
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
        if failure == nil {
            acceptedOriginalSource = request.value.source
            if let neutral, let result {
                exactPreviewCache.store(neutral: neutral, result: result, for: request.value)
            }
        }
        let completion = scheduler.finish(request)
        let sameFile = request.value.file.standardizedFileURL == file?.standardizedFileURL
        switch completion {
        case .publishInteractive, .publishExact:
            if sameFile, request.value.source != file.map({ referenceSource($0) }) {
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
                    if self.committedEdit?.state == self.editState(settings: request.value.settings) {
                        self.invalidateEditedThumbnail(for: request.value.file)
                    }
                }
            } else if let neutral, let result {
                let previousCanvas = geometryCanvasSize
                if !request.value.editingGeometry { pendingGeometryPresentation = nil }
                self.neutral = neutral
                self.result = result
                if request.value.settings.isHDREditing { self.error = request.value.settings.hdr?.missingResourceMessage }
                if completion == .publishExact { previewOutdated = false }
                if request.value.settings.activeAIDenoise && !self.aiState.isRunning {
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
                if pendingSDRFallbackNotice {
                    pendingSDRFallbackNotice = false
                    saveStatusKey = "此照片的 HDR 需 macOS 15 才能编辑，已按 SDR 打开。"
                    clearSaveStatusLater()
                }
                if !request.value.settings.isHDREditing {
                    updatingMetadata = true
                    settings.resolveWhiteBalance(result.asShotWhiteBalance)
                    settings.resolveRawNoiseReductionSupport(result.supportsRawNoiseReduction)
                    updatingMetadata = false
                }
                if completion == .publishExact, !request.value.editingGeometry,
                   let committedEdit, isRecordModified(committedEdit),
                   committedEdit.state == editState(settings: request.value.settings),
                   request.value.lut == nil || request.value.previewScope?.look == request.value.lut.flatMap({ try? OriginalFileIdentity($0) }) {
                    completedEditPreview = (committedEdit, result.image)
                }
                hslAcceptedRequest = request
                hslAcceptedSettings = settings
                if completion == .publishInteractive {
                    statusState = .interactive(result.image.width, result.image.height)
                } else {
                    statusState = .preview(result.image.width, result.image.height, original: result.isFullResolution)
                }
            }
        case .discard, .ignored:
            break
        }
        launchNextRender()
        refreshBusy()
        startProcessingMigrationIfNeeded()
    }

    func refreshBusy() {
        busy = workerActive || scheduler.isBusy || viewportResizeWork != nil
        resumeHSLTargetKeys()
    }
}

struct MacExactPreviewCache {
    struct Scope: Equatable {
        let source: MacReferenceSource
        let editRevision: UUID
        let look: OriginalFileIdentity?
    }

    private var scope: Scope?
    private var entries: [(edge: Int?, neutral: RenderedImage, result: RenderedImage, bytes: Int)] = []
    private static let budget = 512 * 1024 * 1024

    mutating func useScope(_ scope: Scope?) {
        guard self.scope != scope else { return }
        self.scope = scope
        entries.removeAll()
    }

    func frames(for work: EditorModel.RenderWork) -> (neutral: RenderedImage, result: RenderedImage)? {
        guard work.pass == .exact, scope != nil, work.previewScope == scope,
              let entry = entries.first(where: { $0.edge == work.edge }) else { return nil }
        return (entry.neutral, entry.result)
    }

    mutating func store(neutral: RenderedImage, result: RenderedImage, for work: EditorModel.RenderWork) {
        guard work.pass == .exact, scope != nil, work.previewScope == scope,
              (result.hdr != nil || result.histogram.count == 3),
              (neutral.hdr != nil || neutral.histogram.count == 3) else { return }
        // Q8：SDR 对照帧已按长边上限封顶，这里按封顶后的实际尺寸计入本预算
        // （同一基准帧被多条缓存项共享时按条计费，预算偏保守）。
        let bytes = Self.bytes(result) + Self.bytes(neutral)
        guard bytes <= Self.budget else { return }
        entries.removeAll { $0.edge == work.edge }
        while entries.count >= 3 || entries.reduce(bytes, { $0 + $1.bytes }) > Self.budget {
            entries.removeFirst()
        }
        entries.append((work.edge, neutral, result, bytes))
    }

    /// 预算核算视角：当前缓存实际计费的字节数（含封顶后的参考帧尺寸）。
    var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    static func bytes(_ frame: RenderedImage) -> Int {
        let mask = frame.clipping.map { $0.bytesPerRow * $0.height } ?? 0
        return frame.image.bytesPerRow * frame.image.height + mask + (frame.hdr?.image.byteCount ?? 0)
    }
}
