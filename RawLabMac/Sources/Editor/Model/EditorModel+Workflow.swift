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
        let isGeometry = scope == .group(.geometry)
        if geometryDraft != nil && !isGeometry { return .blocked(.geometryDraftActive) }
        if isGeometry && geometryDraft == nil { return .blocked(.geometryDraftRequired) }
        guard invalidGeometryDraftInputs.isEmpty else { return .blocked(.invalidDraftInputs) }
        let context = EditorAdjustmentContext(isRaw: !RenderEngine.isRasterInput(file),
                                              defaultExposureMode: Adjustments().exposureMode, neutralFilmID: "")
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
            return .prepared(PreparedReset(source: file, identity: identity, revision: editRevision,
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
            cropAspectPreset = .free; cropAspectSwapped = false
            geometryDraftRevision &+= 1
            if previousPreview != draft.previewGeometry || previousLens != draft.lens {
                geometryDraftPreviewReady = false
                schedule()
            }
        } else {
            guard prepared.candidate != prepared.original else { return true }
            updatingMetadata = true
            settings = prepared.candidate.settings
            // 普通组保留 UI selection；存储 ID 可能是 builtin:<filename>。
            if prepared.candidate.filmID != prepared.original.filmID { selectedFilmID = "" }
            updatingMetadata = false
            edited()
        }
        return true
    }

    func selectMasterRecipe(_ recipe: MasterRecipe?) {
        guard geometryDraft == nil else { return }
        guard recipe != nil || settings.masterRecipeID != nil else { return }
        updatingMetadata = true
        if let recipe {
            settings.applyMasterRecipe(recipe)
            selectedFilmID = ""
        } else {
            settings.clearMasterRecipe()
        }
        updatingMetadata = false
        edited()
    }

    func selectFilm(_ id: String) {
        guard (id != selectedFilmID || settings.masterRecipeID != nil),
              id.isEmpty || films.contains(where: { $0.id == id }) else { return }
        selectedFilmID = id
        onUsage(.filmSelected(id.isEmpty ? .none : selectedFilm?.managedID == nil ? .builtIn : .custom))
    }

    func edited() {
        editRevision = UUID()
        guard file != nil else { return }
        dirty = true
        saveStatusKey = ""
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.saveEdits() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        schedule()
    }

    @discardableResult func saveEdits() -> Bool {
        saveWork?.cancel()
        guard let file, dirty else { return true }
        do {
            if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
            try editStore!.save(file, state: editState(settings: settings))
            dirty = false; saveError = nil; saveStatusKey = "调整已保存"
            clearSaveStatusLater()
            return true
        } catch {
            saveError = L10n.format("调整未保存：%@", String(describing: error.localizedDescription))
            return false
        }
    }

    func clearSaveStatusLater() {
        let message = saveStatusKey
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.saveStatusKey == message { self?.saveStatusKey = "" }
        }
    }

    @discardableResult func applyCurrentSettings(to urls: [URL]) throws -> Int {
        guard file != nil, !exporting, !lookLibraryBusy, !missingFilm, !missingMasterRecipe, geometryDraft == nil else {
            throw RenderError.failed(L10n.text("当前照片的设置尚不可用。"))
        }
        let targets = Array(Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }))
        guard !targets.isEmpty else { return 0 }
        let filmID = selectedFilm.map { $0.managedID ?? "builtin:\($0.url.lastPathComponent)" } ?? selectedFilmID
        if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
        try editStore!.save(targets, state: PhotoEditState(settings: settings, filmID: filmID, masterRecipeID: settings.masterRecipeID))
        statusState = .applied(targets.count)
        return targets.count
    }

    func confirmApplySettings(to url: URL, directory: Bool) {
        guard canApplySettings else { return }
        do {
            let targets = directory ? try DirectoryContents.read(url).photos : [url]
            guard !targets.isEmpty else { throw RenderError.failed(L10n.text("此目录没有照片。")) }
            let alert = NSAlert()
            alert.messageText = L10n.format("应用当前设置到 %@ 张照片？", String(describing: targets.count))
            alert.informativeText = L10n.text("将替换目标照片的本机调整记录，不改写原始文件。") +
                (directory ? L10n.text("仅包含此目录中的照片，不包含子目录。") : "")
            alert.addButton(withTitle: L10n.text("应用当前设置")); alert.addButton(withTitle: L10n.text("取消"))
            if alert.runModal() == .alertFirstButtonReturn { try applyCurrentSettings(to: targets) }
        } catch { self.error = error.localizedDescription }
    }

    func prepareBatch() -> Bool {
        guard !busy, !exporting, !lookLibraryBusy, result != nil, !missingFilm, !missingMasterRecipe, geometryDraft == nil, let file else { return false }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L10n.text("打开照片")
        panel.allowedContentTypes = DirectoryContents.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !exporting else { return }
        if file == url && result != nil { return }
        if geometryDraft != nil {
            requestLeavingGeometryDraft { [weak self] in self?.open(url) }
            return
        }
        guard saveEdits() else { return }
        let restored: PhotoEditState?
        do {
            if editStore == nil { editStore = try EditPersistence(directory: editDirectory) }
            restored = try editStore!.state(for: url)
        } catch {
            saveError = L10n.format("无法恢复调整：%@", String(describing: error.localizedDescription))
            return
        }
        cancelViewportResize()
        editRevision = UUID()
        scheduler.setInteracting(false)
        file = url; neutral = nil; result = nil; error = nil; statusState = .none
        pendingImportEvent = true
        updatingMetadata = true
        settings = restored?.settings ?? Adjustments()
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
        panel.allowedContentTypes = ["cube", "rlook", "dcp"].map { UTType(filenameExtension: $0) ?? .data }
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
        changeLookLibrary { library in
            var selectedID: String?
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    selectedID = try library.importLook(from: url).id
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
                let updated = library.looks.map { Film(name: $0.name, url: library.url(for: $0), managedID: $0.id) }
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
        guard !busy, !exporting, !lookLibraryBusy, !missingFilm, !missingMasterRecipe, result != nil, geometryDraft == nil, let file else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let lookName = settings.masterRecipe?.title ?? selectedFilm?.name ?? "neutral"
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "-" +
            lookName + "." + format.suffix
        let sizePicker = NSHostingView(rootView: ExportSizeAccessory(model: self).padding(12).frame(width: 360))
        sizePicker.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        panel.accessoryView = sizePicker
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exporting = true
        let settings = settings, lut = settings.masterRecipe?.lutURL() ?? selectedFilm?.url, longEdge = exportLongEdge
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
                DispatchQueue.main.async { self.exporting = false; self.error = error.localizedDescription }
            }
        }
    }
}
