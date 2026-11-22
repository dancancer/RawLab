import RawLabKit
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
}
