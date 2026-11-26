import RawLabKit
import RawLabNative
import SwiftUI

extension ContentView {
    var hslTargetActive: Bool { coordinator.hslTargetActive }

    var hslTargetInput: HSLTargetCanvasInput {
        let source = viewModel.sourceRevision, draftID = workspaceDraftID, axis = coordinator.hslTargetAxis, hdr = workingSettings.isHDREditing
        func current() -> Bool {
            viewModel.sourceRevision == source && workspaceDraftID == draftID &&
                coordinator.hslTargetAxis == axis && workingSettings.isHDREditing == hdr
        }
        return HSLTargetCanvasInput(scope: "\(source)-\(draftID)-\(axis.rawValue)-\(hdr)",
            begin: { if current() { beginHSLTarget($0) } }, change: { if current() { moveHSLTarget($0) } },
            end: { if current() { endHSLTarget() } }, cancel: { if current() { cancelHSLTarget() } },
            key: { if current() { keyHSLTarget($0) } }, reject: { if current() { cancelHSLTarget(); coordinator.hslTargetNotice = .outside } })
    }

    func beginHSLTarget(_ point: CGPoint, keyDelta: Double? = nil) {
        cancelHSLTarget()
        guard hslTargetActive, let revision = viewModel.hslTargetRevision else { coordinator.hslTargetNotice = .stale; return }
        let before = workingSettings, source = viewModel.sourceRevision, draftID = workspaceDraftID, axis = coordinator.hslTargetAxis
        let token = coordinator.hslTargetInteraction.begin(before: before.editingHSLSettings, axis: axis, revision: revision)
        coordinator.hslTargetPoint = point
        if let keyDelta {
            coordinator.hslTargetInteraction.move(delta: keyDelta)
            coordinator.hslTargetInteraction.end()
        }
        viewModel.sampleHSL(point: point, settings: before, revision: revision) { sample in
            guard coordinator.hslTargetInteraction.matches(token) else { return }
            guard viewModel.sourceRevision == source, workspaceDraftID == draftID, workingSettings == before,
                  hslTargetActive, coordinator.hslTargetAxis == axis else {
                cancelHSLTarget(); coordinator.hslTargetNotice = .stale; return
            }
            guard let next = coordinator.hslTargetInteraction.accept(sample, token: token, currentRevision: viewModel.hslTargetRevision) else {
                coordinator.hslTargetNotice = coordinator.hslTargetInteraction.selection == sample ? sample.availability : .stale
                return
            }
            setSliderEditing(true)
            guard workspaceDraft != nil || (viewModel.adjustmentInteraction != nil && !viewModel.adjustmentInteractionRejected) else {
                cancelHSLTarget(); coordinator.hslTargetNotice = .failed; return
            }
            coordinator.hslTargetHistoryActive = true
            workingSettings.editingHSLSettings = next
            if !coordinator.hslTargetInteraction.isDragging { endHSLTarget() }
        }
    }

    func moveHSLTarget(_ delta: Double) {
        guard hslTargetActive, let next = coordinator.hslTargetInteraction.move(delta: delta),
              coordinator.hslTargetHistoryActive else { return }
        workingSettings.editingHSLSettings = next
    }

    func endHSLTarget() {
        coordinator.hslTargetInteraction.end()
        if coordinator.hslTargetHistoryActive {
            coordinator.hslTargetHistoryActive = false
            setSliderEditing(false)
        }
    }

    func cancelHSLTarget() { coordinator.cancelHSLTarget() }

    func keyHSLTarget(_ delta: Double) {
        guard !coordinator.hslTargetInteraction.isDragging, let point = coordinator.hslTargetPoint else { return }
        if coordinator.hslTargetInteraction.isWaiting {
            coordinator.hslTargetInteraction.accumulateReleased(delta: delta)
            return
        }
        beginHSLTarget(point, keyDelta: delta)
    }

    var curveTargetActive: Bool { coordinator.curveTargetActive }

