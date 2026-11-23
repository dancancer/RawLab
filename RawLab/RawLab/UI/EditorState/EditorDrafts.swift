import RawLabKit
import SwiftUI
import UIKit

extension ContentView {
    var settings: RawSettings {
        get { coordinator.settings }
        nonmutating set { coordinator.settings = newValue }
    }

    var workspaceDraft: EditorToolDraft? {
        get { coordinator.workspaceDraft }
        nonmutating set { coordinator.workspaceDraft = newValue }
    }

    var toolWorkspaceOpen: Bool {
        get { coordinator.toolWorkspaceOpen }
        nonmutating set { coordinator.toolWorkspaceOpen = newValue }
    }

    var workspaceDraftID: UUID { coordinator.workspaceDraftID }
    var settingsRevision: UUID { coordinator.settingsRevision }
    var photoViewing: PhotoViewingState {
        get { coordinator.photoViewing }
        nonmutating set { coordinator.photoViewing = newValue }
    }
    var photoViewport: PhotoViewport {
        get { coordinator.photoViewport }
        nonmutating set { coordinator.photoViewport = newValue }
    }
    var selectedAdjustment: AdjustmentKind? {
        get { coordinator.selectedAdjustment }
        nonmutating set { coordinator.selectedAdjustment = newValue }
    }
    var selectedHDRRenditionTool: EditorToolSelection? {
        get { coordinator.selectedHDRRenditionTool }
        nonmutating set { coordinator.selectedHDRRenditionTool = newValue }
    }
    var lensSelected: Bool { coordinator.lensSelected }
    var geometrySelected: Bool { coordinator.geometrySelected }
    var choosingMasterRecipe: Bool { coordinator.choosingMasterRecipe }
    var adjustmentsExpanded: Bool {
        get { coordinator.adjustmentsExpanded }
        nonmutating set { coordinator.adjustmentsExpanded = newValue }
    }
    var isAdjustingSlider: Bool { coordinator.isAdjustingSlider }
    var geometryDraft: GeometrySettings? {
        get { coordinator.geometryDraft }
        nonmutating set { coordinator.geometryDraft = newValue }
    }
    var lensDraft: RawSettings? {
        get { coordinator.lensDraft }
        nonmutating set { coordinator.lensDraft = newValue }
    }
    var draftExitPresented: Bool {
        get { coordinator.draftExitPresented }
        nonmutating set { coordinator.draftExitPresented = newValue }
    }
    var pendingToolSelection: EditorToolSelection? { coordinator.pendingToolSelection }
    var pendingAdjustmentExpansion: Bool? { coordinator.pendingAdjustmentExpansion }
    var selectedGroup: EditorAdjustmentGroup {
        get { coordinator.selectedGroup }
        nonmutating set { coordinator.selectedGroup = newValue }
    }
    var hslChannel: Int {
        get { coordinator.hslChannel }
        nonmutating set { coordinator.hslChannel = newValue }
    }
    var adjustmentFine: Bool { coordinator.adjustmentFine }
    var collapsedEditorTool: EditorToolSelection? { coordinator.collapsedEditorTool }
    var preparedReset: PreparedEditorReset? { coordinator.preparedReset }
    var resetConfirmationPresented: Bool {
        get { coordinator.resetConfirmationPresented }
        nonmutating set { coordinator.resetConfirmationPresented = newValue }
    }
    var adjustmentSheet: IOSAdjustmentSheet? {
        get { coordinator.adjustmentSheet }
        nonmutating set { coordinator.adjustmentSheet = newValue }
    }
    var showingBatchSelection: Bool {
        get { coordinator.showingBatchSelection }
        nonmutating set { coordinator.showingBatchSelection = newValue }
    }
    var pendingCollectionNavigation: IOSCollectionNavigation? {
        get { coordinator.pendingCollectionNavigation }
        nonmutating set { coordinator.pendingCollectionNavigation = newValue }
    }
    var showingBatchExport: Bool {
        get { coordinator.showingBatchExport }
        nonmutating set { coordinator.showingBatchExport = newValue }
    }
    var batchModel: BatchExportModel? {
        get { coordinator.batchExportHandle as? BatchExportModel }
        nonmutating set { coordinator.batchExportHandle = newValue }
    }
    var showingExportSize: Bool {
        get { coordinator.showingExportSize }
        nonmutating set { coordinator.showingExportSize = newValue }
    }
    var singleExportFormat: BatchOutputFormat { coordinator.singleExportFormat }

