import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension EditorModel {
    func editState(settings: Adjustments) -> PhotoEditState {
        let filmID = selectedFilm.map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" } ?? selectedFilmID
        return PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: settings.masterRecipeID)
    }

    func prepareReset(scope: EditorResetScope) -> ResetPreparation {
        guard let file, let identity = try? OriginalFileIdentity(file) else { return .blocked(.sourceUnavailable) }
        let isGeometry = scope.usesGeometryDraft
        if geometryDraft != nil && !isGeometry { return .blocked(.geometryDraftActive) }
        if isGeometry && geometryDraft == nil { return .blocked(.geometryDraftRequired) }
        if scope == .tool(.geometry) && geometryDraftTab == .lens || scope == .tool(.lens) && geometryDraftTab != .lens {
            return .blocked(.geometryDraftRequired)
        }
        guard invalidGeometryDraftInputs.isEmpty else { return .blocked(.invalidDraftInputs) }
        let context = EditorAdjustmentContext(isRaw: !RenderEngine.isRasterInput(file),
                                              defaultExposureMode: RenderEngine.isRasterInput(file) ? .sensor : Adjustments().exposureMode, neutralFilmID: "")
        let original = editState(settings: settings)
        var snapshot = original
        if let draft = geometryDraft {
            if case .blocked(let reason) = EditorAdjustmentRules.prepareReset(scope: scope, snapshot: original, context: context) {
                return .blocked(.adjustment(reason))
            }
            snapshot.settings.geometry = draft.geometry.isIdentity ? nil : draft.geometry
            snapshot.settings.lensCorrection = draft.lens == LensCorrectionSettings() ? nil : draft.lens
        }
        switch EditorAdjustmentRules.prepareReset(scope: scope, snapshot: snapshot, context: context) {
        case .unchanged: return .unchanged
        case .blocked(let reason): return .blocked(.adjustment(reason))
        case .candidate(let candidate):
            return .prepared(PreparedReset(scope: scope, source: file, identity: identity, revision: editRevision,
                                           original: original, candidate: candidate,
                                           selectedFilmID: selectedFilmID, draft: geometryDraft))
        }
    }

    @discardableResult func commitReset(_ prepared: PreparedReset) -> Bool {
        guard file == prepared.source, editRevision == prepared.revision,
              (try? OriginalFileIdentity(prepared.source)) == prepared.identity,
              editState(settings: settings) == prepared.original,
              selectedFilmID == prepared.selectedFilmID, geometryDraft == prepared.draft,
              invalidGeometryDraftInputs.isEmpty else { return false }
        if var draft = prepared.draft {
            let previousPreview = draft.previewGeometry, previousLens = draft.lens
            draft.geometry = prepared.candidate.settings.geometrySettings
            draft.lens = prepared.candidate.settings.lensSettings
            guard draft != geometryDraft else { return true }
            geometryDraft = draft
            if draft.geometry != prepared.draft?.geometry { cropAspectPreset = .free; cropAspectSwapped = false }
            geometryDraftRevision &+= 1
            if previousPreview != draft.previewGeometry || previousLens != draft.lens {
                geometryDraftPreviewReady = false
                schedule()
            }
        } else {
            guard prepared.candidate != prepared.original else { return true }
            if [.all, .group(.detail), .tool(.denoise)].contains(prepared.scope) { resetAITask() }
            updatingMetadata = true
            settings = prepared.candidate.settings
            // 普通组保留 UI selection；存储 ID 可能是 builtin:<filename>。
            if prepared.candidate.filmID != prepared.original.filmID { selectedFilmID = "" }
            updatingMetadata = false
            edited()
        }
        return true
    }

    var adjustmentContext: EditorAdjustmentContext {
        EditorAdjustmentContext(isRaw: !RenderEngine.isRasterInput(file),
            defaultExposureMode: RenderEngine.isRasterInput(file) ? .sensor : Adjustments().exposureMode, neutralFilmID: "")
    }

    func isAdjustmentModified(_ scope: EditorResetScope) -> Bool {
        var snapshot = editState(settings: settings)
        if let draft = geometryDraft {
            snapshot.settings.geometry = draft.geometry.isIdentity ? nil : draft.geometry
            snapshot.settings.lensCorrection = draft.lens == LensCorrectionSettings() ? nil : draft.lens
        }
        return EditorAdjustmentRules.isModified(scope: scope, snapshot: snapshot, context: adjustmentContext)
    }

    func selectAdjustmentGroup(_ group: EditorAdjustmentGroup) {
        var target = adjustmentNavigation
        target.selectGroup(group)
        navigateAdjustment(to: target)
    }

    func selectAdjustmentTool(_ tool: EditorAdjustmentTool) {
        guard tool != adjustmentNavigation.tool || adjustmentNavigation.expandedGroup == nil else { return }
        var target = adjustmentNavigation; target.selectTool(tool)
        navigateAdjustment(to: target)
    }

    func selectAdjustmentGeometryTab(_ tab: MacGeometryTab) {
        let tool: EditorAdjustmentTool = tab == .lens ? .lens : .geometry
        if geometryDraft != nil && adjustmentNavigation.tool == tool {
            _ = selectGeometryDraftTab(tab)
            return
        }
        var target = adjustmentNavigation; target.selectTool(tool)
        navigateAdjustment(to: target, geometryTab: tab)
    }

    private func navigateAdjustment(to target: EditorAdjustmentNavigation, geometryTab: MacGeometryTab? = nil) {
        cancelHSLTarget(); hslTargetEnabled = false
        if adjustmentNavigation.tool == .colorGrading || adjustmentNavigation.tool == .toneCurve { cancelAdjustmentInteraction() }
        ParameterValueField.cancelPendingInputs()
        guard resetReturnTool == nil, resetConfirmation == nil else { return }
        let action = { [weak self] in
            guard let self else { return }
            if target.expandedGroup != nil && target.tool.usesGeometryDraft {
                guard self.beginGeometryDraft(tab: geometryTab ?? (target.tool == .lens ? .lens : .crop)) else { return }
            }
            self.adjustmentNavigation = target
        }
        if geometryDraft != nil { requestLeavingGeometryDraft(action) }
        else { action() }
    }

    func requestAdjustmentReset(_ scope: EditorResetScope) {
        cancelHSLTarget()
        ParameterValueField.cancelPendingInputs()
        guard !busy, !exporting, !lookLibraryBusy, resetConfirmation == nil, resetReturnTool == nil else { return }
        if scope == .all, geometryDraft != nil {
            if !geometryDraftHasChanges && !isAdjustmentModified(.all) { return }
            resetReturnTool = adjustmentNavigation.tool
            resetReturnGeometryTab = geometryDraftTab
            resetSource = file
            requestLeavingGeometryDraft({ [weak self] in self?.prepareAdjustmentReset(scope) }, onStay: { [weak self] in
                self?.resetReturnTool = nil; self?.resetReturnGeometryTab = nil; self?.resetSource = nil
            })
        } else { prepareAdjustmentReset(scope) }
    }

    private func prepareAdjustmentReset(_ scope: EditorResetScope) {
        switch prepareReset(scope: scope) {
        case .unchanged:
            if [.all, .group(.detail), .tool(.denoise)].contains(scope) {
                let wasPreparing = aiManuallyRequested
                resetAITask()
                if wasPreparing { schedule() }
            }
            resumeResetToolIfReady()
        case .blocked(let reason): resetBlockedMessage = resetMessage(reason); resumeResetToolIfReady()
        case .prepared(let prepared):
            let needsConfirmation: Bool
            switch scope {
            case .all, .group, .hslAll, .allGrading, .tool(.hsl), .tool(.colorGrading): needsConfirmation = true
            case .tool(.film), .tool(.recipe): needsConfirmation = !resetConversions(prepared).isEmpty
            default: needsConfirmation = false
            }
            if needsConfirmation { resetConfirmationScope = scope; resetConfirmation = prepared }
            else if !commitReset(prepared) { resetBlockedMessage = L10n.text("照片或调整已变化，请重新确认重置。") }
        }
    }

    func finishAdjustmentReset(confirm: Bool) {
        let candidate = resetConfirmation
        resetConfirmation = nil; resetConfirmationScope = nil
        if confirm, let candidate, !commitReset(candidate) {
            resetBlockedMessage = L10n.text("照片或调整已变化，请重新确认重置。")
        }
        resumeResetToolIfReady()
    }

    func resumeResetToolIfReady() {
        guard resetConfirmation == nil, let tool = resetReturnTool else { return }
        guard file == resetSource else { resetReturnTool = nil; resetReturnGeometryTab = nil; resetSource = nil; return }
        guard !busy, pendingGeometryPresentation == nil else { return }
        if tool.usesGeometryDraft {
            guard beginGeometryDraft(tab: resetReturnGeometryTab ?? (tool == .lens ? .lens : .crop)) else { return }
        }
        adjustmentNavigation.selectTool(tool)
        resetReturnTool = nil; resetReturnGeometryTab = nil; resetSource = nil
    }

    func resetConversions(_ prepared: PreparedReset) -> [String] {
        let before = prepared.original.settings, after = prepared.candidate.settings
        guard before.masterRecipeID != nil, after.masterRecipeID == nil else { return [] }
        var changes = [String]()
        for parameter in [AdjustmentParameter.exposure, .contrast, .highlights, .shadows, .saturation, .temperature, .tint,
                          .blackPoint, .whitePoint, .vibrance, .clarity, .dehaze] {
            if before[keyPath: parameter.spec.keyPath] != after[keyPath: parameter.spec.keyPath] { changes.append(parameter.spec.title) }
        }
        if before.whiteBalanceMode != after.whiteBalanceMode { changes.append(L10n.text("白平衡")) }
        if before.hslSettings != after.hslSettings { changes.append("HSL") }
        if before.toneCurve != after.toneCurve || before.curveSettings != after.curveSettings { changes.append(L10n.text("曲线")) }
        if before.gradingSettings != after.gradingSettings { changes.append(L10n.text("颜色分级")) }
        return changes
    }

    private func resetMessage(_ reason: ResetBlockedReason) -> String {
        switch reason {
        case .adjustment(.missingAsShotWhiteBalance): return L10n.text("缺少拍摄时白平衡数据，无法保留配方效果。")
        case .adjustment(.unrepresentableRecipe): return L10n.text("现有参数范围无法保留配方的全部效果。你可以取消，或另行确认重置全部调整。")
        case .adjustment(.invalidSnapshot("masterRecipe")), .adjustment(.invalidSnapshot("masterRecipeID")):
            return L10n.text("当前配方不可用，无法安全重置外观。")
        case .geometryDraftActive, .geometryDraftRequired, .invalidDraftInputs: return L10n.text("预览尚未就绪，请稍后重试。")
        default: return L10n.text("当前照片或调整记录无效，无法安全重置。")
        }
    }

    func selectMasterRecipe(_ recipe: MasterRecipe?) {
        guard geometryDraft == nil else { return }
        guard recipe != nil || settings.masterRecipeID != nil else { return }
        updatingMetadata = true
        if let recipe {
            settings.applyMasterRecipe(recipe)
            selectedFilmID = ""
        } else {
            guard settings.clearMasterRecipe(isRaw: adjustmentContext.isRaw) else {
                updatingMetadata = false
                resetBlockedMessage = L10n.text("现有参数范围无法保留配方的全部效果。你可以取消，或另行确认重置全部调整。")
                return
            }
        }
        updatingMetadata = false
        edited()
    }

    func selectFilm(_ id: String) {
        guard (id != selectedFilmID || settings.masterRecipeID != nil),
              id.isEmpty || filmChoices.contains(where: { $0.id == id }) else { return }
        selectedFilmID = id
        guard selectedFilmID == id, settings.masterRecipeID == nil else { return }
        onUsage(.filmSelected(id.isEmpty ? .none : selectedFilm?.managedID == nil ? .builtIn : .custom))
    }

    func edited() {
        editRevision = UUID()
        guard file != nil else { return }
        synchronizeAI()
        dirty = true
        saveStatusKey = ""
        saveWork?.cancel()
        if !scheduler.interacting {
            // 同一个原生事件的联动 setter 合为一次；拖动由 begin/end 明确提交。
            let work = DispatchWorkItem { [weak self] in _ = self?.saveEdits() }
            saveWork = work
            DispatchQueue.main.async(execute: work)
        }
        schedule()
    }

    @discardableResult func saveEdits() -> Bool {
        saveWork?.cancel()
        guard file != nil, dirty else { return true }
        guard !scheduler.interacting, commitAdjustment(editState(settings: settings)) else { return false }
        dirty = false
        return true
    }

    func clearSaveStatusLater() {
        let message = saveStatusKey
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.saveStatusKey == message { self?.saveStatusKey = "" }
        }
    }

    @discardableResult func applyCurrentSettings(to urls: [URL]) throws -> Int {
        guard file != nil, !exporting, !aiState.isRunning, !lookLibraryBusy, !missingFilm, !missingMasterRecipe, geometryDraft == nil else {
            throw RenderError.failed(L10n.text("当前照片的设置尚不可用。"))
        }
        let sourcePath = file!.resolvingSymlinksInPath().standardizedFileURL.path
        let targets = Array(Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL })).filter { $0.path != sourcePath }
        guard !targets.isEmpty else { return 0 }
        guard saveEdits(), let file else { throw AdjustmentTransferError.draftRequiresPreflight }
        let payload = try MacAdjustmentTransfer.capture(scope: .standard, snapshot: editState(settings: settings),
            context: adjustmentTransferContext(for: file))
        let operation = try prepareAdjustmentPaste(payload: payload, targets: targets, excludingSource: sourcePath)
        applyAdjustmentPaste(operation)
        if let failure = adjustmentOutcomes.first(where: { [.blocked, .failed, .conflict].contains($0.status) }) {
            throw failure.error ?? AdjustmentTransferError.incompatible("target")
        }
        let count = adjustmentOutcomes.filter { $0.status == .applied || $0.status == .unchanged }.count
        statusState = .applied(count)
        return count
    }

    func confirmApplySettings(to url: URL, directory: Bool) {
        guard canApplySettings, adjustmentSheet == nil, let file else { return }
        do {
            let sourcePath = file.resolvingSymlinksInPath().standardizedFileURL.path
            let targets = (directory ? try DirectoryContents.read(url).photos : [url])
                .filter { $0.resolvingSymlinksInPath().standardizedFileURL.path != sourcePath }
            guard !targets.isEmpty else { throw RenderError.failed(L10n.text("没有可处理目标，请重新选择照片。")) }
            guard ParameterValueField.resolvePendingInputs(), saveEdits() else { return }
            adjustmentSheetPayload = try MacAdjustmentTransfer.capture(scope: .standard,
                snapshot: editState(settings: settings), context: adjustmentTransferContext(for: file))
            adjustmentSheetTargets = targets
            adjustmentSheetExcludedSource = sourcePath
            pendingAdjustmentHistory = nil
            adjustmentSheetInCollection = false; adjustmentSheet = .paste
        } catch { self.error = error.localizedDescription }
    }

    func prepareBatch() -> Bool {
        guard canExport, let file else { return false }
        if batch?.validating == true || batch?.previewing == true { return true }
        if let batch, batch.job.started && batch.job.succeededCount < batch.job.selectedCount {
            let alert = NSAlert()
            alert.messageText = L10n.text("上次批量任务尚未完成")
            alert.informativeText = L10n.text("继续查看上次任务，或保留已导出文件并新建任务。")
            alert.addButton(withTitle: L10n.text("查看任务")); alert.addButton(withTitle: L10n.text("新建任务"))
            if alert.runModal() == .alertFirstButtonReturn { return true }
        }
        do {
            if let batch { try batchJournal.discard(batch.job) }
            let lookURL = settings.masterRecipe?.lutURL() ?? selectedFilm?.url
            let lookName = settings.masterRecipe?.title ?? selectedFilm?.name ?? "中性"
            var job = BatchExportJob(source: file, settings: settings, look: nil, lookName: lookName)
            job.longEdge = exportLongEdge
            job.look = try batchJournal.snapshotLook(lookURL, for: job.id)
            try batchJournal.save(job)
            attachBatch(job)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func attachBatch(_ job: BatchExportJob) {
        let model = BatchExportModel(job: job, journal: batchJournal, onUsage: onUsage)
        model.sourceEditingGeometry = geometryDraft != nil
        model.onActivity = { [weak self] active in self?.exporting = active }
        model.onDiscard = { [weak self] in self?.batch = nil }
        batch = model
    }

    func openPanel() {
        ParameterValueField.cancelPendingInputs()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L10n.text("打开照片")
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        let url = (try? BatchExportItem.resourceKey(url)).flatMap { batchSelectionPhotos[$0]?.url } ?? url
        guard !exporting else { return }
        cancelHSLTarget()
        if file == url && result != nil, acceptedOriginalSource == MacReferenceSource(url, raster: RenderEngine.isRasterInput(url)) { return }
        ParameterValueField.cancelPendingInputs()
        if geometryDraft != nil {
            requestLeavingGeometryDraft { [weak self] in self?.open(url) }
            return
        }
        if [.colorGrading, .toneCurve].contains(adjustmentNavigation.tool) { cancelAdjustmentInteraction() }
        if scheduler.interacting { setInteracting(false) }
        guard saveEdits() else { return }
        let restoredRecord: VersionedPhotoEdit
        do {
            _ = try requireAdjustmentSession()
            restoredRecord = try editStore!.versionedState(for: url)
        } catch {
            saveError = L10n.format("无法恢复调整：%@", String(describing: error.localizedDescription))
            return
        }
        resetAITask()
        cancelViewportResize()
        committedEdit = restoredRecord
        let restored = restoredRecord.state
        editRevision = UUID()
        scheduler.setInteracting(false)
        sourceRevision = UUID()
        file = url; neutral = nil; result = nil; error = nil; previewOutdated = false; statusState = .none
        pendingImportEvent = true
        updatingMetadata = true
        settings = restored?.settings ?? Adjustments()
        if restored == nil && RenderEngine.isRasterInput(url) { settings.exposureMode = .sensor }
        if let masterRecipeID = restored?.masterRecipeID {
            settings.masterRecipeID = masterRecipeID
        }
        let filmID = restored?.filmID ?? ""
        if settings.masterRecipeID != nil {
            selectedFilmID = ""
        } else {
            selectedFilmID = films.first(where: { $0.id == filmID || "builtin:\($0.url.lastPathComponent)" == filmID })?.id ?? filmID
        }
        updatingMetadata = false
        dirty = false
        saveStatusKey = restored == nil ? "" : "已恢复上次调整"
        clearSaveStatusLater()
        schedule()
    }
    func autoExposure() {
        guard let file, result != nil, !autoExposing, !exporting, geometryDraft == nil else { return }
        let snapshot = settings, revision = editRevision
        autoExposing = true
        queue.async { [weak self] in
            let result = Result { try RenderEngine().autoExposure(file, settings: snapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.autoExposing = false
                guard self.file == file, self.editRevision == revision, self.settings == snapshot else { return }
                switch result {
                case .success(let ev): self.settings.exposure = ev
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func importLUT() {
        guard !lookLibraryBusy, !exporting, geometryDraft == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入外观")
        panel.allowedContentTypes = ["cube", "vlt", "rlook", "dcp"].map { UTType(filenameExtension: $0) ?? .data }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            importLooks(panel.urls)
        }
    }

    func importLook(_ url: URL) {
        importLooks([url])
    }

    func importLooks(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let previewPhoto = file.map { LUTPreviewSource(url: $0) }
        changeLookLibrary { library in
            var selectedID: String?
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        selectedID = try library.importLook(from: url).id
                    } catch {
                        guard (error as? LookLibraryError)?.needsCompatibility == true else { throw error }
                        guard let draft = try LUTCompatibility.inspect(url) else { throw error }
                        let completion = DispatchSemaphore(value: 0)
                        var confirmed: LUTCompatibility?
                        DispatchQueue.main.async {
                            LUTCompatibilityDialog.present(source: url, draft: draft, photo: previewPhoto) { value in
                                confirmed = value
                                completion.signal()
                            }
                        }
                        completion.wait()
                        guard let confirmed else { continue }
                        selectedID = try library.importLook(from: url, compatibility: confirmed).id
                    }
                    imported += 1
                } catch {
                    failures.append(L10n.format("%@：%@", url.lastPathComponent, error.localizedDescription))
                }
            }
            let report = failures.isEmpty ? nil :
                L10n.format("已导入 %@ 个外观，%@ 个文件导入失败：\n", String(describing: imported), String(describing: failures.count)) + failures.joined(separator: "\n")
            return (selectedID, report)
        }
    }

    func renameLook(id: String, name: String) {
        changeLookLibrary { try $0.rename(id: id, to: name); return (nil, nil) }
    }

    func removeLook(id: String) {
        changeLookLibrary { try $0.remove(id: id); return (nil, nil) }
    }

    func renameLookPanel(_ film: Film) {
        guard let id = film.managedID, !lookLibraryBusy, !exporting else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("重命名外观")
        alert.addButton(withTitle: L10n.text("保存"))
        alert.addButton(withTitle: L10n.text("取消"))
        let field = NSTextField(string: film.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { renameLook(id: id, name: field.stringValue) }
    }

    func removeLookPanel(_ film: Film) {
        guard let id = film.managedID, !lookLibraryBusy, !exporting else { return }
        let alert = NSAlert()
        alert.messageText = L10n.format("移除“%@”？", String(describing: film.name))
        alert.informativeText = L10n.text("将移除 RawLab 保存的外观副本，原始文件不会被删除。")
        alert.addButton(withTitle: L10n.text("移除"))
        alert.addButton(withTitle: L10n.text("取消"))
        if alert.runModal() == .alertFirstButtonReturn { removeLook(id: id) }
    }

    private func changeLookLibrary(_ operation: @escaping (LookLibrary) throws -> (selectedID: String?, report: String?)) {
        guard !lookLibraryBusy, !exporting else { return }
        guard let library = lookLibrary else { error = LookLibraryError.invalidRegistry.localizedDescription; return }
        lookLibraryBusy = true
        lookImportReport = nil
        // 与渲染共用串行队列，移除外观时不会删除正在读取的文件。
        queue.async { [weak self] in
            do {
                let change = try operation(library)
                let updated = library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id, colorNotice: $0.colorNotice, isCompatibility: $0.isCompatibility) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.films = self.films.filter { $0.managedID == nil } + updated
                    self.lookLibraryBusy = false
                    self.error = nil
                    if let selectedID = change.selectedID { self.selectedFilmID = selectedID }
                    else if !self.selectedFilmID.isEmpty && !self.films.contains(where: { $0.id == self.selectedFilmID }) {
                        self.schedule()
                    }
                    self.lookImportReport = change.report
                }
            } catch {
                DispatchQueue.main.async {
                    self?.lookLibraryBusy = false
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    func export(png: Bool) {
        export(format: png ? .png : .jpeg)
    }

    func export(format: ExportFormat) {
        guard canExport, let file else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let lookName = settings.masterRecipe?.title ?? selectedFilm?.name ?? "neutral"
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "-" +
            lookName + "." + format.suffix
        let sizePicker = NSHostingView(rootView: ExportSizeAccessory(model: self).padding(12).frame(width: 360))
        sizePicker.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        panel.accessoryView = sizePicker
        guard panel.runModal() == .OK, let output = panel.url else { return }
        export(to: output)
    }

    func export(to output: URL) {
        guard canExport, let file else { return }
        exporting = true
        let settings = settings, lut = settings.masterRecipe?.lutURL() ?? selectedFilm?.url, longEdge = exportLongEdge
        let generation = aiGeneration
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.engine == nil { self.engine = try RenderEngine() }
                _ = try self.engine!.render(file, settings: settings, lut: lut, edge: nil, output: output,
                                             interactive: false, exportLongEdge: longEdge)
                DispatchQueue.main.async {
                    self.exporting = false; self.statusState = .exported(output.lastPathComponent)
                    self.onUsage(.exportCompleted)
                }
            } catch {
                DispatchQueue.main.async {
                    self.exporting = false; self.error = error.localizedDescription
                    if self.file == file, self.settings == settings, self.aiGeneration == generation {
                        self.handleAIFailure(error)
                    }
                }
            }
        }
    }
}
