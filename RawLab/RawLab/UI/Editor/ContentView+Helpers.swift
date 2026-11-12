import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ContentView {
    func supportsHDR(_ tool: EditorToolSelection) -> Bool {
        if tool == .geometry { return true }
        if case .adjustment(let kind)=tool {
            return kind.hdrKeyPath != nil || kind == .hsl || kind == .colorGrading || kind == .vignette || kind == .grain
        }
        return false
    }

    func toolUnavailableReason(_ tool: EditorToolSelection) -> String? {
        if settings.isHDREditing && !supportsHDR(tool) { return L10n.text("HDR 模式暂不支持此工具。") }
        if tool == .lens && usesNormalX3f { return L10n.text("此输入不支持镜头校正") }
        if tool == .adjustment(.temperature) && !settings.isHDREditing && viewModel.rawWhiteBalance == nil {
            return L10n.text("此照片没有可用的相机白平衡校准。")
        }
        if tool == .adjustment(.strength) && !settings.hasLook { return L10n.text("请先选择外观或配方。") }
        return nil
    }

    func setHDREditing(_ enabled: Bool) {
        guard (viewModel.sourceIsHDR || viewModel.sourceSupportsCameraHDR),enabled != settings.isHDREditing,!editorBusy,!isEditorDraftActive,
              let source=viewModel.editorEditSource else { return }
        do {
            var candidate=try settings.withHDRMode(enabled,sourceIsHDR:viewModel.sourceIsHDR,
                                                   cameraRAW:viewModel.sourceSupportsCameraHDR)
            if enabled, viewModel.sourceProRAW != nil {
                candidate.proRAWDecodeVersion = try ProRAWSource.validatedDecodeVersion(settings.proRAWDecodeVersion)
            }
            guard viewModel.saveCurrentSettings(settings) else { return }
            if enabled && viewModel.sourceSupportsCameraHDR {
                let proposed = candidate
                let sourceRevision = viewModel.sourceRevision
                viewModel.preflightCameraHDR(settings: proposed) { result in
                    guard viewModel.sourceRevision == sourceRevision else { return }
                    switch result {
                    case .success: activateHDRMode(proposed, source: source)
                    case .failure(let error): viewModel.reportError(error, operation: .preview, stage: "enableCameraHDR")
                    }
                }
            } else {
                activateHDRMode(candidate, source: source)
            }
        } catch { viewModel.reportError(error, operation: .preview, stage: "changeHDRMode") }
    }

    func applyHDRCameraDevelopment(_ development: HDRCameraDevelopmentSettings) {
        guard !editorBusy, !isEditorDraftActive, settings.isHDREditing, viewModel.sourceSupportsCameraHDR,
              viewModel.sourceProRAW == nil, let source = viewModel.editorEditSource,
              development.isValid, development != settings.hdr?.cameraDevelopmentSettings,
              viewModel.saveCurrentSettings(settings) else { return }
        let before = settings
        let revision = viewModel.sourceRevision
        var candidate = settings
        candidate.hdr?.cameraDevelopmentSettings = development
        viewModel.preflightCameraHDR(settings: candidate) { result in
            guard viewModel.sourceRevision == revision, settings == before else { return }
            switch result {
            case .success: activateHDRMode(candidate, source: source)
            case .failure(let error): viewModel.reportError(error, operation: .preview, stage: "cameraHDRDevelopment")
            }
        }
    }

    private func activateHDRMode(_ candidate: RawSettings, source: EditorEditSource) {
        guard viewModel.persistEditCandidate(viewModel.currentEditState(settings:candidate),source:source) else { return }
        viewModel.persistedEditorSettings=PersistedEditorSettings(source:source,settings:candidate)
        viewModel.committedPreviewSettings=candidate
        settings=candidate
        selectEditorTool(.adjustment(.exposure))
        viewModel.updatePreview(settings:candidate)
    }
    var editingLocked: Bool { isImporting || isSaving || viewModel.isBusy || batchModel?.isRunning == true }
    var editorBusy: Bool { viewModel.isBusy || viewModel.isLoadingLUTs || viewModel.isImportingLooks || editingLocked }
    var selectedFilmName: String {
        workingSettings.masterRecipe?.title ?? viewModel.availableLUTs.first { $0.id == workingSettings.lutID }?.name ?? (workingSettings.lutID == nil ? L10n.text("中性") : L10n.text("外观不可用"))
    }

    var currentPreviewImage: UIImage? { viewModel.previewImage ?? viewModel.basePreviewImage }

    var currentHistogram: Sony2FujiProcessor.RGBHistogram? {
        showingBefore ? viewModel.baseHistogram : viewModel.histogram
    }

    func adjustmentProgress(_ adjustment: AdjustmentKind) -> Double {
        if settings.isHDREditing { return adjustment.progress(in:settings) }
        if viewModel.sourceKind == .raster && (adjustment == .temperature || adjustment == .tint) {
            return 0
        }
        if adjustment == .temperature {
            if viewModel.sourceKind == .raw, settings.whiteBalanceMode == .custom,
               let camera = viewModel.rawWhiteBalance {
                let temperatureOrigin = RawSettings.reciprocalSliderValue(for: camera.temperature)
                let temperaturePosition = RawSettings.reciprocalSliderValue(for: settings.temperature)
                let temperatureDelta = temperaturePosition - temperatureOrigin
                let temperatureDistance = temperatureDelta < 0 ? temperatureOrigin : 1 - temperatureOrigin
                let temperatureProgress = temperatureDistance > 0
                    ? min(1, max(-1, temperatureDelta / temperatureDistance)) : 0
                let tintOrigin = (camera.tint + 150) / 300
                let tintPosition = (settings.tint + 150) / 300
                let tintDelta = tintPosition - tintOrigin
                let tintDistance = tintDelta < 0 ? tintOrigin : 1 - tintOrigin
                let tintProgress = tintDistance > 0 ? min(1, max(-1, tintDelta / tintDistance)) : 0
                return abs(temperatureProgress) >= abs(tintProgress) ? temperatureProgress : tintProgress
            }
            if viewModel.sourceKind == .raw {
                return settings.masterRecipeID == nil ? 0 : settings.tint / 150
            }
            return adjustment.progress(in: settings)
        }
        if adjustment == .tint && settings.masterRecipeID != nil { return settings.tint / 150 }
        if viewModel.sourceKind == .raw, adjustment == .tint {
            guard settings.whiteBalanceMode == .custom, let camera = viewModel.rawWhiteBalance else { return 0 }
            let origin = (camera.tint + 150) / 300
            let position = (settings.tint + 150) / 300
            let delta = position - origin
            let distance = delta < 0 ? origin : 1 - origin
            return distance > 0 ? min(1, max(-1, delta / distance)) : 0
        }
        return adjustment.progress(in: settings)
    }

    var manualWhiteBalanceSettings: RawSettings {
        guard !settings.isHDREditing, viewModel.sourceKind == .raw,
              let camera = viewModel.rawWhiteBalance else { return settings }
        return settings.customWhiteBalance(cameraTemperature: camera.temperature, cameraTint: camera.tint)
    }

    func exportPhoto(longEdge: Int?, format: BatchOutputFormat) {
        guard !isEditorDraftActive else { return }
        isSaving = true
        viewModel.exportPhoto(settings: settings, longEdge: longEdge, format: format) { result in
            switch result {
            case .success(let data):
                saveToPhotoLibrary(data, format: format)
            case .failure(let error):
                isSaving = false
                if error is CancellationError {
                    viewModel.statusMessage = L10n.text("导出已取消")
                } else {
                    viewModel.reportError(error, operation: .photoExport, stage: "renderPhoto",
                                          context: ["outputFormat": format.rawValue])
                }
            }
        }
    }

    func exportDNG(longEdge: Int? = nil) {
        guard !isEditorDraftActive, canStartFileExport else { return }
        isSaving = true
        viewModel.exportDNG(settings: settings, longEdge: longEdge) { result in
            switch result {
            case .success(let url):
                isSaving = false
                fileExportRequest = FileExportRequest(
                    urls: [url],
                    removeAfterExport: true,
                    successMessage: L10n.text("已导出渲染型 DNG。"),
                    cancelMessage: L10n.text("已生成渲染型 DNG，未另存到所选位置。")
                )
            case .failure(let error):
                isSaving = false
                viewModel.reportError(error, operation: .photoExport, stage: "renderDNG")
            }
        }
    }

    func applySettingsChange(_ newSettings: RawSettings) {
        workingSettings = newSettings
    }

    func queueEditorSettingsChange(_ newSettings: RawSettings) {
        showingBefore = false
        viewModel.queueSettingsSave(newSettings)
        if isAdjustingSlider {
            viewModel.schedulePreviewUpdate(settings: draftPreviewSettings, delay: 0.08,
                                           includeHistogram: false, quality: .interactive)
        } else {
            _ = viewModel.saveCurrentSettings(newSettings)
            viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
        }
    }

    func adjustmentBinding(_ adjustment: AdjustmentKind) -> Binding<Double> {
        Binding(
            get: { adjustment.value(from: workingSettings) },
            set: { value in
                var updated = !workingSettings.isHDREditing && viewModel.sourceKind == .raw && (adjustment == .temperature || (adjustment == .tint && workingSettings.masterRecipeID == nil))
                    ? manualWhiteBalanceSettings : workingSettings
                adjustment.setValue(value, in: &updated)
                if !workingSettings.isHDREditing, viewModel.sourceKind == .raw,
                   (adjustment == .temperature || adjustment == .tint) && !(updated.masterRecipeID != nil && adjustment == .tint) {
                    updated.whiteBalanceMode = .custom
                }
                applySettingsChange(updated)
            }
        )
    }

    func reset(_ adjustment: AdjustmentKind) {
        var updated = workingSettings
        adjustment.reset(in: &updated)
        if !workingSettings.isHDREditing, viewModel.sourceKind == .raw,
           adjustment == .temperature || adjustment == .tint {
            if let whiteBalance = viewModel.rawWhiteBalance {
                if adjustment == .temperature { updated.temperature = whiteBalance.temperature }
                else { updated.tint = updated.masterRecipeID == nil ? whiteBalance.tint : 0 }
                if updated.masterRecipeID != nil {
                    if adjustment == .temperature { updated.whiteBalanceMode = .camera }
                } else {
                    updated.whiteBalanceMode = updated.temperature == whiteBalance.temperature && updated.tint == whiteBalance.tint ? .camera : .custom
                }
            }
        }
        applySettingsChange(updated)
    }

    func resetTool(_ adjustment: AdjustmentKind) {
        requestEditorReset(.tool(.adjustment(adjustment)))
    }

    func resetSelectedAdjustment() {
        requestEditorReset(.tool(currentEditorTool))
    }

    func resetWhiteBalance() {
        requestEditorReset(.tool(.adjustment(.temperature)))
    }

    func setWhiteBalanceMode(_ mode: RawWhiteBalanceMode) {
        guard !workingSettings.isHDREditing else { return }
        var updated = workingSettings
        if mode == .custom,
           workingSettings.whiteBalanceMode == .camera,
           let whiteBalance = viewModel.rawWhiteBalance {
            updated.temperature = whiteBalance.temperature
            if updated.masterRecipeID == nil { updated.tint = whiteBalance.tint }
        }
        updated.whiteBalanceMode = mode
        if mode == .camera, let whiteBalance = viewModel.rawWhiteBalance {
            updated.temperature = whiteBalance.temperature
            updated.tint = updated.masterRecipeID == nil ? whiteBalance.tint : 0
        }
        applySettingsChange(updated)
    }

    var displayedTemperature: Double {
        if workingSettings.isHDREditing { return workingSettings.hdr!.temperature }
        guard viewModel.sourceKind != .raster else { return RawSettings.default.temperature }
        if viewModel.sourceKind == .raw,
           workingSettings.whiteBalanceMode == .camera,
           let whiteBalance = viewModel.rawWhiteBalance {
            return whiteBalance.temperature
        }
        return workingSettings.temperature
    }

    var displayedTint: Double {
        if workingSettings.isHDREditing { return workingSettings.hdr!.tint }
        guard viewModel.sourceKind != .raster else { return 0 }
        if workingSettings.masterRecipeID != nil { return workingSettings.tint }
        if viewModel.sourceKind == .raw,
           workingSettings.whiteBalanceMode == .camera,
           let whiteBalance = viewModel.rawWhiteBalance {
            return whiteBalance.tint
        }
        return workingSettings.tint
    }

    func reciprocalTemperatureBinding() -> Binding<Double> {
        Binding(
            get: { RawSettings.reciprocalSliderValue(for: displayedTemperature) },
            set: { value in
                var updated = manualWhiteBalanceSettings
                AdjustmentKind.temperature.setValue(RawSettings.temperature(forReciprocalSliderValue:value),in:&updated)
                if !workingSettings.isHDREditing, viewModel.sourceKind == .raw { updated.whiteBalanceMode = .custom }
                applySettingsChange(updated)
            }
        )
    }

    func temperatureNumberBinding() -> Binding<Double> {
        Binding(
            get: { displayedTemperature },
            set: { value in
                guard value.isFinite else { return }
                var updated = manualWhiteBalanceSettings
                AdjustmentKind.temperature.setValue(min(max(value.rounded(),RawSettings.temperatureRange.lowerBound),
                    RawSettings.temperatureRange.upperBound),in:&updated)
                if !workingSettings.isHDREditing, viewModel.sourceKind == .raw { updated.whiteBalanceMode = .custom }
                applySettingsChange(updated)
            }
        )
    }

    func setSliderEditing(_ editing: Bool) {
        guard !editorBusy else {
            isAdjustingSlider = false
            cancelRulerFocus()
            return
        }
        let wasEditing = isAdjustingSlider
        if !isEditorDraftActive {
            if editing && !wasEditing {
                guard viewModel.beginAdjustmentInteraction(settings: settings) else { return }
            } else if !editing && (wasEditing || viewModel.adjustmentInteractionRejected) {
                _ = viewModel.endAdjustmentInteraction(settings: settings)
            }
        }
        isAdjustingSlider = editing
        updateRulerFocus(editing: editing, wasEditing: wasEditing)
        if !editing {
            workspaceDraft?.finishInteraction()
            viewModel.updatePreview(settings: draftPreviewSettings, includeHistogram: true, quality: .final)
        }
    }

    func cancelSliderInteraction() {
        hslTargetInteraction.cancel(); hslTargetHistoryActive = false
        hslTargetPoint = nil; hslTargetNotice = nil
        if let original = viewModel.cancelAdjustmentInteraction() {
            settings = original
            viewModel.updatePreview(settings: original, includeHistogram: true, quality: .final)
        }
        isAdjustingSlider = false
        cancelRulerFocus()
    }

    func photoImportButton(isEnabled: Bool) -> some View {
        Button { requestEditorImport(file: false) } label: { Image(systemName: viewModel.hasImage ? "chevron.left" : "photo.badge.plus") }
            .accessibilityLabel(L10n.text("导入照片"))
            .help(L10n.text("从照片图库导入"))
            .accessibilityIdentifier("editor.import")
            .disabled(!isEnabled)
    }

    func fileImportButton(isEnabled: Bool) -> some View {
        Button { requestEditorImport(file: true) } label: { Image(systemName: "folder.badge.plus") }
            .accessibilityLabel(L10n.text("从文件导入"))
            .help(L10n.text("从文件导入"))
            .accessibilityIdentifier("editor.import.file")
            .disabled(!isEnabled)
    }

    func requestEditorImport(file: Bool, recent: RecentPhoto? = nil) {
        guard !editorBusy else { return }
        recentReselection = recent
        photoViewing.endTemporaryViewing()
        pendingFileImport = file
        pendingPhotoImport = !file
        if isEditorDraftChanged { draftExitPresented = true; return }
        if isEditorDraftActive { activateEditorTool(.adjustment(.exposure)) }
        continueEditorImport()
    }

    func requestSystemPhotoImport(_ urls: [URL]) {
        recentReselection = nil
        pendingSystemPhotoURLs = PhotoImportFile.appendSystemPhotoEvent(urls, to: pendingSystemPhotoURLs)
        continueSystemPhotoImport()
    }

    func stageSystemPhotoImport(_ files: [PhotoImportFile]) -> [URL] {
        var seen = Set<URL>()
        var transferred = Set<URL>()
        return files.compactMap { file in
            let sourceURL = file.source.url.standardizedFileURL
            guard seen.insert(sourceURL).inserted else {
                if !transferred.contains(sourceURL) { PhotoImportFile.release(file.source.url) }
                return nil
            }
            do {
                let staged = try PhotoImportFile.renameRetainedSource(file.source.url,
                                                                       filename: file.source.displayName)
                transferred.insert(sourceURL)
                return staged
            } catch {
                PhotoImportFile.release(file.source.url)
                viewModel.reportError(error, operation: .photoImport, stage: "stageDrop",
                                      context: ["entryPoint": "drop"])
                return nil
            }
        }
    }

    func continueSystemPhotoImport() {
        guard !pendingSystemPhotoURLs.isEmpty, !editorBusy else { return }
        photoViewing.endTemporaryViewing()
        cancelSliderInteraction()
        if isEditorDraftChanged { draftExitPresented = true; return }
        if isEditorDraftActive { activateEditorTool(.adjustment(.exposure)) }
        guard viewModel.saveCurrentSettings(settings) else { return }
        guard let event = PhotoImportFile.consumeSystemPhotoEvent(from: pendingSystemPhotoURLs) else { return }
        guard importFromFile(.success(event.current)) else { return }
        pendingSystemPhotoURLs = event.remaining
    }

    func continueEditorImport() {
        guard pendingFileImport || pendingPhotoImport else { return }
        guard viewModel.saveCurrentSettings(settings) else { return }
        if pendingFileImport { documentImportKind = .photo }
        showingDocumentImporter = pendingFileImport
        showingPhotoImporter = pendingPhotoImport
        pendingFileImport = false
        pendingPhotoImport = false
    }

    func requestLookImport() {
        guard !editorBusy, !isEditorDraftActive || currentEditorTool == .film else { return }
        documentImportKind = .looks
        showingDocumentImporter = true
    }

    @MainActor
    func importLooks(_ result: Result<[URL], Error>) {
        guard !editorBusy, !isEditorDraftActive || currentEditorTool == .film else { return }
        let draftID = workspaceDraftID, source = viewModel.sourceRevision
        switch result {
        case .failure(let error):
            viewModel.reportError(error, operation: .lookImport, stage: "filePicker", context: ["entryPoint": "files"])
        case .success(let sources):
            viewModel.importLooks(from: sources, compatibilityPrompt: { source, draft, finish in
                lookCompatibilityCompletion = finish
                confirmedLookCompatibility = nil
                pendingLookCompatibility = .init(source: source, draft: draft)
            }, dcpOptionsPrompt: { source, reason, finish in
                dcpImportOptionsCompletion = finish
                confirmedDCPImportOptions = nil
                pendingDCPImportOptions = .init(source: source, reason: reason)
            }) { report in
                guard workspaceDraftID == draftID, viewModel.sourceRevision == source else { return }
                if case .select(let selectedID) = LookImportSelection.decision(previousID: workingSettings.lutID,
                                                                                imported: report.imported) {
                    var updated = workingSettings
                    if let reason = updated.clearMasterRecipe(context: resetContext) {
                        viewModel.statusMessage = resetBlockedMessage(reason); return
                    }
                    updated.lutID = selectedID
                    applySettingsChange(updated)
                }
                guard let first = report.failures.first else { return }
                let prefix = L10n.format("已导入 %@ 个外观，%@ 个文件导入失败：\n",
                                         String(report.imported.count), String(report.failures.count))
                let details = report.failures.map {
                    "\($0.fileName): \($0.reason.localizedDescription)"
                }.joined(separator: "\n")
                let attemptID = UUID()
                let context = ["entryPoint": "files", "failedCount": String(report.failures.count),
                               "importedCount": String(report.imported.count)]
                viewModel.reportError(first.reason, operation: .lookImport, stage: "importLook",
                                      attemptID: attemptID, context: context, message: prefix + details)
                for failure in report.failures.dropFirst() {
                    ErrorDiagnostics.log(failure.reason, operation: .lookImport, stage: "importLook",
                                         attemptID: attemptID, context: context)
                }
            }
        }
    }

    @MainActor
    func importFromPhotoItem(_ item: PhotosPickerItem, requestID: UUID) async {
        guard photoImportRequestID == requestID, !Task.isCancelled, !isEditorDraftActive else { return }
        guard viewModel.saveCurrentSettings(settings) else {
            selectedPhotoItem = nil
            photoImportTask = nil
            photoImportRequestID = nil
            return
        }
        isImporting = true
        showingBefore = false
        let reselecting = recentReselection
        recentReselection = nil
        do {
            let source = try await loadPhotoSource(from: item)
            var transferred = false
            defer { if !transferred { PhotoImportFile.release(source.url) } }
            var identity = try await viewModel.photoIdentity(for: source, from: item)
            if let reselecting {
                guard identity.contentIdentifier == reselecting.identity.contentIdentifier else {
                    throw RecentPhotoError.originalChanged
                }
                identity = reselecting.identity
            }
            guard photoImportRequestID == requestID, !Task.isCancelled else { return }
            try await resolveLegacyAssetEdit(for: identity)
            guard photoImportRequestID == requestID, !Task.isCancelled else { return }
            transferred = true
            viewModel.importImage(from: source, identity: identity, settings: .default,
                diagnosticContext: ["entryPoint": "photos"],
                onImported: { UsageAnalytics.shared.record(.photoImported) }) { restored in
                guard photoImportRequestID == requestID else { return }
                settings = restored
                if restored.isHDREditing { selectedGroup = .light; selectedAdjustment = .exposure }
            }
            selectedPhotoItem = nil
            photoImportTask = nil
        } catch {
            guard photoImportRequestID == requestID else { return }
            photoImportTask = nil
            photoImportRequestID = nil
            isImporting = false
            selectedPhotoItem = nil
            if !Task.isCancelled && !(error is CancellationError) {
                viewModel.reportError(error, operation: .photoImport, stage: "readPhotoLibrary",
                                      attemptID: requestID, context: ["entryPoint": "photos"])
            }
        }
    }

    func cancelPhotoImport() {
        finishLegacyAssetEditDecision(nil)
        recentReselection = nil
        photoImportRequestID = nil
        photoImportTask?.cancel()
        photoImportTask = nil
        selectedPhotoItem = nil
        viewModel.cancelImageImport()
        isImporting = false
    }

    @MainActor
    @discardableResult
    func resolveLegacyAssetEdit(for identity: PhotoIdentity) async throws -> Bool {
        guard let store = viewModel.editPersistence else { return false }
        let legacy: PhotoEditState?
        do {
            legacy = try store.unverifiedAssetEdit(for: identity)
        } catch is UnusableEditRecordError {
            // 坏旧版资产记录交给 importImage 走单条恢复弹窗，不在入口处提前中断。
            return false
        }
        guard let legacy else { return false }
        let restore = await withCheckedContinuation { continuation in
            legacyAssetEditDecision = continuation
            showingLegacyAssetEdit = true
        }
        try Task.checkCancellation()
        guard let restore else { throw CancellationError() }
        try store.resolveUnverifiedAssetEdit(for: identity, expected: legacy, restore: restore)
        return true
    }

    func finishLegacyAssetEditDecision(_ restore: Bool?) {
        let decision = legacyAssetEditDecision
        legacyAssetEditDecision = nil
        showingLegacyAssetEdit = false
        decision?.resume(returning: restore)
    }

    @MainActor
    @discardableResult
    func importFromFile(_ result: Result<[URL], Error>) -> Bool {
        guard !editorBusy, !isEditorDraftChanged else { return false }
        let urls = PhotoImportFile.fileURLs(from: (try? result.get()) ?? [])
        guard let url = urls.first else {
            recentReselection = nil
            if case .failure(let error) = result, !(error is CancellationError) {
                viewModel.reportError(error, operation: .photoImport, stage: "filePicker", context: ["entryPoint": "files"])
            }
            return false
        }
        guard viewModel.saveCurrentSettings(settings) else { return false }
        if urls.count > 1 {
            isImporting = true
            photoImportTask = Task { @MainActor in
                defer {
                    for url in urls { PhotoImportFile.release(url) }
                    photoImportTask = nil
                    isImporting = false
                }
                for url in urls {
                    guard !Task.isCancelled else { return }
                    do {
                        let photo = try await viewModel.loadAdjustmentPhoto(fromFile: url, workflow: "batchSelection")
                        guard !Task.isCancelled else { return }
                        viewModel.batchSelection.append(photo)
                    } catch {
                        guard !Task.isCancelled else { return }
                        viewModel.batchSelection.append(.init(identity: .init(resourceIdentifier: "unreadable:\(UUID())"),
                            displayName: url.lastPathComponent, file: nil, isRaw: false, error: error))
                    }
                }
                viewModel.batchSelection.selection.returnToCollection()
                showingBatchSelection = true
            }
            return true
        }
        photoImportTask?.cancel()
        let requestID = UUID()
        photoImportRequestID = requestID
        viewModel.cancelImageImport()
        isImporting = true
        showingBefore = false
        let reselecting = recentReselection
        recentReselection = nil
        photoImportTask = Task {
            defer { PhotoImportFile.release(url) }
            let (prepared, context): (Result<(PhotoImportSource, PhotoIdentity?), Error>, [String: String]) = await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var context = ErrorDiagnostics.fileContext(url)
                context["entryPoint"] = "files"
                context["securityScope"] = String(accessing)
                do {
                    let source = try await PhotoImportFile.load(fromFile: url)
                    var transferred = false
                    defer { if !transferred { PhotoImportFile.release(source.url) } }
                    var identity = try PhotoIdentity.fallback(for: source.url)
                    if let reselecting {
                        guard identity.contentIdentifier == reselecting.identity.contentIdentifier else {
                            throw RecentPhotoError.originalChanged
                        }
                        identity = reselecting.identity
                    }
                    transferred = true
                    return (Result.success((source, identity)), context)
                } catch {
                    return (Result.failure(error), context)
                }
            }.value
            guard !Task.isCancelled, photoImportRequestID == requestID else {
                if case .success(let value) = prepared { PhotoImportFile.release(value.0.url) }
                return
            }
            switch prepared {
            case .success(let value):
                photoImportTask = nil
                viewModel.importImage(from: value.0, identity: value.1, settings: .default,
                                      diagnosticContext: context,
                                      onImported: { UsageAnalytics.shared.record(.photoImported) }) { restored in
                    settings = restored
                if restored.isHDREditing { selectedGroup = .light; selectedAdjustment = .exposure }
                }
            case .failure(let error):
                photoImportTask = nil
                photoImportRequestID = nil
                isImporting = false
                if !Task.isCancelled {
                    viewModel.reportError(error, operation: .photoImport, stage: "retainPickerSource",
                                          attemptID: requestID, context: context)
                }
            }
        }
        return true
    }

    func openBatchExport() {
        guard !isEditorDraftActive else { return }
        if batchModel != nil { showingBatchExport = true; return }
        guard let source = viewModel.currentBatchSource(settings: settings) else {
            viewModel.statusMessage = L10n.text("请先导入一张照片。")
            return
        }
        batchModel = BatchExportModel(source: source, editor: viewModel)
        batchModel?.onUsage = { UsageAnalytics.shared.record($0) }
        batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false }
        showingBatchExport = true
    }

    func recoverBatchExport() {
        do {
            let journal = try BatchJournalStore.appStore()
            if let job = try journal.pendingJobs().first {
                batchModel = BatchExportModel(job:job,journalStore:journal,editor:viewModel)
                batchModel?.onUsage = { UsageAnalytics.shared.record($0) }
                batchModel?.onDiscard = { batchModel = nil; showingBatchExport = false; recoverBatchExport() }
            }
        } catch {
            viewModel.reportError(error, operation: .batchExport, stage: "recover",
                                  message: L10n.format("无法读取上次批量任务：%@", error.localizedDescription))
        }
    }

    func loadPhotoSource(from item: PhotosPickerItem) async throws -> PhotoImportSource {
        try await PhotoImportFile.loadSource { try await PhotoImportFile.load(from: item) }
    }

    func saveToPhotoLibrary(_ data: Data, format: BatchOutputFormat) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    viewModel.reportError(NSError(domain: "RawLab.PhotoLibrary", code: status.rawValue),
                                          operation: .photoExport, stage: "photoLibraryPermission",
                                          message: L10n.text("无法保存照片，请在系统设置中允许添加照片。"))
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = (format == .hdrHEIF ? UTType.heic : .jpeg).identifier
                request.addResource(with: .photo, data: data, options: options)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    isSaving = false
                    if let error = error {
                        viewModel.reportError(error, operation: .photoExport, stage: "savePhotoLibrary")
                    } else if success {
                        UsageAnalytics.shared.record(.exportCompleted)
                        viewModel.statusMessage = L10n.text("已保存到照片。")
                    } else {
                        viewModel.reportError(NSError(domain: "RawLab.PhotoLibrary", code: -1),
                                              operation: .photoExport, stage: "savePhotoLibrary",
                                              message: L10n.text("保存失败，请重试。"))
                    }
                }
            })
        }
    }
}