    var curveTargetInput: HSLTargetCanvasInput {
        let source = viewModel.sourceRevision, draftID = workspaceDraftID, channel = coordinator.curveTargetChannel, hdr = workingSettings.isHDREditing
        func current() -> Bool {
            viewModel.sourceRevision == source && workspaceDraftID == draftID &&
                coordinator.curveTargetChannel == channel && workingSettings.isHDREditing == hdr
        }
        return HSLTargetCanvasInput(scope: "curve-\(source)-\(draftID)-\(channel.rawValue)-\(hdr)",
            begin: { if current() { beginCurveTarget($0) } }, change: { if current() { moveCurveTarget($0) } },
            end: { if current() { endCurveTarget() } }, cancel: { if current() { cancelCurveTarget() } },
            key: { if current() { keyCurveTarget($0) } }, reject: { if current() { cancelCurveTarget(); coordinator.curveTargetNotice = .outside } })
    }

    func beginCurveTarget(_ point: CGPoint, keyDelta: Double? = nil) {
        cancelCurveTarget()
        guard curveTargetActive, let revision = viewModel.hslTargetRevision else { coordinator.curveTargetNotice = .stale; return }
        let before = workingSettings, source = viewModel.sourceRevision, draftID = workspaceDraftID, channel = coordinator.curveTargetChannel
        let curve = before.editingCurveSettings
        let sampledCurve = curve.sampledPoints(channel: channel)
        let parametricEval: ((Double) -> Double)? = channel == .rgb && !curve.parametric.isIdentity
            ? { curve.sampledParametricValue(at: $0) }
            : nil
        let token = coordinator.curveTargetInteraction.begin(
            before: curve,
            channel: channel,
            revision: revision,
            sampledCurve: sampledCurve,
            isHDR: before.isHDREditing,
            parametricEvaluator: parametricEval
        )
        coordinator.curveTargetPoint = point
        if let keyDelta {
            coordinator.curveTargetInteraction.move(delta: keyDelta)
            coordinator.curveTargetInteraction.end()
        }
        viewModel.sampleHSL(point: point, settings: before, revision: revision) { sample in
            guard coordinator.curveTargetInteraction.matches(token) else { return }
            guard viewModel.sourceRevision == source, workspaceDraftID == draftID, workingSettings == before,
                  curveTargetActive, coordinator.curveTargetChannel == channel else {
                cancelCurveTarget(); coordinator.curveTargetNotice = .stale; return
            }
            guard let next = coordinator.curveTargetInteraction.accept(sample, token: token, currentRevision: viewModel.hslTargetRevision) else {
                coordinator.curveTargetNotice = coordinator.curveTargetInteraction.selection == sample ? sample.availability : .stale
                return
            }
            setSliderEditing(true)
            guard workspaceDraft != nil || (viewModel.adjustmentInteraction != nil && !viewModel.adjustmentInteractionRejected) else {
                cancelCurveTarget(); coordinator.curveTargetNotice = .failed; return
            }
            coordinator.curveTargetHistoryActive = true
            workingSettings.editingCurveSettings = next
            if !coordinator.curveTargetInteraction.isDragging { endCurveTarget() }
        }
    }

    func moveCurveTarget(_ delta: Double) {
        guard curveTargetActive, let next = coordinator.curveTargetInteraction.move(delta: delta),
              coordinator.curveTargetHistoryActive else { return }
        workingSettings.editingCurveSettings = next
    }

    func endCurveTarget() {
        coordinator.curveTargetInteraction.end()
        if coordinator.curveTargetHistoryActive {
            coordinator.curveTargetHistoryActive = false
            setSliderEditing(false)
        }
    }

    func cancelCurveTarget() { coordinator.cancelCurveTarget() }

    func keyCurveTarget(_ delta: Double) {
        guard !coordinator.curveTargetInteraction.isDragging, let point = coordinator.curveTargetPoint else { return }
        if coordinator.curveTargetInteraction.isWaiting {
            coordinator.curveTargetInteraction.accumulateReleased(delta: delta)
            return
        }
        beginCurveTarget(point, keyDelta: delta)
    }

    var wbProbeActive: Bool { coordinator.wbProbeActive }

