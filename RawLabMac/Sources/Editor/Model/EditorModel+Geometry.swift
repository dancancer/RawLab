import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MacGeometryTab: String, CaseIterable {
    case crop, perspective, lens

    var title: String {
        L10n.text(self == .crop ? "裁切" : self == .perspective ? "透视" : "镜头")
    }
}

struct MacGeometryDraft: Equatable {
    let originalGeometry: GeometrySettings
    let originalLens: LensCorrectionSettings
    var geometry: GeometrySettings
    var lens: LensCorrectionSettings

    init(geometry: GeometrySettings, lens: LensCorrectionSettings) {
        originalGeometry = geometry; originalLens = lens
        self.geometry = geometry; self.lens = lens
    }

    var hasChanges: Bool { geometry != originalGeometry || lens != originalLens }
    var previewGeometry: GeometrySettings {
        var full = geometry
        full.cropX = 0; full.cropY = 0; full.cropWidth = 1; full.cropHeight = 1
        full.straightenDegrees = 0
        return full
    }
}

enum MacGeometryDeparture { case apply, discard, stay }

extension EditorModel {
    @discardableResult func beginGeometryDraft(tab: MacGeometryTab = .crop) -> Bool {
        if tab == .lens && RenderEngine.isRasterInput(file) { return false }
        if geometryDraft != nil { return selectGeometryDraftTab(tab) }
        guard file != nil, result != nil, !exporting, !lookLibraryBusy, saveEdits() else { return false }
        geometryDraftEntrySaveError = saveError
        geometryDraftSaveFailed = false
        geometryDraftEntryResult = result; geometryDraftEntryNeutral = neutral
        geometryDraftEpoch = UUID(); editRevision = UUID()
        geometryDraft = MacGeometryDraft(geometry: settings.geometrySettings, lens: settings.lensSettings)
        geometryDraftTab = tab; geometryDraftPreviewReady = false
        adjustmentNavigation.selectTool(tab == .lens ? .lens : .geometry)
        cropAspectPreset = .free; cropAspectSwapped = false; cropLockedRatio = nil
        invalidGeometryDraftInputs.removeAll()
        batch?.sourceEditingGeometry = true
        scheduler.setInteracting(false)
        schedule(forceExact: true)
        return true
    }

    @discardableResult func selectGeometryDraftTab(_ tab: MacGeometryTab) -> Bool {
        if tab == .lens && RenderEngine.isRasterInput(file) { return false }
        ParameterValueField.cancelPendingInputs()
        guard geometryDraft != nil, invalidGeometryDraftInputs.isEmpty else { return false }
        geometryDraftTab = tab
        return true
    }

    func updateGeometryDraft(_ edit: (inout GeometrySettings) -> Void) {
        guard var draft = geometryDraft else { return }
        let before = draft.previewGeometry
        let previousAngle = draft.geometry.straightenDegrees
        edit(&draft.geometry)
        guard draft.geometry.isValid, draft != geometryDraft else { return }
        geometryDraft = draft
        // Crop selection is an overlay on the already rendered, transformed canvas.
        if before != draft.previewGeometry {
            geometryDraftPreviewReady = false
            schedule()
        } else if geometryDraftPreviewReady, previousAngle != draft.geometry.straightenDegrees,
                  let ratio = cropAspectRatio {
            let rect = CropInteraction.dragging(CropInteraction.rect(from: draft.geometry), handle: .bottomRight,
                translation: .zero, canvasSize: geometryCanvasSize, ratio: ratio)
            draft.geometry = CropInteraction.applying(rect: rect, to: draft.geometry)
            geometryDraft = draft
        }
    }

    func updateLensDraft(_ edit: (inout LensCorrectionSettings) -> Void) {
        guard var draft = geometryDraft else { return }
        edit(&draft.lens)
        guard draft != geometryDraft else { return }
        geometryDraft = draft; geometryDraftPreviewReady = false
        schedule()
    }

    func geometryDraftParameterRange(_ parameter: GeometryParameter) -> ClosedRange<Double> {
        let geometry = geometryDraftSettings
        let base = parameter.range(for: geometry)
        guard parameter == .cropWidth || parameter == .cropHeight,
              let ratio = cropAspectRatio, geometryCanvasSize.width > 0, geometryCanvasSize.height > 0 else { return base }
        let normalized = ratio * Double(geometryCanvasSize.height / geometryCanvasSize.width)
        if parameter == .cropWidth {
            let upper = min(base.upperBound, (1 - geometry.cropY) * normalized)
            let lower = max(base.lowerBound, GeometryParameter.cropHeight.range(for: geometry).lowerBound * normalized)
            return min(lower, upper)...upper
        }
        let upper = min(base.upperBound, (1 - geometry.cropX) / normalized)
        let lower = max(base.lowerBound, GeometryParameter.cropWidth.range(for: geometry).lowerBound / normalized)
        return min(lower, upper)...upper
    }

    func setGeometryDraftParameter(_ parameter: GeometryParameter, to value: Double) {
        guard value.isFinite else { return }
        let range = geometryDraftParameterRange(parameter)
        guard range.contains(value) else { return }
        updateGeometryDraft { geometry in
            geometry[keyPath: parameter.keyPath] = value
            if let ratio = cropAspectRatio, geometryCanvasSize.width > 0 {
                let normalized = ratio * Double(geometryCanvasSize.height / geometryCanvasSize.width)
                if parameter == .cropWidth { geometry.cropHeight = value / normalized }
                if parameter == .cropHeight { geometry.cropWidth = value * normalized }
            }
        }
    }

