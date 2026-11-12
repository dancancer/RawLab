import AppKit

enum BatchFlowModelTests {
    static func uneditedFallbackCollection(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("unedited-fallback-collection")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent("gain-map.jpg")
        let source = CGImageSourceCreateWithURL(fixture as CFURL, nil)!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        try require(CGImageDestinationFinalize(destination), "unedited fallback fixture is generated")
        var data = try Data(contentsOf: photo)
        // 旧系统探测由注入模拟；ISO 声明使再次调用系统探测无法悄悄当作普通 JPEG 通过。
        data.append(Data("urn:iso:std:iso:ts:21496:-1".utf8))
        try data.write(to: photo)
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        var probes = 0
        model.probeHDRSource = { url, onSDRFallback in
            probes += 1
            return try HDRSourceProbeTests.unsupportedSystem(url, onSDRFallback: onSDRFallback)
        }
        model.addCollectionPhotos([photo])
        let review = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: directory)
        try require(review.ready && review.snapshots.count == 1,
                    "unedited macOS 14 gain maps prepare for SDR export without a strict re-probe")
        let snapshot = review.snapshots[0]
        try require(snapshot.record.state == nil && snapshot.settings.hdr == nil,
                    "unedited fallback defaults leave HDR disabled without an edit record")
        try require(snapshot.noticeKey == "此照片的 HDR 需 macOS 15 才能编辑，将按 SDR 导出。" && probes == 1,
                    "unedited fallback collection reuses one probe and reports SDR export (probes: \(probes))")
        try require(try model.editStore!.state(for: photo) == nil,
                    "fallback collection preparation does not create an edit record")
        let payload = try AdjustmentTransferPayload(source: .init(identifier: "saved-preset", isRaw: false,
            processingVersion: 2, recipe: nil), values: ["light.exposure": .number(0.6)])
        let paste = try model.prepareAdjustmentPaste(payload: payload, targets: [photo])
        model.applyAdjustmentPaste(paste)
        try require(model.adjustmentOutcomes.first?.status == .applied &&
                    model.editStore?.state(for: photo)?.settings.exposure == 0.6,
                    "fallback preset targets reuse the injected probe and centralized SDR defaults")
        var savedHDR = Adjustments(); savedHDR.hdr = HDRSettings()
        try model.editStore!.save(photo, state: PhotoEditState(settings: savedHDR, filmID: ""))
        let savedRecord = try model.editStore!.readState(for: photo)
        var batchSource = savedHDR; batchSource.hdr?.exposure = 0.4
        let preparation = MacHDRBatchPreparation(source: fixture, settings: batchSource, store: model.editStore!, films: [],
            probeHDRSource: HDRSourceProbeTests.unsupportedSystem)
        let frozen = try preparation.prepare(BatchExportItem(url: photo), ordinal: 0, format: .jpeg, longEdge: nil)
        try require(!frozen.settings.isHDREditing && frozen.settings.exposure == 0.4 &&
                    model.editStore!.readState(for: photo) == savedRecord,
                    "HDR uniform batch uses fallback SDR settings without rewriting the saved HDR layer")
        try require(snapshot.settings.exposureMode == .sensor,
                    "unedited fallback defaults retain sensor exposure")
    }

    static func unsupportedHDRSystem(root: URL, fixture: URL, exerciseOpening: Bool = true) throws {
        let directory = root.appendingPathComponent("unsupported-hdr-system")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent("gain-map.jpg")
        let source = CGImageSourceCreateWithURL(fixture as CFURL, nil)!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        try require(CGImageDestinationFinalize(destination), "SDR base fixture is generated")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.probeHDRSource = HDRSourceProbeTests.unsupportedSystem
        if exerciseOpening {
            model.open(photo); try BatchSelectionModelTests.rendered(model)
            try require(!model.sourceIsHDR && !model.settings.isHDREditing && model.result?.hdr == nil,
                        "unsupported-system single opens render the SDR base")
            try require(model.saveStatusKey == "此照片的 HDR 需 macOS 15 才能编辑，已按 SDR 打开。",
                        "single opens show a nonblocking fallback notice after rendering")
            model.saveStatusKey = ""
            model.settings.exposure = 0.4; try BatchSelectionModelTests.rendered(model)
            try require(model.saveStatusKey != "此照片的 HDR 需 macOS 15 才能编辑，已按 SDR 打开。",
                        "editing the same photo does not repeat the HDR fallback notice")
            try require(model.saveEdits(), "SDR fallback edits save")
        } else {
            var settings = Adjustments(); settings.hdr = HDRSettings()
            try model.editStore!.save(photo, state: PhotoEditState(settings: settings, filmID: ""))
        }
        model.addCollectionPhotos([photo])
        let review = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: directory)
        try require(review.ready && !review.snapshots[0].settings.isHDREditing &&
                    review.snapshots[0].noticeKey == "此照片的 HDR 需 macOS 15 才能编辑，将按 SDR 导出。",
                    "unsupported-system collection preparation retains SDR targets and their notice")
        let frozen = try model.freezeCollectionExport(review)
        try require(frozen.items[0].noticeKey != nil && frozen.items[0].frozen?.outputFormat == .png,
                    "collection export freezes its SDR format and notice")
        guard exerciseOpening else { return }
        var job = BatchExportJob(source: photo, settings: Adjustments(), look: nil, lookName: "neutral")
        job.outputDirectory = directory; job.format = .jpeg
        let batch = BatchExportModel(job: job, journal: BatchJournal(directory: directory.appendingPathComponent("uniform")),
                                    probeHDRSource: HDRSourceProbeTests.unsupportedSystem)
        batch.add([photo]); try wait { !batch.validating }
        try require(batch.job.selectedCount == 1 && batch.job.items[0].validationError == nil &&
                    batch.job.items[0].noticeKey == "此照片的 HDR 需 macOS 15 才能编辑，将按 SDR 导出。",
                    "uniform batch preflight keeps fallback photos selected and describes their upcoming SDR export")
        try require(batch.start(), "SDR fallback batch starts")
        try wait { !batch.running }
        try require(batch.job.succeededCount == 1, "SDR fallback batch exports successfully")
        // 重新打开同一张已渲染的照片会直接复用当前结果；先切到另一张，才能读取外部写入的 HDR 记录。
        let other = directory.appendingPathComponent("other.jpg")
        try FileManager.default.copyItem(at: photo, to: other)
        model.open(other); try BatchSelectionModelTests.rendered(model)
        var savedHDR = Adjustments(); savedHDR.hdr = HDRSettings()
        try model.editStore!.save(photo, state: PhotoEditState(settings: savedHDR, filmID: ""))
        model.open(photo); try BatchSelectionModelTests.rendered(model)
        try require(!model.settings.isHDREditing && model.settings.hdr?.mode == .sdr,
                    "saved HDR edits retain their dormant snapshot when opening as SDR")
        let restoredReview = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: directory)
        try require(restoredReview.ready && !restoredReview.snapshots[0].settings.isHDREditing,
                    "saved HDR collection targets also use SDR on unsupported systems")
    }

    static func fallbackPersistence(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("fallback-persistence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent("gain-map.jpg"), other = directory.appendingPathComponent("other.jpg")
        let source = CGImageSourceCreateWithURL(fixture as CFURL, nil)!
        for url in [photo, other] {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            try require(CGImageDestinationFinalize(destination), "fallback persistence fixture is generated")
        }
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.probeHDRSource = HDRSourceProbeTests.unsupportedSystem
        var savedHDR = Adjustments(); savedHDR.hdr = HDRSettings()
        savedHDR.hdr?.exposure = 1.7
        savedHDR.hdr?.geometry.quarterTurns = 1
        try model.editStore!.save(photo, state: PhotoEditState(settings: savedHDR, filmID: ""))
        model.open(photo)
        try require(model.file == photo && !model.settings.isHDREditing,
                    "opening a stored HDR record activates its SDR fallback session")
        model.setInteracting(true)
        model.settings.exposure = 0.8
        model.settings.rotateGeometry(clockwise: false)
        model.setInteracting(false)
        try require(model.saveEdits(), "fallback session saves changes to its SDR layer")
        let savedFallback = try model.editStore!.state(for: photo)!.settings
        try require(savedFallback.hdr == savedHDR.hdr && savedFallback.exposure == 0.8 &&
                    savedFallback.geometry?.quarterTurns == 3,
                    "stored fallback edits preserve the HDR mode and snapshot while updating SDR exposure and geometry")
        model.settings.contrast = 12
        try require(model.saveEdits(), "a second fallback save succeeds")
        try require(try model.editStore!.state(for: photo)!.settings.hdr == savedHDR.hdr,
                    "repeated fallback saves retain the original HDR snapshot")
        model.undoAdjustment()
        try require(!model.settings.isHDREditing && model.settings.exposure == 0.8 && model.settings.contrast == 0,
                    "fallback undo restores SDR controls without enabling HDR")
        model.redoAdjustment()
        try require(!model.settings.isHDREditing && model.settings.contrast == 12,
                    "fallback redo restores SDR controls without enabling HDR")
        try require(try model.editStore!.state(for: photo)!.settings.hdr == savedHDR.hdr,
                    "fallback history retains the stored HDR snapshot")
        model.open(other)
        model.open(photo)
        try require(!model.settings.isHDREditing && model.settings.exposure == 0.8 && model.settings.contrast == 12,
                    "reopening a fallback edit restores the saved SDR layer")
    }

    static func appleFallbackAdmission(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("apple-fallback-admission")
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lutools/tests/fixtures/hdr/apple-legacy-macos26.jpg")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.probeHDRSource = HDRSourceProbeTests.unsupportedSystem
        model.open(fixture)
        model.open(apple)
        let diagnostic = L10n.text("HDR 照片需要 macOS 15 或 iOS 18 及以上版本。")
        try require(model.file == fixture && model.error == diagnostic,
                    "Apple fallback rejection retains the current photo and the system diagnostic")
        model.addCollectionPhotos([apple])
        let review = try model.prepareCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: directory)
        try require(!review.ready && review.rows.first?.error?.localizedDescription == diagnostic,
                    "Apple gain maps are rejected during collection export preflight")
        let job = BatchExportJob(source: fixture, settings: Adjustments(), look: nil, lookName: "neutral")
        let batch = BatchExportModel(job: job, journal: BatchJournal(directory: directory.appendingPathComponent("uniform")),
                                    probeHDRSource: HDRSourceProbeTests.unsupportedSystem)
        batch.add([apple]); try wait { !batch.validating }
        try require(batch.job.selectedCount == 0 && batch.job.items[0].validationError == diagnostic &&
                    batch.job.items[0].noticeKey == nil,
                    "Apple gain maps cannot enter uniform batch export as SDR targets")
    }

    static func adaptiveJPEG(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("adaptive-jpeg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hdrPhoto = directory.appendingPathComponent("hdr.png"), sdrPhoto = directory.appendingPathComponent("sdr.png")
        for photo in [hdrPhoto, sdrPhoto] { try FileManager.default.copyItem(at: fixture, to: photo) }
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.addCollectionPhotos([hdrPhoto, sdrPhoto])
        model.probeHDRSource = { url, _ in
            url == hdrPhoto ? HDRSourceInfo(native: sony2fuji_hdr_source_info_v1()) : nil
        }
        var settings = Adjustments(); settings.hdr = HDRSettings()
        try model.editStore!.save(hdrPhoto, state: PhotoEditState(settings: settings, filmID: ""))
        let strict = try model.prepareCollectionExport(skipping: [], format: .hdrJPEG, longEdge: 512, directory: directory)
        try require(!strict.ready && strict.rows[1].error != nil, "explicit HDR JPEG still rejects SDR targets")
        let heif = try model.prepareCollectionExport(skipping: [], format: .hdrHEIF, longEdge: 512, directory: directory)
        try require(!heif.ready && heif.rows[1].error != nil, "explicit HDR HEIF also rejects SDR targets")
        let review = try model.prepareCollectionExport(skipping: [], format: .hdrJPEG, longEdge: 512,
                                                       directory: directory, adaptiveJPEG: true)
        try require(review.ready && review.snapshots.count == 2, "adaptive JPEG accepts mixed saved HDR and SDR edits")
        let job = try model.freezeCollectionExport(review)
        try require(job.items.map { $0.frozen!.outputFormat } == [.hdrJPEG, .jpeg],
                    "adaptive JPEG freezes the actual format for each photo")
        let restored = try model.batchJournal.load()!
        try require(restored.items.map { $0.frozen!.outputFormat } == [.hdrJPEG, .jpeg],
                    "mixed JPEG formats survive task recovery")
        settings.hdr?.mode = .sdr
        try model.editStore!.save(hdrPhoto, state: PhotoEditState(settings: settings, filmID: ""))
        try require(restored.items[0].frozen?.outputFormat == .hdrJPEG,
                    "later photo mode changes cannot alter frozen formats")
    }

    static func presetWithoutPhoto(root: URL, fixture: URL, exerciseOpenPhoto: Bool = true) throws {
        let directory = root.appendingPathComponent("preset-without-photo")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        let payload = try AdjustmentTransferPayload(source: .init(identifier: "saved-preset", isRaw: false,
            processingVersion: 2, recipe: nil), values: ["light.exposure": .number(0.7)])
        model.requestAdjustmentSheet(.presets)
        var selectedTargets = false
        try require(model.preparePresetAction { selectedTargets = true } && selectedTargets && model.file == nil,
                    "saved presets can enter target selection without opening a photo")
        try require(!model.canUsePresetPhoto, "saving and applying to the current photo still require a photo")
        let prepared = try model.prepareAdjustmentPaste(payload: payload, targets: [fixture])
        model.applyAdjustmentPaste(prepared)
        try require(model.adjustmentOutcomes.first?.status == .applied &&
                    model.editStore?.state(for: fixture)?.settings.exposure == 0.7,
                    "a preset applies to selected targets without a host photo")
        for busy in ["export", "look", "ai", "draft"] {
            model.exporting = busy == "export"; model.lookLibraryBusy = busy == "look"
            model.aiState = busy == "ai" ? .running(1, 0, 1) : .idle
            model.geometryDraftDeparturePending = busy == "draft"
            selectedTargets = false
            try require(!model.preparePresetAction { selectedTargets = true } && !selectedTargets,
                        "\(busy) blocks preset target selection without a photo")
        }
        model.exporting = false; model.lookLibraryBusy = false; model.aiState = .idle
        model.geometryDraftDeparturePending = false
        guard exerciseOpenPhoto else { return }
        model.open(fixture); try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = 1.2
        selectedTargets = false
        try require(model.preparePresetAction { selectedTargets = true } && selectedTargets && !model.dirty &&
                    model.editStore?.state(for: fixture)?.settings.exposure == 1.2,
                    "preset target selection still saves an open photo")
        try require(model.beginGeometryDraft(), "preset guard opens a geometry draft")
        model.updateGeometryDraft { $0.cropWidth = 0.75 }
        selectedTargets = false
        _ = model.preparePresetAction { selectedTargets = true }
        try require(!selectedTargets && model.geometryDraftDeparturePending,
                    "preset target selection still waits for the open photo's draft decision")
        model.resolveGeometryDraftDeparture(.stay)
        try require(!selectedTargets && model.geometryDraft != nil,
                    "staying with a geometry draft does not enter preset target selection")
    }

    static func uniformAI(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("uniform-ai")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent("source.arw")
        try Data("RAW identity fixture".utf8).write(to: raw)
        var settings = Adjustments(); settings.aiDenoiseEnabled = true; settings.exposure = 0.7
        var job = BatchExportJob(source: raw, settings: settings, look: nil, lookName: "neutral")
        job.outputDirectory = directory; job.format = .png
        let raster = try BatchExportItem(url: fixture), rawItem = try BatchExportItem(url: raw)
        try require(!job.snapshot(for: raster).settings.aiDenoiseEnabled && job.snapshot(for: rawItem).settings.aiDenoiseEnabled,
                    "uniform snapshots disable AI only for ordinary image targets")
        let model = BatchExportModel(job: job, journal: BatchJournal(directory: directory.appendingPathComponent("journal")))
        model.add([fixture]); try wait { !model.validating }
        try require(model.job.selectedCount == 1 && model.job.items[0].validationError == nil,
                    "ordinary images remain selected after preflight with an AI-enabled RAW source")
        try require(model.notice(for: model.job.items[0]) == L10n.text("普通图片未使用 AI 降噪"),
                    "ordinary image batch items explain why AI was omitted")
        try require(model.start(), "mixed AI job can start")
        try wait { !model.running }
        try require(model.job.succeededCount == 1 && model.job.items[0].output?.pathExtension == "png",
                    "ordinary images export without requesting RAW AI preparation")
    }

    static func x3fSnapshots(root: URL) throws {
        let directory = root.appendingPathComponent("x3f-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try RenderEngine.x3fDefaultMode(for: directory.appendingPathComponent("missing.X3F"))
            try require(false, "missing X3F must fail with an IO diagnostic")
        } catch {
            try require(error.localizedDescription == L10n.text("无法读取或写入文件，请检查路径和访问权限。"),
                        "X3F IO errors retain the file-access diagnostic")
        }
        let normal = directory.appendingPathComponent("normal.X3F")
        let legacy = directory.appendingPathComponent("legacy.X3F")
        // 预检只验证文件身份和已保存设置；这里不触发 RAW 解码。
        for file in [normal, legacy] { try Data("FOVb snapshot fixture".utf8).write(to: file) }
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.addCollectionPhotos([normal, legacy])
        var settings = Adjustments()
        settings.x3fMode = .normal; settings.aiDenoiseEnabled = true
        try model.editStore!.save(normal, state: PhotoEditState(settings: settings, filmID: ""))
        settings.x3fMode = .legacy; settings.aiDenoiseEnabled = false
        try model.editStore!.save(legacy, state: PhotoEditState(settings: settings, filmID: ""))
        let rejected = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: directory)
        try require(!rejected.ready && rejected.rows.first?.error?.localizedDescription ==
                    L10n.text("此 X3F 显影模式不支持 AI 降噪。"),
                    "moved collection preflight preserves the normal X3F AI restriction")
        settings.selectX3fMode(.normal)
        try model.editStore!.save(normal, state: PhotoEditState(settings: settings, filmID: ""))
        let review = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: directory)
        try require(review.ready && review.snapshots.map { $0.settings.x3fMode } == [.normal, .legacy],
                    "collection preparation retains each photo's saved X3F mode")
        let job = try model.freezeCollectionExport(review)
        try require(job.items.map { $0.frozen!.settings.x3fMode } == [.normal, .legacy],
                    "collection freeze retains mixed normal and legacy X3F identities")
        let unedited = directory.appendingPathComponent("unedited.X3F")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lutools/tests/fixtures/linear-uncompressed.dng")
        try FileManager.default.copyItem(at: fixture, to: unedited)
        model.addCollectionPhotos([unedited])
        let uneditedReview = try model.prepareCollectionExport(skipping: [], format: .png, longEdge: nil, directory: root)
        let snapshot = uneditedReview.snapshots.first { $0.photo.url == unedited }
        try require(snapshot?.record.state == nil && snapshot?.settings.x3fMode == .legacy,
                    "no-record collection export uses the source's Legacy default without creating an edit")
        let replacedInspect = directory.appendingPathComponent("inspect-replaced.X3F")
        try Data("initial".utf8).write(to: replacedInspect)
        let replacedItem = try BatchExportItem(url: replacedInspect)
        try Data("FOVb-replaced-corrupt-header".utf8).write(to: replacedInspect)
        let inspectBatch = BatchExportModel(
            job: BatchExportJob(source: normal, settings: Adjustments(), look: nil, lookName: "neutral"),
            journal: BatchJournal(directory: directory.appendingPathComponent("inspect-journal"))
        )
        inspectBatch.inspect(replacedItem)
        try wait { !inspectBatch.previewing }
        try require(inspectBatch.error == BatchExportFailure.changedInput.localizedDescription,
                    "batch inspect checks input identity before probing X3F target mode")
    }

    static func automaticLaunch(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("automatic-launch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.png"), second = directory.appendingPathComponent("second.png")
        for file in [first, second] { try FileManager.default.copyItem(at: fixture, to: file) }
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.addCollectionPhotos([first, second])
        model.open(first); try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = 0.8; try require(model.saveEdits(), "first export target saves its own adjustment")
        model.open(second); try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = -0.6; try require(model.saveEdits(), "second export target saves a different adjustment")
        let history = model.adjustmentSession!.transactions.count

        model.startCollectionExport(skipping: [], format: .png, longEdge: nil, directory: output)
        try wait { model.batch != nil && model.batch?.running == false }
        let job = model.batch!.job
        try require(job.started && job.succeededCount == 2 && job.mode == .perTargetFrozen,
            "one collection action prepares freezes and exports both photos")
        try require(try model.batchJournal.load()?.id == job.id && model.adjustmentSession!.transactions.count == history,
            "automatic export retains one journal and adds no photo history")
        let outputs = job.items.compactMap(\.output)
        try require(outputs.count == 2 && pixels(outputs[0]) != pixels(outputs[1]),
            "one-action export renders each photo's independent saved exposure")
        try require(!model.collectionExportBlockedByTask, "a completed task leaves the next collection export available")
        model.startCollectionExport(skipping: [], format: .png, longEdge: nil, directory: output)
        try wait { model.batch?.job.id != job.id && model.batch?.running == false }
        try require(model.batch!.job.succeededCount == 2,
            "another collection export can start after the previous task completes")
    }

    private static func pixels(_ url: URL) -> Data {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!.dataProvider!.data! as Data
    }

    static func pendingLaunches(root: URL, fixture: URL) throws {
        for action in ["cancel", "photo", "edit", "selection", "conflict", "restart"] {
            let directory = root.appendingPathComponent("pending-\(action)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let first = directory.appendingPathComponent("first.png"), second = directory.appendingPathComponent("second.png")
            for file in [first, second] { try FileManager.default.copyItem(at: fixture, to: file) }
            let output = directory.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
                editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
                presetDirectory: directory.appendingPathComponent("presets"))
            model.addCollectionPhotos([first, second]); model.open(first)
            try BatchSelectionModelTests.rendered(model)
            let prepare = model.prepareCollectionExportOperation
            let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var calls = 0
            model.prepareCollectionExportOperation = { input in
                calls += 1
                let result = try prepare(input)
                ready.signal(); release.wait()
                return result
            }
            defer { release.signal() }
            model.startCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: output)
            model.startCollectionExport(skipping: [], format: .jpeg, longEdge: nil, directory: output)
            var prepared = false
            try wait {
                if !prepared { prepared = ready.wait(timeout: .now()) == .success }
                return prepared
            }
            try require(calls == 1 && model.collectionExportPreparing && model.batch == nil,
                "\(action): duplicate clicks keep one cancellable preparation")
            try require(try model.batchJournal.load() == nil, "\(action): checking has no journal")
            switch action {
            case "photo": model.open(second); try BatchSelectionModelTests.rendered(model)
            case "edit": model.settings.exposure = 0.3; try require(model.saveEdits(), "ordinary edits still save during a cancelled check")
            case "selection": model.batchSelection.selectAll(false)
            case "conflict":
                let expected = try model.editStore!.readState(for: second)
                var state = try expected.state ?? PhotoEditState(
                    settings: RenderEngine.defaultSettings(for: second, sourceIsHDR: false), filmID: "")
                state.settings.exposure = 0.6
                try require(model.adjustmentSession!.commitEdit(expected: expected, state: state).status == .applied,
                    "a later session commit expires collection export without changing the active photo")
            case "restart":
                model.cancelCollectionExportPreparation()
                model.prepareCollectionExportOperation = prepare
                model.startCollectionExport(skipping: [], format: .png, longEdge: nil, directory: output)
            default: model.cancelCollectionExportPreparation()
            }
            release.signal()
            var delivered = false
            model.collectionExportQueue.async { DispatchQueue.main.async { delivered = true } }
            try wait { delivered }
            if action == "restart" {
                try wait { model.batch != nil && model.batch?.running == false }
                try require(model.batch!.job.format == .png && model.batch!.job.succeededCount == 2,
                    "only the newer request freezes and runs its selected format")
            } else {
                try require(!model.collectionExportPreparing && model.batch == nil && (try model.batchJournal.load()) == nil,
                    "\(action): a late result cannot freeze or attach a task")
                try require(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty,
                    "\(action): a rejected check creates no output")
                if action == "conflict" {
                    try require(model.collectionExportError != nil, "a local edit expires the pending export check")
                }
            }
        }
    }

    static func preparedSourceChange(root: URL, fixture: URL) throws {
        let directory = root.appendingPathComponent("source-change")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.png")
        let target = directory.appendingPathComponent("target.png")
        let next = directory.appendingPathComponent("next.png")
        for file in [source, target, next] { try FileManager.default.copyItem(at: fixture, to: file) }
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"),
            batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.open(source)
        try BatchSelectionModelTests.rendered(model)
        model.settings.exposure = 0.8
        try require(model.saveEdits(), "source edit is saved before preparing a transfer")
        let payload = try model.copyAdjustments(scope: .custom([.exposure]))
        let prepared = try model.prepareAdjustmentPaste(payload: payload, targets: [target])
        let before = try model.editStore!.readState(for: target)
        let historyCount = model.adjustmentSession!.transactions.count

        model.open(next)
        try BatchSelectionModelTests.rendered(model)
        model.applyAdjustmentPaste(prepared)
        try require(try model.editStore!.readState(for: target) == before,
            "switching the host photo rejects prepared writes to a different target")
        try require(model.adjustmentSession!.transactions.count == historyCount,
            "an expired transfer adds no history")

        let current = try model.prepareAdjustmentPaste(payload: payload, targets: [target])
        model.applyAdjustmentPaste(current)
        try require(try model.editStore!.state(for: target)?.settings.exposure == 0.8,
            "a new request can still use the independent copied payload")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: label, code: 1) }
        print("PASS: \(label)")
    }

    static func declinedStart(job: BatchExportJob, journal: BatchJournal) throws {
        var unavailable = job
        unavailable.outputDirectory = nil
        let batch = BatchExportModel(job: unavailable, journal: journal)
        let accepted = batch.start()
        try require(!accepted && !batch.running && batch.error == L10n.text("选择输出文件夹"),
            "a declined start reports the missing output destination")
        try require(try journal.load()?.id == job.id && batch.job.id == job.id,
            "declined admission preserves the existing frozen job identity")
    }

    static func initializationFailure(job: BatchExportJob, root: URL) throws {
        let destination = root.appendingPathComponent("blocked-output")
        try Data("blocked".utf8).write(to: destination)
        var blocked = job
        blocked.outputDirectory = destination
        let journal = BatchJournal(directory: root.appendingPathComponent("failed-start"))
        try journal.save(blocked)
        let failed = BatchExportModel(job: blocked, journal: journal)
        try require(failed.start(), "the runner accepts a structurally valid frozen task")
        try wait { !failed.running }
        let stored = try journal.load()!
        try require(stored.id == job.id && stored.failure != nil && stored.interrupted,
            "initialization failure persists its reason on the same frozen job")
        try require(failed.error != nil && !stored.started, "failed initialization remains visible without claiming a started export")
        try require(failed.close(), "a frozen task can close after initialization failure")
        try require(try journal.load()?.id == job.id,
            "closing an unstarted frozen task preserves it for recovery")

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let recovered = BatchExportModel(job: stored, journal: journal)
        try require(recovered.start(), "the recovered frozen task can retry after its destination is repaired")
        try wait { !recovered.running }
        try require(recovered.job.id == job.id && recovered.job.succeededCount == job.selectedCount,
            "startup retry exports the original frozen job without creating another one")
        var draft = BatchExportJob(source: job.source, settings: Adjustments(), look: nil, lookName: "neutral")
        draft.outputDirectory = destination
        try journal.save(draft)
        let uniform = BatchExportModel(job: draft, journal: journal)
        try require(try uniform.close() && journal.load() == nil,
            "closing an unstarted uniform draft still discards it")
    }

    static func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try require(predicate(), "batch flow asynchronous work completes")
    }
}
