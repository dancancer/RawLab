import AppKit

extension EditorModel {
    var hslTargetActive: Bool {
        hslTargetEnabled && adjustmentNavigation.tool == .hsl && adjustmentNavigation.expandedGroup != nil &&
        geometryDraft == nil && pendingGeometryPresentation == nil && !exporting && adjustmentSheet == nil
    }
    var hslTargetRevision: HSLTargetRevision? {
        guard let accepted = hslAcceptedRequest, accepted.value.file == file else { return nil }
        return HSLTargetRevision(source: hslSourceRevision, request: UInt64(accepted.id))
    }
    func beginHSLTarget(_ point: CGPoint, keyDelta: Double? = nil) {
        guard hslTargetActive, ParameterValueField.commitPendingInputs(), !busy, !previewOutdated, let work = hslAcceptedRequest?.value,
              let revision = hslTargetRevision, settings == hslAcceptedSettings,
              work.source == file.map({ MacReferenceSource($0, raster: RenderEngine.isRasterInput($0)) }) else { hslTargetNotice = .stale; return }
        cancelHSLTarget()
        let before = settings, source = sourceRevision, axis = hslTargetAxis
        let token = hslTargetInteraction.begin(before: before.hslSettings, axis: axis, revision: revision)
        hslTargetPoint = point; hslTargetNotice = nil
        if let keyDelta { hslTargetInteraction.move(delta: keyDelta); hslTargetInteraction.end() }
        queue.async { [weak self] in
            guard let self else { return }
            let sample: HSLTargetSample
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                sample = try self.engine!.sampleHSL(work.file, settings: work.settings, lut: work.lut,
                    edge: work.edge, interactive: work.pass == .interactive, revision: revision, point: point)
            } catch {
                sample = HSLTargetSample(revision: revision, availability: .failed, rgb: [], weights: [], preview: true)
            }
            DispatchQueue.main.async {
                guard self.hslTargetInteraction.matches(token) else { return }
                guard self.sourceRevision == source, self.settings == before, self.hslTargetActive,
                      self.hslTargetAxis == axis else { self.cancelHSLTarget(); self.hslTargetNotice = .stale; return }
                let next = self.hslTargetInteraction.accept(sample, token: token, currentRevision: self.hslTargetRevision)
                guard let next else {
                    self.hslTargetNotice = self.hslTargetInteraction.selection == sample ? sample.availability : .stale
                    return
                }
                self.setInteracting(true)
                self.hslTargetHistoryActive = true
                self.settings.hsl = next.isIdentity ? nil : next
                if !self.hslTargetInteraction.isDragging { self.endHSLTarget() }
            }
        }
    }
    func moveHSLTarget(_ delta: Double) {
        guard hslTargetActive, let next = hslTargetInteraction.move(delta: delta), hslTargetHistoryActive else { return }
        settings.hsl = next.isIdentity ? nil : next
    }
    func endHSLTarget() {
        hslTargetInteraction.end()
        if hslTargetHistoryActive { hslTargetHistoryActive = false; setInteracting(false) }
    }
    func cancelHSLTarget() {
        hslTargetInteraction.cancel()
        hslTargetPoint = nil; hslTargetNotice = nil; hslPendingKeyDelta = 0
        if hslTargetHistoryActive { hslTargetHistoryActive = false; cancelAdjustmentInteraction() }
    }
    func keyHSLTarget(_ delta: Double) {
        guard !hslTargetInteraction.isDragging, let point = hslTargetPoint else { return }
        if hslTargetInteraction.isWaiting { hslTargetInteraction.accumulateReleased(delta: delta); return }
        if busy { hslPendingKeyDelta += delta; return }
        beginHSLTarget(point, keyDelta: delta)
    }
    func resumeHSLTargetKeys() {
        guard !busy, !previewOutdated, hslTargetActive, let point = hslTargetPoint,
              hslPendingKeyDelta != 0, !hslTargetInteraction.isDragging, !hslTargetInteraction.isWaiting else { return }
        let delta = hslPendingKeyDelta; hslPendingKeyDelta = 0
        beginHSLTarget(point, keyDelta: delta)
    }
    func rejectHSLTarget() { cancelHSLTarget(); hslTargetNotice = .outside }
}