    func setGeometryDraftInputValidity(identifier: String, isValid: Bool) {
        guard geometryDraft != nil else { return }
        if isValid { invalidGeometryDraftInputs.remove(identifier) }
        else { invalidGeometryDraftInputs.insert(identifier) }
    }

    func setGeometryCropInteracting(_ interacting: Bool) {
        guard geometryCropInteracting != interacting else { return }
        geometryCropInteracting = interacting
        // @Published 在赋值前通知；原生手势同步刷新后还需读取已写入的状态。
        objectWillChange.send()
    }

    func selectCropAspect(_ preset: CropAspectPreset) {
        guard geometryDraftPreviewReady else { return }
        cropLockedRatio = nil
        cropAspectPreset = preset
        fitDraftCropAspect()
    }

    func toggleCropAspectLock() {
        guard geometryDraftPreviewReady else { return }
        if cropAspectRatio != nil {
            cropAspectPreset = .free; cropAspectSwapped = false; cropLockedRatio = nil
        } else {
            let crop = geometryDraftSettings
            cropAspectSwapped = false
            cropLockedRatio = crop.cropWidth * Double(geometryCanvasSize.width) /
                (crop.cropHeight * Double(geometryCanvasSize.height))
        }
    }

    func swapCropAspect() {
        guard geometryDraftPreviewReady, cropAspectRatio != nil else { return }
        cropAspectSwapped.toggle(); fitDraftCropAspect()
    }

    private func fitDraftCropAspect() {
        let rect = MacCropInteraction.fitting(ratio: cropAspectRatio, in: geometryCanvasSize,
                                             around: CropInteraction.rect(from: geometryDraftSettings))
        updateGeometryDraft { $0 = CropInteraction.applying(rect: rect, to: $0) }
    }

    func resetGeometryDraft() {
        cropAspectPreset = .free; cropAspectSwapped = false; cropLockedRatio = nil
        geometryDraftRevision &+= 1
        invalidGeometryDraftInputs.removeAll()
        updateGeometryDraft { $0 = GeometrySettings() }
    }

    func resetLensDraft() {
        geometryDraftRevision &+= 1
        updateLensDraft { $0 = LensCorrectionSettings() }
    }

    @discardableResult func applyGeometryDraft() -> Bool {
        guard geometryDraftCanApply, let draft = geometryDraft, let file else { return false }
        var committed = settings
        committed.geometry = draft.geometry.isIdentity ? nil : draft.geometry
        committed.lensCorrection = draft.lens == LensCorrectionSettings() ? nil : draft.lens
        do {
            if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
            try editStore!.save(file, state: editState(settings: committed))
        } catch {
            geometryDraftSaveFailed = true
            saveError = L10n.format("调整未保存：%@", error.localizedDescription)
            return false
        }
        saveWork?.cancel()
        updatingMetadata = true; settings = committed; updatingMetadata = false
        dirty = false; saveError = nil; saveStatusKey = "调整已保存"
        // 精确渲染完成前沿用同一底图的已裁切显示，避免闪回未旋转画面。
        pendingGeometryPresentation = draft.geometry
        clearSaveStatusLater(); endGeometryDraft(); schedule(forceExact: true)
        return true
    }

    func cancelGeometryDraft() {
        guard geometryDraft != nil else { return }
        // Discarding an unsaved draft restores the saved entry state, including
        // its feedback. Do not clear an unrelated error that predated the task.
        if geometryDraftSaveFailed { saveError = geometryDraftEntrySaveError }
        result = geometryDraftEntryResult; neutral = geometryDraftEntryNeutral
        endGeometryDraft(); schedule(forceExact: true)
    }

    private func endGeometryDraft() {
        if resetReturnTool == nil && !geometryDraftDeparturePending { adjustmentNavigation.selectTool(.exposure) }
        geometryDraft = nil; geometryDraftPreviewReady = false
        geometryCropInteracting = false; invalidGeometryDraftInputs.removeAll()
        geometryDraftEntrySaveError = nil; geometryDraftSaveFailed = false
        geometryDraftEntryResult = nil; geometryDraftEntryNeutral = nil
        geometryDraftEpoch = UUID(); editRevision = UUID()
        scheduler.setInteracting(false)
        batch?.sourceEditingGeometry = false
    }

    func requestLeavingGeometryDraft(_ action: @escaping () -> Void, onStay: @escaping () -> Void = {}) {
        guard !geometryDraftDeparturePending else { return }
        // Navigation discards only uncommitted field text before inspecting the geometry transaction.
        ParameterValueField.cancelPendingInputs()
        if geometryDraftHasChanges {
            geometryDepartureAction = action; geometryDepartureStay = onStay
            geometryDraftDeparturePending = true
        } else {
            cancelGeometryDraft(); action()
        }
    }

    func resolveGeometryDraftDeparture(_ choice: MacGeometryDeparture) {
        guard geometryDraftDeparturePending else { return }
        if choice == .apply && !applyGeometryDraft() { return }
        if choice == .discard { cancelGeometryDraft() }
        let action = choice == .stay ? geometryDepartureStay : geometryDepartureAction
        geometryDepartureAction = nil; geometryDepartureStay = nil
        geometryDraftDeparturePending = false
        action?()
    }
}