    var wbProbeInput: HSLTargetCanvasInput {
        let source = viewModel.sourceRevision, draftID = workspaceDraftID, hdr = workingSettings.isHDREditing
        func current() -> Bool {
            viewModel.sourceRevision == source && workspaceDraftID == draftID && workingSettings.isHDREditing == hdr
        }
        return HSLTargetCanvasInput(scope: "wb-\(source)-\(draftID)-\(hdr)",
            begin: { if current() { beginWBProbe($0) } }, change: { _ in },
            end: {}, cancel: { if current() { cancelWBProbe() } },
            key: { _ in }, reject: { if current() { coordinator.wbProbeNotice = .outside } })
    }

    func beginWBProbe(_ point: CGPoint) {
        guard wbProbeActive else { coordinator.wbProbeNotice = .stale; return }
        let before = workingSettings, source = viewModel.sourceRevision, draftID = workspaceDraftID
        let isRaster = viewModel.sourceKind == .raster
        coordinator.wbProbeSampling = true
        coordinator.wbProbeNotice = nil
        viewModel.sampleWBProbe(point: point, settings: before) { outcome in
            coordinator.wbProbeSampling = false
            guard viewModel.sourceRevision == source, workspaceDraftID == draftID,
                  workingSettings == before, wbProbeActive else {
                coordinator.wbProbeNotice = .stale
                return
            }
            switch outcome.availability {
            case SONY2FUJI_WB_PROBE_AVAILABLE:
                coordinator.wbProbeNotice = nil
                setSliderEditing(true)
                var updated = before
                if !isRaster { updated.whiteBalanceMode = .custom }
                else { updated.whiteBalanceMode = .camera }
                updated.temperature = outcome.temperature
                updated.tint = outcome.tint
                applySettingsChange(updated)
                setSliderEditing(false)
            case SONY2FUJI_WB_PROBE_OVEREXPOSED:
                coordinator.wbProbeNotice = .overexposed
            case SONY2FUJI_WB_PROBE_OUTSIDE:
                coordinator.wbProbeNotice = .outside
            default:
                coordinator.wbProbeNotice = .unavailable
            }
        }
    }

    func cancelWBProbe() {
        coordinator.wbProbeSampling = false
        coordinator.wbProbeNotice = nil
    }

    var pointColorEyedropperActive: Bool { coordinator.pointColorEyedropperActive }

    var pointColorEyedropperInput: HSLTargetCanvasInput {
        let source = viewModel.sourceRevision, draftID = workspaceDraftID, hdr = workingSettings.isHDREditing
        func current() -> Bool {
            viewModel.sourceRevision == source && workspaceDraftID == draftID && workingSettings.isHDREditing == hdr
        }
        return HSLTargetCanvasInput(scope: "pointColor-\(source)-\(draftID)-\(hdr)",
            begin: { if current() { samplePointColor(atOutputPoint: $0) } }, change: { _ in },
            end: {}, cancel: { if current() { coordinator.pointColorEyedropperEnabled = false } },
            key: { _ in }, reject: { if current() { coordinator.pointColorEyedropperEnabled = false } })
    }

    func samplePointColor(atOutputPoint point: CGPoint) {
        guard pointColorEyedropperActive else { return }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              let sample = sampleInspectionAfter(atOutputPoint: point) else {
            coordinator.pointColorEyedropperEnabled = false
            return
        }
        let swatch = PointColorSwatch.fromSample(sample)
        var updated = workingSettings
        var pc = updated.pointColorSettings
        let maxSwatches = AdjustmentFieldSpec.SubFields.PointColor.maxSwatches
        if pc.swatches.count < maxSwatches {
            pc.swatches.append(swatch)
            coordinator.selectedPointColorSwatchIndex = pc.swatches.count - 1
        } else {
            let targetIndex = min(max(coordinator.selectedPointColorSwatchIndex, 0), maxSwatches - 1)
            pc.swatches[targetIndex] = swatch
            coordinator.selectedPointColorSwatchIndex = targetIndex
        }
        updated.pointColorSettings = pc
        setSliderEditing(true)
        applySettingsChange(updated)
        setSliderEditing(false)
        coordinator.pointColorEyedropperEnabled = false
    }
}
