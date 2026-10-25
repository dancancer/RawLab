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
        model.open(first); try rendered(model)
        try check(model.adjustmentSession!.transactions.isEmpty, "opening and resolving metadata create no history")
        model.setInteracting(true)
        model.settings.exposure = 0.2
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        model.settings.exposure = 0.6
        try check(model.adjustmentSession!.transactions.isEmpty, "a long slider gesture does not save intermediate history")
        model.setInteracting(false)
        try check(model.adjustmentSession!.transactions.count == 1 && !model.dirty, "gesture end saves exactly one history item")
        try rendered(model)
        model.undoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0 && model.canRedoAdjustment, "undo restores the pre-gesture state")
        model.redoAdjustment(); try rendered(model)
        try check(model.settings.exposure == 0.6, "redo restores the saved gesture")
        model.setInteracting(true); model.settings.exposure = 1.2
        model.cancelAdjustmentInteraction(); try rendered(model)
        try check(model.settings.exposure == 0.6 && model.adjustmentSession!.transactions.count == 1,
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
