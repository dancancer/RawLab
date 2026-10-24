import SwiftUI
import UIKit

enum RulerFocusPhase: Equatable {
    case idle, dragging, holding, restoring
}

extension ContentView {
    var effectivePreviewSettings: RawSettings {
        editorDraftSnapshot.projecting(on: settings)
    }

    var editorDraftSnapshot: EditorDraftSnapshot {
        EditorDraftSnapshot(geometry: geometryDraft, lens: lensDraft,
                            tool: resetDraftSuspended || collapsedEditorTool != nil ? .film : currentEditorTool, destination: pendingToolSelection)
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
        editorDraftSnapshot.isChanged(from: settings)
    }

    var rulerFocusOpacity: Double {
        guard rulerFocusPhase == .dragging || rulerFocusPhase == .holding else { return 1 }
        return UIDevice.current.userInterfaceIdiom == .pad ? 0.42 : 0.08
    }

    func selectEditorTool(_ selection: EditorToolSelection) {
        guard !editorBusy else { return }
        if selection == currentEditorTool {
            if !adjustmentsExpanded { requestAdjustmentExpansion(true) }
            return
        }
        if isEditorDraftChanged {
            pendingToolSelection = selection
            draftExitPresented = true
            return
        }
        activateEditorTool(selection)
    }

    var currentEditorTool: EditorToolSelection {
        if let collapsedEditorTool { return collapsedEditorTool }
        if geometrySelected { return .geometry }
        if lensSelected { return .lens }
        if choosingMasterRecipe { return .recipe }
        return selectedAdjustment.map(EditorToolSelection.adjustment) ?? .film
    }

    func activateEditorTool(_ selection: EditorToolSelection, resettingFine: Bool = true) {
        cancelSliderInteraction()
        if resettingFine && selection != currentEditorTool { adjustmentFine = false }
        collapsedEditorTool = nil
        let leavingDraft = geometrySelected || lensSelected
        if leavingDraft { viewModel.discardDraftSaveFailure(settings: settings) }
        pendingToolSelection = nil
        draftExitPresented = false
        cancelRulerFocus()
        geometryDraft = nil
        lensDraft = nil
        geometrySelected = selection == .geometry
        lensSelected = selection == .lens
        choosingMasterRecipe = selection == .recipe
        selectedGroup = EditorAdjustmentRules.groupFor(selection)
        if case .adjustment(let adjustment) = selection { selectedAdjustment = adjustment }
        else { selectedAdjustment = nil }
        if geometrySelected {
            geometryAspectPreset = .free; geometryLockedRatio = nil; geometryAspectSwapped = false
            geometryDraft = settings.geometry
        }
        if lensSelected { lensDraft = settings }
        if leavingDraft && !geometrySelected && !lensSelected {
            viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
        }
    }

    func applyEditorDraft() {
        guard commitEditorDraft() else { return }
        activateEditorTool(.adjustment(.exposure))
    }

    func commitEditorDraft() -> Bool {
        guard !editorBusy, !viewModel.previewRendering, !viewModel.previewResizePending, !viewModel.previewFailed, !isAdjustingSlider,
              let prepared = viewModel.prepareDraft(settings: settings, revision: settingsRevision, draft: editorDraftSnapshot),
              viewModel.saveDraft(prepared, settings: settings, revision: settingsRevision, draft: editorDraftSnapshot) else { return false }
        // 退出草稿会立即请求预览，不能等待 settings observer 才更新参考构图。
        viewModel.committedPreviewSettings = prepared.candidate.settings
        settings = prepared.candidate.settings
        geometryDraft = nil
        lensDraft = nil
        cancelRulerFocus()
        return true
    }

    func cancelEditorDraft() {
        discardEditorDraft()
        activateEditorTool(.adjustment(.exposure))
    }

    func discardEditorDraft() {
        geometryDraft = nil
        lensDraft = nil
        viewModel.discardDraftSaveFailure(settings: settings)
        cancelRulerFocus()
    }

    func finishDraftNavigation(apply: Bool) {
        if apply {
            guard commitEditorDraft() else { return }
        } else { discardEditorDraft() }
        if pendingAdjustmentAction != nil {
            activateEditorTool(.adjustment(.exposure))
            continueAdjustmentAction()
            return
        }
        if pendingFileImport || pendingPhotoImport {
            activateEditorTool(.adjustment(.exposure))
            continueEditorImport()
            return
        }
        if resetRestoreTool != nil {
            resetDraftSuspended = true
            resetWaitingForReady = true
            draftExitPresented = false
            // Apply/Discard 已结束；最终确认取消也不回退这一步。
            viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
            continuePendingAllReset()
            return
        }
        let selection = pendingToolSelection
        let expansion = pendingAdjustmentExpansion
        pendingToolSelection = nil
        pendingAdjustmentExpansion = nil
        if expansion == false { completeAdjustmentExpansion(false); return }
        if let selection { activateEditorTool(selection) }
        if let expansion { completeAdjustmentExpansion(expansion) }
    }

