import SwiftUI
import UIKit

enum RulerFocusPhase: Equatable {
    case idle, dragging, holding, restoring
}

extension ContentView {
    var workingSettings: RawSettings {
        get { editorDraftSnapshot.projecting(on: settings) }
        nonmutating set {
            guard !editorBusy else { return }
            if var draft = workspaceDraft {
                draft.update(newValue, geometry: geometryDraftState, interactive: isAdjustingSlider)
                workspaceDraft = draft
            } else { settings = newValue }
        }
    }

    var workingSettingsBinding: Binding<RawSettings> {
        Binding(get: { workingSettings }, set: { workingSettings = $0 })
    }

    var geometryDraftState: EditorGeometryDraftState {
        EditorGeometryDraftState(preset: geometryAspectPreset.rawValue, lockedRatio: geometryLockedRatio,
                                 swapped: geometryAspectSwapped, grid: geometryGrid,
                                 includesLens: workspaceDraft?.step.geometry.includesLens ?? false)
    }

    func syncGeometryDraft() {
        guard var draft = workspaceDraft, draft.tool == .geometry || draft.tool == .lens else { return }
        var value = draft.value
        if let geometryDraft { value.setGeometrySettings(geometryDraft) }
        if let lensDraft { value.lensCorrection = lensDraft.lensCorrection }
        draft.update(value, geometry: geometryDraftState, interactive: isAdjustingSlider)
        workspaceDraft = draft
    }

    func undoEditorDraft() { workspaceDraft?.undo(); restoreDraftControls() }
    func redoEditorDraft() { workspaceDraft?.redo(); restoreDraftControls() }

    func restoreDraftControls() {
        guard let draft = workspaceDraft else { return }
        if geometrySelected { geometryDraft = draft.value.geometrySettings }
        if lensSelected { lensDraft = draft.value }
        geometryAspectPreset = CropAspectPreset(rawValue: draft.step.geometry.preset) ?? .free
        geometryLockedRatio = draft.step.geometry.lockedRatio
        geometryAspectSwapped = draft.step.geometry.swapped
        geometryGrid = draft.step.geometry.grid
    }

    var effectivePreviewSettings: RawSettings {
        editorDraftSnapshot.projecting(on: settings)
    }

    var editorDraftSnapshot: EditorDraftSnapshot {
        EditorDraftSnapshot(geometry: geometryDraft, lens: lensDraft,
                            tool: resetDraftSuspended || collapsedEditorTool != nil ? .film : currentEditorTool, destination: pendingToolSelection,
                            workspace: resetDraftSuspended || !toolWorkspaceOpen ? nil : workspaceDraft)
    }

    var draftPreviewSettings: RawSettings {
        var result = effectivePreviewSettings
        if geometrySelected {
            result.geometrySettings.cropX = 0
            result.geometrySettings.cropY = 0
            result.geometrySettings.cropWidth = 1
            result.geometrySettings.cropHeight = 1
        }
        return result
    }

