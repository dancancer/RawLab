import RawLabKit
import RawLabNative
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
              work.source == file.map(referenceSource) else { hslTargetNotice = .stale; return }
        cancelHSLTarget()
        let before = settings, source = sourceRevision, axis = hslTargetAxis
        let token = hslTargetInteraction.begin(before: before.editingHSLSettings, axis: axis, revision: revision)
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
                self.settings.editingHSLSettings = next
                if !self.hslTargetInteraction.isDragging { self.endHSLTarget() }
            }
        }
    }
    func moveHSLTarget(_ delta: Double) {
        guard hslTargetActive, let next = hslTargetInteraction.move(delta: delta), hslTargetHistoryActive else { return }
        settings.editingHSLSettings = next
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

    var curveTargetActive: Bool {
        curveTargetEnabled && adjustmentNavigation.tool == .toneCurve && adjustmentNavigation.expandedGroup != nil &&
        geometryDraft == nil && pendingGeometryPresentation == nil && !exporting && adjustmentSheet == nil
    }

    func beginCurveTarget(_ point: CGPoint, keyDelta: Double? = nil) {
        guard curveTargetActive, ParameterValueField.commitPendingInputs(), !busy, !previewOutdated,
              let work = hslAcceptedRequest?.value, let revision = hslTargetRevision, settings == hslAcceptedSettings,
              work.source == file.map(referenceSource) else { curveTargetNotice = .stale; return }
        cancelCurveTarget()
        let before = settings, source = sourceRevision, channel = curveTargetChannel
        let curve = before.editingCurveSettings
        let sampledCurve = curve.sampledPoints(channel: channel)
        let parametricEval: ((Double) -> Double)? = channel == .rgb && !curve.parametric.isIdentity
            ? { curve.sampledParametricValue(at: $0) }
            : nil
        let token = curveTargetInteraction.begin(
            before: curve,
            channel: channel,
            revision: revision,
            sampledCurve: sampledCurve,
            isHDR: before.isHDREditing,
            parametricEvaluator: parametricEval
        )
        curveTargetPoint = point; curveTargetNotice = nil
        if let keyDelta { curveTargetInteraction.move(delta: keyDelta); curveTargetInteraction.end() }
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
                guard self.curveTargetInteraction.matches(token) else { return }
                guard self.sourceRevision == source, self.settings == before, self.curveTargetActive,
                      self.curveTargetChannel == channel else { self.cancelCurveTarget(); self.curveTargetNotice = .stale; return }
                let next = self.curveTargetInteraction.accept(sample, token: token, currentRevision: self.hslTargetRevision)
                guard let next else {
                    self.curveTargetNotice = self.curveTargetInteraction.selection == sample ? sample.availability : .stale
                    return
                }
                self.setInteracting(true)
                self.curveTargetHistoryActive = true
                self.settings.editingCurveSettings = next
                if !self.curveTargetInteraction.isDragging { self.endCurveTarget() }
            }
        }
    }

    func moveCurveTarget(_ delta: Double) {
        guard curveTargetActive, let next = curveTargetInteraction.move(delta: delta), curveTargetHistoryActive else { return }
        settings.editingCurveSettings = next
    }

    func endCurveTarget() {
        curveTargetInteraction.end()
        if curveTargetHistoryActive { curveTargetHistoryActive = false; setInteracting(false) }
    }

    func cancelCurveTarget() {
        curveTargetInteraction.cancel()
        curveTargetPoint = nil; curveTargetNotice = nil; curvePendingKeyDelta = 0
        if curveTargetHistoryActive { curveTargetHistoryActive = false; cancelAdjustmentInteraction() }
    }

    func keyCurveTarget(_ delta: Double) {
        guard !curveTargetInteraction.isDragging, let point = curveTargetPoint else { return }
        if curveTargetInteraction.isWaiting { curveTargetInteraction.accumulateReleased(delta: delta); return }
        if busy { curvePendingKeyDelta += delta; return }
        beginCurveTarget(point, keyDelta: delta)
    }

    func resumeCurveTargetKeys() {
        guard !busy, !previewOutdated, curveTargetActive, let point = curveTargetPoint,
              curvePendingKeyDelta != 0, !curveTargetInteraction.isDragging, !curveTargetInteraction.isWaiting else { return }
        let delta = curvePendingKeyDelta; curvePendingKeyDelta = 0
        beginCurveTarget(point, keyDelta: delta)
    }

    func rejectCurveTarget() { cancelCurveTarget(); curveTargetNotice = .outside }
}