    func retryEditorSave() {
        if viewModel.adjustmentReloadRequired { adjustmentReloadPresented = true; return }
        if isEditorDraftActive && viewModel.hasFailedDraftSave {
            if pendingToolSelection != nil || pendingAdjustmentExpansion != nil || resetRestoreTool != nil || pendingFileImport || pendingPhotoImport || pendingAdjustmentAction != nil { finishDraftNavigation(apply: true) }
            else { applyEditorDraft() }
        } else if pendingFileImport || pendingPhotoImport {
            continueEditorImport()
        } else if pendingAdjustmentAction != nil {
            continueAdjustmentAction()
        } else { viewModel.retrySave(settings: settings) }
    }

    func prepareEditorReset(_ scope: EditorAdjustmentScope) -> EditorResetPreparation {
        viewModel.prepareReset(scope, settings: settings, revision: settingsRevision, draft: editorDraftSnapshot)
    }

    @discardableResult
    func commitEditorReset(_ prepared: PreparedEditorReset) -> Bool {
        guard !editorBusy,
              let candidate = viewModel.commitReset(prepared, settings: settings, revision: settingsRevision,
                                                   draft: editorDraftSnapshot) else { return false }
        if prepared.updatesDraft {
            geometryDraft = candidate.settings.geometry
            lensDraft = candidate.settings
        } else {
            let parametersChanged = settings != candidate.settings
            applySettingsChange(candidate.settings)
            if !parametersChanged {
                // 仅外部外观身份改变时，SwiftUI 不会发出 settings onChange。
                settingsRevision = UUID()
                queueEditorSettingsChange(candidate.settings)
            }
        }
        return true
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

    func selectEditorGroup(_ group: EditorAdjustmentGroup) {
        guard !editorBusy, !resetDraftSuspended else { return }
        if group == selectedGroup {
            requestAdjustmentExpansion(!adjustmentsExpanded)
        } else {
            let target = EditorAdjustmentRules.defaultTool(group)
            if isEditorDraftChanged {
                pendingToolSelection = target
                pendingAdjustmentExpansion = true
                draftExitPresented = true
            } else {
                activateEditorTool(target)
                adjustmentsExpanded = true
            }
        }
    }

    func requestAdjustmentExpansion(_ expanded: Bool) {
        guard !editorBusy, !resetDraftSuspended else { return }
        if !expanded && isEditorDraftChanged {
            pendingToolSelection = currentEditorTool
            pendingAdjustmentExpansion = false
            draftExitPresented = true
        } else { completeAdjustmentExpansion(expanded) }
    }

    func completeAdjustmentExpansion(_ expanded: Bool) {
        if !expanded { cancelSliderInteraction() }
        if expanded {
            if let tool = collapsedEditorTool { activateEditorTool(tool) }
        } else if isEditorDraftActive {
            let tool = currentEditorTool
            let group = selectedGroup
            // 收起结束实际草稿并恢复 committed 画面；记住的工具只属于导航会话。
            activateEditorTool(.film, resettingFine: false)
            collapsedEditorTool = tool
            selectedGroup = group
        }
        adjustmentsExpanded = expanded
    }

    func cancelDraftNavigation() {
        pendingAdjustmentAction = nil
        pendingFileImport = false
        pendingPhotoImport = false
        pendingToolSelection = nil
        pendingAdjustmentExpansion = nil
        resetRestoreTool = nil
        resetIntentSource = nil
        resetWaitingForReady = false
    }

    var resetSnapshot: PhotoEditState {
        let state = viewModel.currentEditState(settings: settings)
        return state.replacing(settings: effectivePreviewSettings, preservingFilmID: state.filmID)
    }

    var resetContext: EditorAdjustmentContext {
        EditorAdjustmentContext(isRaw: viewModel.sourceKind == .raw,
            defaultExposureMode: RawSettings.default.exposureMode,
            cameraTemperature: viewModel.rawWhiteBalance?.isCalibrated == true ? viewModel.rawWhiteBalance?.temperature : nil,
            cameraTint: viewModel.rawWhiteBalance?.isCalibrated == true ? viewModel.rawWhiteBalance?.tint : nil)
    }

    func resetModified(_ scope: EditorAdjustmentScope) -> Bool {
        EditorAdjustmentRules.isModified(scope, snapshot: resetSnapshot, context: resetContext)
    }

    func requestEditorReset(_ scope: EditorAdjustmentScope) {
        guard !editorBusy else { return }
        if scope == .all && isEditorDraftActive {
            resetRestoreTool = currentEditorTool
            resetIntentSource = viewModel.editorEditSource
            if isEditorDraftChanged { draftExitPresented = true; return }
            resetDraftSuspended = true
            resetWaitingForReady = true
            continuePendingAllReset()
        } else { presentEditorReset(scope) }
    }

    func continuePendingAllReset() {
        guard resetWaitingForReady else { return }
        guard resetIntentSource == viewModel.editorEditSource else { cancelEditorReset(); return }
        guard !editorBusy, !viewModel.previewRendering, !viewModel.previewResizePending, !isAdjustingSlider else { return }
        resetWaitingForReady = false
        presentEditorReset(.all)
    }

    func presentEditorReset(_ scope: EditorAdjustmentScope) {
        switch prepareEditorReset(scope) {
        case .unchanged: restoreResetDraft()
        case .blocked(let reason):
            viewModel.statusMessage = resetBlockedMessage(reason)
            restoreResetDraft()
        case .prepared(let candidate):
            preparedResetScope = scope
            preparedReset = candidate
            if candidate.requiresConfirmation { resetConfirmationPresented = true }
            else { confirmEditorReset() }
        }
    }

    func confirmEditorReset() {
        guard let candidate = preparedReset else { restoreResetDraft(); return }
        if !commitEditorReset(candidate) { viewModel.statusMessage = L10n.text("照片或调整已变化，请重新确认重置。") }
        preparedReset = nil
        preparedResetScope = nil
        restoreResetDraft(preview: false)
    }

    func cancelEditorReset() {
        preparedReset = nil
        preparedResetScope = nil
        restoreResetDraft()
    }

    func restoreResetDraft(preview: Bool = true) {
        guard let tool = resetRestoreTool else { return }
        let sameSource = resetIntentSource == viewModel.editorEditSource
        resetRestoreTool = nil
        resetIntentSource = nil
        resetDraftSuspended = false
        resetWaitingForReady = false
        guard sameSource else { return }
        let freshGeometry = tool == .geometry ? settings.geometry : nil
        let freshLens = tool == .lens ? settings : nil
        if geometryDraft != freshGeometry || lensDraft != freshLens {
            // 确认后的 settings observer 已负责预览；取消时重进几何要恢复 uncropped 画面。
            suppressNextDraftPreview = !preview
        }
        geometryDraft = freshGeometry
        lensDraft = freshLens
    }

    var resetConfirmationTitle: String {
        switch preparedResetScope {
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
        switch preparedResetScope {
        case .all: base = L10n.text("恢复当前照片的全部调整，不改写原始照片。")
        case .allGrading, .tool(.adjustment(.colorGrading)): base = L10n.text("恢复阴影、中间调和高光的颜色分级默认值？")
        case .allHSL, .tool(.adjustment(.hsl)):
            base = L10n.text("八个色域的色相、饱和度和明度都会恢复为 0。其他调整保持不变。")
        case .group(let group): base = L10n.format("此操作只恢复%@组内的调整，其他分组保持不变。", group.title)
        default: base = ""
        }
        guard let preparedReset else { return base }
        let fields = EditorAdjustmentRules.materializedFields(before: preparedReset.original.committed.settings,
            after: preparedReset.candidate.settings)
        let wasRecipe = preparedReset.original.committed.settings.masterRecipeID != nil
        let removesRecipe = preparedReset.candidate.settings.masterRecipeID == nil
        guard wasRecipe && removesRecipe && preparedResetScope != .all && !fields.isEmpty else { return base }
        return [base, L10n.format("将以下项目转为独立调整，以保留其他分组的当前效果：%@",
                                fields.map { L10n.text($0) }.joined(separator: ", "))].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func resetBlockedMessage(_ reason: EditorAdjustmentResetBlock?) -> String {
        switch reason {
        case .invalidInput: return L10n.text("当前照片或调整记录无效，无法安全重置。")
        case .unknownRecipe: return L10n.text("当前配方不可用，无法安全重置外观。")
        case .missingCameraWhiteBalance: return L10n.text("缺少拍摄时白平衡数据，无法保留配方效果。")
        case .unrepresentable: return L10n.text("现有参数范围无法保留配方的全部效果。你可以取消，或另行确认重置全部调整。")
        case nil: return L10n.text("预览尚未就绪，请稍后重试。")
        }
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
