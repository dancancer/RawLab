import SwiftUI
import UIKit

enum EditorToolSelection: Hashable {
    case adjustment(AdjustmentKind)
    case film, recipe, lens, geometry
}

enum RulerFocusPhase: Equatable {
    case idle, dragging, holding, restoring
}

extension ContentView {
    var effectivePreviewSettings: RawSettings {
        var result = settings
        if let lensDraft { result.lensCorrection = lensDraft.lensCorrection }
        if let geometryDraft { result.geometry = geometryDraft }
        return result
    }

    var draftPreviewSettings: RawSettings {
        var result = effectivePreviewSettings
        if geometrySelected {
            result.geometry.cropX = 0
            result.geometry.cropY = 0
            result.geometry.cropWidth = 1
            result.geometry.cropHeight = 1
        }
        return result
    }

    var geometryDraftBinding: Binding<GeometrySettings> {
        let sourceRevision = viewModel.sourceRevision
        return Binding(get: { geometryDraft ?? settings.geometry }, set: { value in
            guard !editorBusy, geometrySelected, viewModel.sourceRevision == sourceRevision else { return }
            geometryDraft = value
        })
    }

    var lensDraftBinding: Binding<RawSettings> {
        let sourceRevision = viewModel.sourceRevision
        return Binding(get: { lensDraft ?? settings }, set: { value in
            guard !editorBusy, lensSelected, viewModel.sourceRevision == sourceRevision else { return }
            lensDraft = value
        })
    }

    var isEditorDraftActive: Bool { geometrySelected || lensSelected }

    var isEditorDraftChanged: Bool {
        geometryDraft.map { $0 != settings.geometry } ?? lensDraft.map { $0.lensSettings != settings.lensSettings } ?? false
    }

    var rulerFocusOpacity: Double {
        guard rulerFocusPhase == .dragging || rulerFocusPhase == .holding else { return 1 }
        return UIDevice.current.userInterfaceIdiom == .pad ? 0.42 : 0.08
    }

    func selectEditorTool(_ selection: EditorToolSelection) {
        guard !editorBusy, selection != currentEditorTool else { return }
        if isEditorDraftChanged {
            pendingToolSelection = selection
            draftExitPresented = true
            return
        }
        activateEditorTool(selection)
    }

    var currentEditorTool: EditorToolSelection {
        if geometrySelected { return .geometry }
        if lensSelected { return .lens }
        if choosingMasterRecipe { return .recipe }
        return selectedAdjustment.map(EditorToolSelection.adjustment) ?? .film
    }

    private func activateEditorTool(_ selection: EditorToolSelection) {
        let leavingDraft = geometrySelected || lensSelected
        cancelRulerFocus()
        geometryDraft = nil
        lensDraft = nil
        geometrySelected = selection == .geometry
        lensSelected = selection == .lens
        choosingMasterRecipe = selection == .recipe
        if case .adjustment(let adjustment) = selection { selectedAdjustment = adjustment }
        else { selectedAdjustment = nil }
        if geometrySelected { geometryAspectPreset = .free; geometryDraft = settings.geometry }
        if lensSelected { lensDraft = settings }
        if leavingDraft && !geometrySelected && !lensSelected {
            viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
        }
    }

    func applyEditorDraft() {
        commitEditorDraft()
        activateEditorTool(.adjustment(.exposure))
    }

    private func commitEditorDraft() {
        settings = effectivePreviewSettings
        if geometrySelected { geometryDraft = settings.geometry }
        if lensSelected { lensDraft = settings }
        cancelRulerFocus()
    }

    func cancelEditorDraft() {
        discardEditorDraft()
        activateEditorTool(.adjustment(.exposure))
    }

    private func discardEditorDraft() {
        if geometrySelected { geometryDraft = settings.geometry }
        if lensSelected { lensDraft = settings }
        cancelRulerFocus()
        viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
    }

    func finishDraftNavigation(apply: Bool) {
        if apply { commitEditorDraft() } else { discardEditorDraft() }
        if let selection = pendingToolSelection { activateEditorTool(selection) }
        pendingToolSelection = nil
    }

    func previewEditorDraft() {
        guard !editorBusy, viewModel.hasImage else { return }
        showingBefore = false
        if isAdjustingSlider {
            viewModel.schedulePreviewUpdate(settings: draftPreviewSettings, delay: 0.08,
                                           includeHistogram: false, quality: .interactive)
        } else {
            viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
        }
    }

    func selectedScalarBadge(_ adjustment: AdjustmentKind) -> String? {
        guard selectedAdjustment == adjustment, !geometrySelected, !lensSelected else { return nil }
        return adjustment.badge(for: adjustment.value(from: settings))
    }

    // MARK: - Interruptible focus return

    func updateRulerFocus(editing: Bool, wasEditing: Bool) {
        rulerFocusTask?.cancel()
        if editing {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { rulerFocusPhase = .dragging }
            return
        }
        guard wasEditing, !reduceMotion else { rulerFocusPhase = .idle; return }
        rulerFocusPhase = .holding
        rulerFocusTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            withAnimation(.easeOut(duration: 0.18)) { rulerFocusPhase = .restoring }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            rulerFocusPhase = .idle
        }
    }

    func cancelRulerFocus() {
        rulerFocusTask?.cancel()
        rulerFocusTask = nil
        rulerFocusPhase = .idle
        isAdjustingSlider = false
    }
}