    var workingSettings: RawSettings {
        get { coordinator.workingSettings }
        nonmutating set { coordinator.workingSettings = newValue }
    }

    var workingSettingsBinding: Binding<RawSettings> {
        Binding(get: { workingSettings }, set: { workingSettings = $0 })
    }

    var geometryDraftState: EditorGeometryDraftState { coordinator.geometryDraftState }

    func syncGeometryDraft() { coordinator.syncGeometryDraft() }
    func undoEditorDraft() { coordinator.undoEditorDraft() }
    func redoEditorDraft() { coordinator.redoEditorDraft() }
    func restoreDraftControls() { coordinator.restoreDraftControls() }

    var effectivePreviewSettings: RawSettings { coordinator.effectivePreviewSettings }
    var editorDraftSnapshot: EditorDraftSnapshot { coordinator.editorDraftSnapshot }
    var draftPreviewSettings: RawSettings { coordinator.draftPreviewSettings }

    func previewSettings(for draft: EditorDraftSnapshot) -> RawSettings {
        coordinator.previewSettings(for: draft)
    }

    func geometryProjection(for image: UIImage) -> GeometryDraftProjection? {
        var base = effectivePreviewSettings
        let geometry = base.geometrySettings
        guard geometrySelected || !geometry.isIdentity else { return nil }
        base.setGeometrySettings(GeometrySettings())
        // 只投影已经交付的无几何底图；应用或取消后用它承接到精确帧到达。
        guard viewModel.acceptedPreviewRequest?.settings == base else { return nil }
        return GeometryDraftProjection(source: viewModel.nativeImageSize ?? image.size, settings: geometry)
    }

    var geometryDraftBinding: Binding<GeometrySettings> {
        let sourceRevision = viewModel.sourceRevision
        return Binding(get: { coordinator.geometryDraft ?? settings.geometrySettings }, set: { value in
            guard !editorBusy, geometrySelected, viewModel.sourceRevision == sourceRevision else { return }
            coordinator.geometryDraft = value
        })
    }

    var lensDraftBinding: Binding<RawSettings> {
        let sourceRevision = viewModel.sourceRevision
        return Binding(get: { coordinator.lensDraft ?? settings }, set: { value in
            guard !editorBusy, lensSelected, viewModel.sourceRevision == sourceRevision else { return }
            coordinator.lensDraft = value
        })
    }

    var isEditorDraftActive: Bool { coordinator.isEditorDraftActive }
    var isEditorDraftChanged: Bool { coordinator.isEditorDraftChanged }

    func preserveEditorDraft() { coordinator.preserveEditorDraft() }
    func restoreEditorDraft() { coordinator.restoreEditorDraft() }
    func clearRecoverableDraft() { coordinator.clearRecoverableDraft() }

    var rulerFocusOpacity: Double {
        guard coordinator.rulerFocusPhase == .dragging || coordinator.rulerFocusPhase == .holding else { return 1 }
        return UIDevice.current.userInterfaceIdiom == .pad ? 0.42 : 0.08
    }

    func selectEditorTool(_ selection: EditorToolSelection) { coordinator.selectEditorTool(selection) }
    var currentEditorTool: EditorToolSelection { coordinator.currentEditorTool }

    func activateEditorTool(_ selection: EditorToolSelection, resettingFine: Bool = true, leavingWorkspace: Bool = false) {
        coordinator.activateEditorTool(selection, resettingFine: resettingFine, leavingWorkspace: leavingWorkspace)
    }

    func applyEditorDraft() { coordinator.applyEditorDraft() }
    func finishEditorTool() { coordinator.finishEditorTool() }
    func commitEditorDraft() -> Bool { coordinator.commitEditorDraft() }
    func cancelEditorDraft() { coordinator.cancelEditorDraft() }
    func closeEditorDraftCleanly() -> Bool { coordinator.closeEditorDraftCleanly() }
    func discardEditorDraft() { coordinator.discardEditorDraft() }

    func finishDraftNavigation(apply: Bool) {
        coordinator.finishDraftNavigation(
            apply: apply,
            continueImport: { continueEditorImport() },
            continueCollection: { continueCollectionNavigation() }
        )
    }

    func retryEditorSave() {
        coordinator.retryEditorSave(
            continueImport: {
                if !coordinator.pendingSystemPhotoURLs.isEmpty { continueSystemPhotoImport() }
                else { continueEditorImport() }
            },
            continueCollection: { continueCollectionNavigation() }
        )
    }