    var geometryDraftBinding: Binding<GeometrySettings> {
        let sourceRevision = viewModel.sourceRevision
        return Binding(get: { geometryDraft ?? settings.geometrySettings }, set: { value in
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

    var isEditorDraftActive: Bool { toolWorkspaceOpen && workspaceDraft != nil }

    var isEditorDraftChanged: Bool {
        editorDraftSnapshot.isChanged(from: settings)
    }

    func preserveEditorDraft() {
        guard var draft = workspaceDraft, let identity = viewModel.sourceIdentity else { return }
        syncGeometryDraft()
        draft = workspaceDraft ?? draft
        draft.finishInteraction()
        do { try EditorToolDraftStore.appStore().save(identity: identity, draft: draft) }
        catch { viewModel.statusMessage = L10n.text("无法保存编辑草稿。") }
    }

    func restoreEditorDraft() {
        guard workspaceDraft == nil, let identity = viewModel.sourceIdentity, !editorBusy else { return }
        do {
            guard let draft = try EditorToolDraftStore.appStore().load(identity: identity, committed: settings) else { return }
            activateEditorTool(draft.tool)
            workspaceDraft = draft
            restoreDraftControls()
            previewEditorDraft()
        } catch { viewModel.statusMessage = L10n.text("无法恢复编辑草稿，已保留已应用的调整。") }
    }

    func clearRecoverableDraft() {
        guard let identity = viewModel.sourceIdentity else { return }
        try? EditorToolDraftStore.appStore().clear(identity: identity)
    }

    var rulerFocusOpacity: Double {
        guard rulerFocusPhase == .dragging || rulerFocusPhase == .holding else { return 1 }
        return UIDevice.current.userInterfaceIdiom == .pad ? 0.42 : 0.08
    }

    func selectEditorTool(_ selection: EditorToolSelection) {
        guard !editorBusy else { return }
        closeQuickPresets()
        if selection == currentEditorTool && toolWorkspaceOpen {
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
        viewModel.closeQuickPresets()
        cancelHSLTarget()
        cancelSliderInteraction()
        if resettingFine && selection != currentEditorTool { adjustmentFine = false }
        collapsedEditorTool = nil
        let leavingDraft = isEditorDraftActive
        if leavingDraft { clearRecoverableDraft(); viewModel.discardDraftSaveFailure(settings: settings) }
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
            geometryDraft = settings.geometrySettings
        }
        if lensSelected { lensDraft = settings }
        workspaceDraftID = UUID()
        workspaceDraft = EditorToolDraft(tool: selection, original: settings)
        toolWorkspaceOpen = true
        if leavingDraft && !geometrySelected && !lensSelected {
            viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
        }
    }

    func applyEditorDraft() {
        guard commitEditorDraft() else { return }
        finishEditorTool()
    }

    func finishEditorTool() {
        cancelHSLTarget()
        clearRecoverableDraft()
        workspaceDraftID = UUID()
        workspaceDraft = nil
        toolWorkspaceOpen = false
        geometrySelected = false; lensSelected = false
        geometryDraft = nil; lensDraft = nil
        viewModel.hasAdjustmentDraft = false
        viewModel.updatePreview(settings: settings, includeHistogram: true, quality: .final)
    }

    func commitEditorDraft() -> Bool {
        guard !editorBusy, !viewModel.previewRendering, !viewModel.previewResizePending, !viewModel.previewFailed, !isAdjustingSlider else { return false }
        if !isEditorDraftChanged { discardEditorDraft(); return true }
        guard let prepared = viewModel.prepareDraft(settings: settings, revision: settingsRevision, draft: editorDraftSnapshot),
              viewModel.saveDraft(prepared, settings: settings, revision: settingsRevision, draft: editorDraftSnapshot) else { return false }
        // 退出草稿会立即请求预览，不能等待 settings observer 才更新参考构图。
        viewModel.committedPreviewSettings = prepared.candidate.settings
        settings = prepared.candidate.settings
        clearRecoverableDraft()
        workspaceDraftID = UUID()
        workspaceDraft = nil
        geometryDraft = nil
        lensDraft = nil
        cancelRulerFocus()
        return true
    }

    func cancelEditorDraft() {
        discardEditorDraft()
        finishEditorTool()
    }

    func discardEditorDraft() {
        cancelHSLTarget()
        clearRecoverableDraft()
        workspaceDraftID = UUID()
        workspaceDraft = nil
        geometryDraft = nil
        lensDraft = nil
        viewModel.discardDraftSaveFailure(settings: settings)
        cancelRulerFocus()
    }

    func finishDraftNavigation(apply: Bool) {
        if apply {
            guard commitEditorDraft() else { return }
        } else { discardEditorDraft() }
        toolWorkspaceOpen = false
        if pendingCollectionNavigation != nil {
            finishEditorTool()
            continueCollectionNavigation()
            return
        }
        if pendingAdjustmentAction != nil {
            finishEditorTool()
            continueAdjustmentAction()
            return
        }
        if !pendingSystemPhotoURLs.isEmpty {
            finishEditorTool()
            continueSystemPhotoImport()
            return
        }
        if pendingFileImport || pendingPhotoImport {
            finishEditorTool()
            continueEditorImport()
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
        if isEditorDraftActive && viewModel.hasFailedDraftSave {
            if pendingToolSelection != nil || pendingAdjustmentExpansion != nil || pendingFileImport || pendingPhotoImport || !pendingSystemPhotoURLs.isEmpty || pendingAdjustmentAction != nil || pendingCollectionNavigation != nil { finishDraftNavigation(apply: true) }
            else { applyEditorDraft() }
        } else if !pendingSystemPhotoURLs.isEmpty {
            continueSystemPhotoImport()
        } else if pendingFileImport || pendingPhotoImport {
            continueEditorImport()
        } else if pendingCollectionNavigation != nil {
            continueCollectionNavigation()
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
            if currentEditorTool == .geometry || currentEditorTool == .lens {
                var geometry = geometryDraftState
                if preparedResetScope == .group(.geometry) { geometry.includesLens = true }
                workspaceDraft?.update(candidate.settings, geometry: geometry)
                if geometrySelected { geometryDraft = candidate.settings.geometrySettings }
                if lensSelected { lensDraft = candidate.settings }
            } else { workspaceDraft?.update(candidate.settings) }
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
        guard !editorBusy else { return }
        closeQuickPresets()
        guard !isEditorDraftActive else { return }
        selectedGroup = group
        adjustmentsExpanded = true
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
        if !expanded && !hslTargetEnabled { cancelSliderInteraction() }
        if expanded {
            if let tool = collapsedEditorTool { activateEditorTool(tool) }
        } else if isEditorDraftActive {
            let tool = currentEditorTool
            let group = selectedGroup
            // 收起结束实际草稿并恢复 committed 画面；记住的工具只属于导航会话。
            finishEditorTool()
            collapsedEditorTool = tool
            selectedGroup = group
        }
        adjustmentsExpanded = expanded
    }

    func cancelDraftNavigation() {
        let skippedSystemPhoto = !pendingSystemPhotoURLs.isEmpty
        if skippedSystemPhoto {
            let skipped = pendingSystemPhotoURLs.removeFirst()
            for url in skipped { PhotoImportFile.release(url) }
        }
        pendingCollectionNavigation = nil
        pendingAdjustmentAction = nil
        pendingFileImport = false
        pendingPhotoImport = false
        pendingToolSelection = nil
        pendingAdjustmentExpansion = nil
        resetIntentSource = nil
        resetWaitingForReady = false
        if skippedSystemPhoto {
            // 让确认框先完成 dismiss，再尝试下一条系统事件，避免同一轮重开确认框。
            DispatchQueue.main.async { continueSystemPhotoImport() }
        }
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
        presentEditorReset(scope)
    }

    func presentEditorReset(_ scope: EditorAdjustmentScope) {
        switch prepareEditorReset(scope) {
        case .unchanged: break
        case .blocked(let reason):
            viewModel.statusMessage = resetBlockedMessage(reason)
        case .prepared(let candidate):
            preparedResetScope = scope
            preparedReset = candidate
            if candidate.requiresConfirmation { resetConfirmationPresented = true }
            else { confirmEditorReset() }
        }
    }

    func confirmEditorReset() {
        guard let candidate = preparedReset else { return }
        if !commitEditorReset(candidate) { viewModel.statusMessage = L10n.text("照片或调整已变化，请重新确认重置。") }
        preparedReset = nil
        preparedResetScope = nil
    }

    func cancelEditorReset() {
        preparedReset = nil
        preparedResetScope = nil
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

    func resetBlockedMessage(_ reason: EditorResetBlock) -> String {
        reason.message
    }

    func resetBlockedMessage(_ reason: EditorAdjustmentResetBlock) -> String {
        reason.message
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
