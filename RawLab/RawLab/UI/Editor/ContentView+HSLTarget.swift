import SwiftUI

extension ContentView {
    var hslTargetActive: Bool {
        hslTargetEnabled && selectedAdjustment == .hsl && !isEditorDraftActive &&
        !editorBusy && adjustmentSheet == nil && !draftExitPresented && !resetConfirmationPresented
    }
    var hslTargetInput: HSLTargetCanvasInput {
        let source = viewModel.sourceRevision, axis = hslTargetAxis
        func current() -> Bool { viewModel.sourceRevision == source && hslTargetAxis == axis }
        return HSLTargetCanvasInput(scope: "\(source)-\(axis.rawValue)",
            begin: { if current() { beginHSLTarget($0) } }, change: { if current() { moveHSLTarget($0) } },
            end: { if current() { endHSLTarget() } }, cancel: { if current() { cancelHSLTarget() } },
            key: { if current() { keyHSLTarget($0) } }, reject: { if current() { cancelHSLTarget(); hslTargetNotice = .outside } })
    }
    func beginHSLTarget(_ point: CGPoint, keyDelta: Double? = nil) {
        cancelHSLTarget()
        guard hslTargetActive, let revision = viewModel.hslTargetRevision else { hslTargetNotice = .stale; return }
        let before = settings, source = viewModel.sourceRevision, axis = hslTargetAxis
        let token = hslTargetInteraction.begin(before: before.hsl, axis: axis, revision: revision)
        hslTargetPoint = point
        if let keyDelta { hslTargetInteraction.move(delta: keyDelta); hslTargetInteraction.end() }
        viewModel.sampleHSL(point: point, settings: before, revision: revision) { sample in
            guard hslTargetInteraction.matches(token) else { return }
            guard viewModel.sourceRevision == source, settings == before, hslTargetActive, hslTargetAxis == axis else {
                cancelHSLTarget(); hslTargetNotice = .stale; return
            }
            guard let next = hslTargetInteraction.accept(sample, token: token, currentRevision: viewModel.hslTargetRevision) else {
                hslTargetNotice = hslTargetInteraction.selection == sample ? sample.availability : .stale; return
            }
            setSliderEditing(true)
            guard viewModel.adjustmentInteraction != nil, !viewModel.adjustmentInteractionRejected else {
                cancelHSLTarget(); hslTargetNotice = .failed; return
            }
            hslTargetHistoryActive = true
            settings.hsl = next
            if !hslTargetInteraction.isDragging { endHSLTarget() }
        }
    }
    func moveHSLTarget(_ delta: Double) {
        guard hslTargetActive, let next = hslTargetInteraction.move(delta: delta), hslTargetHistoryActive else { return }
        settings.hsl = next
    }
    func endHSLTarget() {
        hslTargetInteraction.end()
        if hslTargetHistoryActive { hslTargetHistoryActive = false; setSliderEditing(false) }
    }
    func cancelHSLTarget() {
        hslTargetInteraction.cancel(); hslTargetPoint = nil; hslTargetNotice = nil
        if hslTargetHistoryActive { hslTargetHistoryActive = false; cancelSliderInteraction() }
    }
    func keyHSLTarget(_ delta: Double) {
        guard !hslTargetInteraction.isDragging, let point = hslTargetPoint else { return }
        if hslTargetInteraction.isWaiting { hslTargetInteraction.accumulateReleased(delta: delta); return }
        beginHSLTarget(point, keyDelta: delta)
    }
}