    func prepareEditorReset(_ scope: EditorAdjustmentScope) -> EditorResetPreparation {
        coordinator.prepareEditorReset(scope)
    }

    @discardableResult
    func commitEditorReset(_ prepared: PreparedEditorReset) -> Bool {
        coordinator.commitEditorReset(prepared)
    }

    func previewEditorDraft() { coordinator.previewEditorDraft() }

    func selectEditorGroup(_ group: EditorAdjustmentGroup) { coordinator.selectEditorGroup(group) }
    func normalizeHDRNavigation(isHDREditing: Bool) { coordinator.normalizeHDRNavigation(isHDREditing: isHDREditing) }
    func requestToolWorkspaceExit() { coordinator.requestToolWorkspaceExit() }
    func requestAdjustmentExpansion(_ expanded: Bool) { coordinator.requestAdjustmentExpansion(expanded) }

    func completeAdjustmentExpansion(_ expanded: Bool, closingWorkspace: Bool = false) {
        coordinator.completeAdjustmentExpansion(expanded, closingWorkspace: closingWorkspace)
    }

    func cancelDraftNavigation() {
        coordinator.cancelDraftNavigation(onSystemPhotoSkipped: { continueSystemPhotoImport() })
    }

    var resetSnapshot: PhotoEditState { coordinator.resetSnapshot }
    var resetContext: EditorAdjustmentContext { coordinator.resetContext }
    func resetModified(_ scope: EditorAdjustmentScope) -> Bool { coordinator.resetModified(scope) }
    func requestEditorReset(_ scope: EditorAdjustmentScope) { coordinator.requestEditorReset(scope) }
    func presentEditorReset(_ scope: EditorAdjustmentScope) { coordinator.presentEditorReset(scope) }
    func confirmEditorReset() { coordinator.confirmEditorReset() }
    func cancelEditorReset() { coordinator.cancelEditorReset() }

    var resetConfirmationTitle: String {
        switch coordinator.preparedResetScope {
        case .all: return L10n.text("重置全部调整？")
        case .allGrading, .tool(.adjustment(.colorGrading)): return L10n.text("重置颜色分级")
        case .allHSL, .tool(.adjustment(.hsl)): return L10n.text("重置全部 HSL？")
        case .group(let group): return L10n.format("重置%@组？", group.title)
        case .tool(let tool): return L10n.format("重置%@？", tool.title)
        default: return L10n.text("重置调整")
        }
    }

    var resetConfirmationMessage: String {
        let base: String
        switch coordinator.preparedResetScope {
        case .all: base = L10n.text("恢复当前照片的全部调整，不改写原始照片。")
        case .allGrading, .tool(.adjustment(.colorGrading)): base = L10n.text("恢复阴影、中间调和高光的颜色分级默认值？")
        case .allHSL, .tool(.adjustment(.hsl)):
            base = L10n.text("八个色域的色相、饱和度和明度都会恢复为 0。其他调整保持不变。")
        case .group(let group): base = L10n.format("此操作只恢复%@组内的调整，其他分组保持不变。", group.title)
        default: base = ""
        }
        guard let preparedReset = coordinator.preparedReset else { return base }
        let fields = EditorAdjustmentRules.materializedFields(before: preparedReset.original.committed.settings,
            after: preparedReset.candidate.settings)
        let wasRecipe = preparedReset.original.committed.settings.masterRecipeID != nil
        let removesRecipe = preparedReset.candidate.settings.masterRecipeID == nil
        guard !preparedReset.original.committed.settings.isHDREditing,
              wasRecipe && removesRecipe && coordinator.preparedResetScope != .all && !fields.isEmpty else { return base }
        return [base, L10n.format("将以下项目转为独立调整，以保留其他分组的当前效果：%@",
                                fields.map { L10n.text($0) }.joined(separator: ", "))].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func resetBlockedMessage(_ reason: EditorResetBlock) -> String { reason.message }
    func resetBlockedMessage(_ reason: EditorAdjustmentResetBlock) -> String { reason.message }

    func updateRulerFocus(editing: Bool, wasEditing: Bool) {
        coordinator.updateRulerFocus(editing: editing, wasEditing: wasEditing, reduceMotion: reduceMotion)
    }

    func cancelRulerFocus() { coordinator.cancelRulerFocus() }
}
