import AppKit

private func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: label, code: 1) }
    print("PASS: \(label)")
}

@main struct EditorAdjustmentHistoryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        let pixels = [UInt8](repeating: 128, count: 8 * 6 * 3)
        let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for url in [first, second] {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("fixture") }
        }
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"), batchDirectory: root.appendingPathComponent("batch"))
        let originalFilms = model.films
        let summaryLook = root.appendingPathComponent("summary.cube")
        try Data("fixture".utf8).write(to: summaryLook)
        model.films = [Film(name: "Summary look", url: summaryLook, managedID: "summary-look")]
        try check(model.adjustmentSummaryLookName(kind: "managed", id: "summary-look") == "Summary look",
                  "Summary resolves a readable managed look")
        try FileManager.default.removeItem(at: summaryLook)
        try check(model.adjustmentSummaryLookName(kind: "managed", id: "summary-look") == nil,
                  "Summary marks a deleted look unavailable even while metadata is cached")
        model.films = originalFilms
        model.open(first); try rendered(model)
        try check(model.adjustmentSession!.transactions.isEmpty, "opening and resolving metadata create no history")
        model.setInteracting(true)
        model.settings.exposure = 0.2
        model.settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 231.25, saturation: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        model.settings.exposure = 0.6
        model.settings.gradingSettings[.midtones] = ColorGradingWheel(hue: 110.125, saturation: 32.375)
        try check(model.adjustmentSession!.transactions.isEmpty, "a long slider gesture does not save intermediate history")
        model.undoAdjustment(); model.redoAdjustment()
        try check(model.scheduler.interacting && model.settings.exposure == 0.6 && model.adjustmentSession!.transactions.isEmpty,
            "Undo and Redo do not split an active adjustment gesture")
        model.setInteracting(false)
        try check(model.adjustmentSession!.transactions.count == 1 && !model.dirty, "gesture end saves exactly one history item")
        try rendered(model)
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0 && model.settings.gradingSettings.isDefault && model.canRedoAdjustment, "undo restores the pre-gesture state")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0.6 && model.settings.gradingSettings.shadows.hue == 231.25
            && model.settings.gradingSettings.midtones.saturation == 32.375, "redo restores the saved gesture including pending hue")
        model.setInteracting(true); model.settings.exposure = 1.2
        model.settings.gradingSettings[.shadows] = ColorGradingWheel(hue: 80, saturation: 75)
        model.cancelAdjustmentInteraction(); try rendered(model)
        try check(model.settings.exposure == 0.6 && model.settings.gradingSettings.shadows == ColorGradingWheel(hue: 231.25, saturation: 0)
            && model.adjustmentSession!.transactions.count == 1,
            "cancelled gesture restores its entry snapshot without history")
        model.settings.contrast = 15; try check(model.saveEdits(), "ordinary change saves")
        try check(model.applyCurrentSettings(to: [first, first]) == 0,
            "sync excludes its source and does not report an empty target set as success")
        let clipboard = try model.copyAdjustments(scope: .custom([.exposure]))
        model.settings.exposure = 1.1; try check(model.saveEdits(), "source can change after copying")
        try check(clipboard[.exposure]?.number == 0.6 && model.adjustmentSession!.clipboard == clipboard,
            "copy freezes the saved selection")
        model.open(second); try rendered(model)
        let operation = try model.prepareAdjustmentPaste(payload: clipboard, targets: [second])
        model.applyAdjustmentPaste(operation)
        try rendered(model)
        try check(model.settings.exposure == 0.6 && !model.dirty, "pasting the active photo updates the committed model")
        model.setInteracting(true); model.settings.saturation = 17
        model.applyAdjustmentPaste(operation)
        try check(model.settings.saturation == 17 && model.dirty,
            "retry receipts never replace later unsaved edits on an already successful photo")
        model.cancelAdjustmentInteraction(); try rendered(model)
        model.settings.saturation = 20; try check(model.saveEdits(), "editing after paste uses the new storage revision")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.saturation == 0 && model.settings.exposure == 0.6, "ordinary undo leaves earlier paste intact")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0, "next undo reaches paste history")
        model.open(first); try rendered(model)
        try check(model.settings.exposure == 1.1 && model.settings.contrast == 15, "photo histories do not cross identities")
        let geometryCount = model.adjustmentSession!.transactions.count
        try check(model.beginGeometryDraft(), "geometry draft opens after committed edits")
        try rendered(model)
        model.updateGeometryDraft { $0.cropWidth = 0.75 }
        try check(model.applyGeometryDraft(), "geometry draft saves through the common transaction entry")
        try rendered(model)
        try check(model.adjustmentSession!.transactions.count == geometryCount + 1, "geometry Apply creates one ordinary history item")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.geometrySettings.isIdentity && model.settings.exposure == 1.1,
            "geometry undo preserves earlier color edits")
        let count = model.adjustmentSession!.transactions.count
        _ = try model.copyAdjustments(scope: .all)
        try check(model.adjustmentSession!.transactions.count == count, "copy is not a photo edit")
        let external = try EditPersistence(directory: root.appendingPathComponent("edits"))
        var other = model.editState(settings: model.settings); other.settings.exposure = 3
        try external.save(first, state: other)
        model.settings.exposure = 2
        try check(!model.saveEdits() && model.dirty && model.saveError != nil,
            "external changes block ordinary saves and preserve unsaved input")
        let externallySaved = try external.state(for: first)
        try check(model.adjustmentSession!.transactions.count == count && externallySaved?.settings.exposure == 3,
            "failed save neither overwrites storage nor creates history")
        try recipeLUTChecks(root: root, first: first, second: second)
        try historyErrorChecks(root: root, first: first)
        try presetChecks(root: root, first: first, second: second)
        try QuickPresetModelChecks.run(root: root, first: first, second: second)
        try hslTargetChecks(root: root, second: second)
        try curveNavigationChecks(root: root, photo: first)
        var aiSettings = Adjustments(); aiSettings.aiDenoiseEnabled = true
        let aiBatch = BatchExportModel(job: BatchExportJob(source: first, settings: aiSettings, look: nil, lookName: "Neutral"),
            journal: BatchJournal(directory: root.appendingPathComponent("ai-batch")))
        aiBatch.add([second])
        let deadline = Date().addingTimeInterval(30)
        while aiBatch.validating && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try check(!aiBatch.validating && aiBatch.job.items.first?.selected == false && aiBatch.job.items.first?.validationError != nil,
            "AI batch preflight excludes raster targets before export")
    }

    static func curveNavigationChecks(root: URL, photo: URL) throws {
        let model = EditorModel(lookDirectory: root.appendingPathComponent("curve-looks"),
            editDirectory: root.appendingPathComponent("curve-edits"), batchDirectory: root.appendingPathComponent("curve-batch"))
        model.open(photo); try rendered(model)
        model.settings.curveSettings = .identity; try check(model.saveEdits(), "curve mode saves")
        let before = model.settings, count = model.adjustmentSession!.transactions.count
        for collapse in [false, true] {
            model.selectAdjustmentTool(.toneCurve)
            model.setInteracting(true); model.settings.curveSettings = .identity.inserting(x: 0.5, y: 0.7)
            if collapse { model.selectAdjustmentGroup(.light) } else { model.selectAdjustmentTool(.exposure) }
            try check(model.settings == before && !model.scheduler.interacting && model.interactionEntry == nil &&
                model.adjustmentSession!.transactions.count == count,
                "curve navigation cancels before changing the tool or collapsing its group")
        }
        model.selectAdjustmentTool(.exposure)
        model.setInteracting(true); model.settings.exposure = 0.4; model.setInteracting(false)
        try check(model.adjustmentSession!.transactions.count == count + 1 && model.settings.curveSettings == .identity,
            "the next tool creates its own history entry after curve cancellation")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings == before, "undo of the next tool retains the saved curve")
    }

    static func hslTargetChecks(root: URL, second: URL) throws {
        let photo = root.appendingPathComponent("hsl-target.png")
        let pixels: [UInt8] = Array(repeating: [204, 102, 51], count: 8 * 6).flatMap { $0 }
        let image = CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("fixture") }
        let model = EditorModel(lookDirectory: root.appendingPathComponent("hsl-looks"),
            editDirectory: root.appendingPathComponent("hsl-edits"), batchDirectory: root.appendingPathComponent("hsl-batch"))
        model.open(photo); try rendered(model); model.selectAdjustmentTool(.hsl); model.hslTargetEnabled = true
        func sampled() throws {
            let deadline = Date().addingTimeInterval(30)
            while model.hslTargetInteraction.isWaiting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            try check(!model.hslTargetInteraction.isWaiting, "target sampling completes")
        }
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5)); model.moveHSLTarget(20); model.endHSLTarget()
        try sampled(); try rendered(model)
        try check(model.adjustmentSession!.transactions.count == 1 && !model.settings.hslSettings.isIdentity,
            "release before native sample creates exactly one durable HSL edit")
        let point = model.hslTargetPoint
        let beforeKeys = model.settings.hslSettings
        model.busy = true
        model.keyHSLTarget(1); model.keyHSLTarget(1); model.keyHSLTarget(1)
        try check(model.hslTargetPoint == point, "Keyboard repeats preserve the sample point while preview is busy")
        model.refreshBusy(); try sampled(); try rendered(model)
        try check(model.adjustmentSession!.transactions.count == 2, "Buffered keyboard repeats form one HSL history transaction")
        let keySample = model.hslTargetInteraction.selection!
        for channel in 0..<8 {
            let expected = min(100, max(-100, beforeKeys.value(model.hslTargetAxis, channel: channel) + 3 * keySample.weights[channel]))
            try check(abs(model.settings.hslSettings.value(model.hslTargetAxis, channel: channel) - expected) < 0.000001,
                "Keyboard repeats apply every weighted step to channel \(channel)")
        }
        model.undoAdjustment(); try rendered(model)
        let targetHistoryCount = model.adjustmentSession!.transactions.count
        let saved = model.settings
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5)); try sampled()
        model.moveHSLTarget(50); model.cancelHSLTarget(); model.endHSLTarget(); try rendered(model)
        try check(model.settings == saved && model.adjustmentSession!.transactions.count == targetHistoryCount,
            "native target cancellation restores before without a second history item")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.hslSettings.isIdentity, "target undo restores all HSL channels")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings == saved, "target redo restores frozen weighted values")
        model.beginHSLTarget(CGPoint(x: 0.5, y: 0.5)); model.moveHSLTarget(10); model.open(second); try rendered(model)
        try check(model.settings.hslSettings.isIdentity && !model.hslTargetInteraction.isWaiting,
            "source switch discards a pending native target sample")
    }

    static func presetChecks(root: URL, first: URL, second: URL) throws {
        let directory = root.appendingPathComponent("preset-edits")
        let model = EditorModel(lookDirectory: root.appendingPathComponent("preset-looks"), editDirectory: directory,
            batchDirectory: root.appendingPathComponent("preset-batch"), presetDirectory: root.appendingPathComponent("preset-library"))
        model.open(first); try rendered(model)
        model.settings.exposure = 0.7; try check(model.saveEdits(), "preset source is committed")
        let clipboard = try model.copyAdjustments(scope: .custom([.contrast]))
        let count = model.adjustmentSession!.transactions.count
        let payload = try model.capturePresetAdjustments(scope: .custom([.exposure]))
        let preset = try model.presetStore.create(name: "Native preset", payload: payload)
        try check(model.adjustmentClipboard == clipboard && model.adjustmentSession!.clipboard == clipboard &&
            model.adjustmentSession!.transactions.count == count, "native preset save preserves both clipboard and photo history")
        try check(model.beginGeometryDraft(), "preset fixture enters a geometry draft")
        try rendered(model); model.updateGeometryDraft { $0.cropWidth = 0.8 }
        model.requestAdjustmentSheet(.presets)
        try check(model.adjustmentSheet == .presets && model.geometryDraft != nil && !model.geometryDraftDeparturePending,
            "opening preset management does not apply or discard a photo draft")
        var continued = false
        model.preparePresetAction { continued = true }
        try check(model.geometryDraftDeparturePending && !continued, "preset save waits for the shared geometry decision")
        model.resolveGeometryDraftDeparture(.stay)
        try check(!continued && model.geometryDraft != nil, "Continue Editing cancels the preset action and preserves its draft")
        model.preparePresetAction { continued = true }
        model.resolveGeometryDraftDeparture(.discard)
        try check(continued && model.geometryDraft == nil && model.adjustmentSession!.transactions.count == count,
            "Discard then preset capture uses committed values without adding a geometry history item")
        model.adjustmentSheet = nil
        model.open(second); try rendered(model)
        model.settings.exposure = -0.2; model.settings.saturation = 14
        try check(model.saveEdits(), "preset target has independent committed adjustments")
        let operation = try model.prepareAdjustmentPaste(payload: preset.payload, targets: [second], action: .preset)
        model.applyAdjustmentPaste(operation); try rendered(model)
        try check(model.settings.exposure == 0.7 && model.settings.saturation == 14 && !model.dirty,
            "native preset apply adopts its conditional receipt and preserves unselected settings")
        try check(model.adjustmentSession!.transactions.last?.action == .preset, "native preset history records its actual action")
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == -0.2 && model.canRedoAdjustment, "native Undo restores the pre-preset photo")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0.7, "native Redo restores the same preset component")
        let externalStore = try EditPersistence(directory: directory)
        var externalSettings = model.settings; externalSettings.exposure = 1.8
        try externalStore.save(second, state: model.editState(settings: externalSettings))
        let externalReceipt = try externalStore.versionedState(for: second)
        let beforeConflictHistory = model.adjustmentSession!.transactions.count
        do { _ = try model.capturePresetAdjustments(scope: .custom([.exposure])); throw NSError(domain: "Expected stale preset capture failure", code: 1) }
        catch EditPersistenceConflict.changed {}
        try check(try externalStore.versionedState(for: second) == externalReceipt && model.presetStore.list() == [preset] &&
            model.adjustmentSession!.transactions.count == beforeConflictHistory && model.adjustmentClipboard == clipboard && model.saveError == nil,
            "preset capture rejects an external photo revision without changing saved state, library, history, clipboard or photo-save status")
        model.open(first); try rendered(model)
        model.open(second); try rendered(model)
        try check(model.settings.exposure == 1.8, "switching away and back after stale preset capture adopts the external settings")
        model.editStore = try EditPersistence(directory: directory, writeData: { _, _ in throw CocoaError(.fileWriteUnknown) })
        model.settings.exposure = 1.3
        do { _ = try model.capturePresetAdjustments(scope: .custom([.exposure])); throw NSError(domain: "Expected preset source save failure", code: 1) }
        catch AdjustmentTransferError.draftRequiresPreflight {}
        try check(model.dirty && model.saveError != nil && model.adjustmentClipboard == clipboard,
            "failed source persistence blocks preset capture without changing clipboard")
        try check(model.presetStore.list() == [preset], "source save failure does not alter the preset library")
    }

    static func recipeLUTChecks(root: URL, first: URL, second: URL) throws {
        let model = EditorModel(lookDirectory: root.appendingPathComponent("recipe-looks"),
            editDirectory: root.appendingPathComponent("recipe-edits"), batchDirectory: root.appendingPathComponent("recipe-batch"))
        model.open(first); try rendered(model)
        model.selectMasterRecipe(.hamadaDaylightV2); try rendered(model)
        let payload = try model.copyAdjustments(scope: .custom([.look]))
        model.open(second); try rendered(model)
        let before = model.settings
        let operation = try model.prepareAdjustmentPaste(payload: payload, targets: [second])
        model.applyAdjustmentPaste(operation); try rendered(model)
        try check(model.settings.masterRecipeID == nil && model.selectedFilmID == "recipe-lut:hamada_daylight_v2",
            "partial recipe look remains an independent LUT")
        try check(model.selectedFilm?.url == MasterRecipe.hamadaDaylightV2.lutURL() && !model.missingFilm,
            "preview and export resolver finds a recipe LUT reference")
        try check(model.settings.exposure == before.exposure && model.settings.hsl == before.hsl,
            "resolving the LUT does not reapply recipe parameter deltas")
        try check(model.prepareBatch() && model.batch?.job.look != nil, "batch export freezes the resolved recipe LUT")
        model.open(first); try rendered(model); model.open(second); try rendered(model)
        try check(model.selectedFilmID == "recipe-lut:hamada_daylight_v2" && model.selectedFilm != nil,
            "saved recipe LUT references restore without selecting a full recipe")
        try check(model.filmChoices.contains { $0.id == model.selectedFilmID }, "independent recipe look has a visible selected film choice")
        model.selectFilm(""); try rendered(model)
        model.selectFilm("recipe-lut:hamada_daylight_v2"); try rendered(model)
        try check(model.selectedFilmID == "recipe-lut:hamada_daylight_v2" && model.settings.masterRecipeID == nil,
            "an encountered independent recipe look can be selected again without recipe deltas")
    }

    static func historyErrorChecks(root: URL, first: URL) throws {
        let directory = root.appendingPathComponent("history-errors")
        let model = EditorModel(lookDirectory: root.appendingPathComponent("error-looks"), editDirectory: directory,
            batchDirectory: root.appendingPathComponent("error-batch"))
        model.open(first); try rendered(model)
        model.settings.exposure = 1; try check(model.saveEdits(), "history error fixture saves")
        var replacement = model.editState(settings: model.settings); replacement.settings.exposure = 2
        try EditPersistence(directory: directory).save(first, state: replacement)
        model.undoAdjustment()
        try check(model.saveError == nil && model.adjustmentSheet == .history,
            "keyboard history failure opens history recovery without pretending the photo is unsaved")
        try check(model.pendingAdjustmentHistory?.photo == first && model.pendingAdjustmentHistory?.undo == true,
            "keyboard recovery retains the single-photo operation scope")
    }

    static func rendered(_ model: EditorModel) throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try check(!model.busy && model.result != nil && model.error == nil, "native preview completes")
    }
}
