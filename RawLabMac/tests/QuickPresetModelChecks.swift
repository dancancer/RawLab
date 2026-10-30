import AppKit

enum QuickPresetModelChecks {
    private static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: label, code: 1) }
        print("PASS: \(label)")
    }

    private static func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try check(predicate(), "quick preset asynchronous work completes")
    }

    private static func rendered(_ model: EditorModel) throws {
        try wait { !model.busy && !model.workerActive }
        try check(model.result != nil && model.error == nil, "quick preset fixture renders")
    }

    private static func wait(_ signal: DispatchSemaphore) throws {
        var received = false
        try wait {
            if !received { received = signal.wait(timeout: .now()) == .success }
            return received
        }
    }

    static func run(root: URL, first: URL, second: URL) throws {
        let directory = root.appendingPathComponent("quick-presets")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
            editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"),
            presetDirectory: directory.appendingPathComponent("presets"))
        model.open(first); try rendered(model)
        model.settings.exposure = 0.7
        try check(model.saveEdits(), "quick preset source saves")
        let preset = try model.presetStore.create(name: "Quick exposure", payload: model.capturePresetAdjustments(scope: .custom([.exposure])))
        let clipboard = try model.copyAdjustments(scope: .custom([.contrast]))
        model.open(second); try rendered(model)
        model.settings.exposure = -0.2; model.settings.saturation = 14
        try check(model.saveEdits(), "quick preset target saves")
        let unchanged = try model.presetStore.create(name: "Existing exposure", payload: model.capturePresetAdjustments(scope: .custom([.exposure])))
        let initialHistory = model.adjustmentSession!.transactions.count
        model.showQuickPresets()
        model.applyPresetToCurrentPhoto(preset)
        try wait { !model.quickPresetState.isPreparing }; try rendered(model)
        guard case .saved(_, let transaction) = model.quickPresetState else { throw NSError(domain: "quick preset must report a saved transaction", code: 1) }
        try check(model.settings.exposure == 0.7 && model.settings.saturation == 14 && !model.dirty,
            "one quick action saves only the selected fields")
        try check(model.adjustmentSession!.transactions.count == initialHistory + 1 &&
            model.adjustmentSession!.transactions.last?.action == .preset && model.lastAdjustmentTransaction == transaction,
            "quick apply records one Preset transaction with its operation identity")
        try check(model.adjustmentClipboard == clipboard, "quick apply leaves the adjustment clipboard unchanged")
        model.undoAdjustment(); try rendered(model)
        guard case .idle = model.quickPresetState else { throw NSError(domain: "global undo must dismiss the previous quick preset result", code: 1) }
        try check(model.quickPresetsVisible && model.settings.exposure == -0.2, "global undo preserves preset browsing and restores the photo")
        model.redoAdjustment(); try rendered(model)
        model.quickPresetState = .saved(preset, transaction)
        model.undoQuickPreset(); try rendered(model)
        guard case .undone = model.quickPresetState else { throw NSError(domain: "quick undo must report completion", code: 1) }
        try check(model.settings.exposure == -0.2 && model.canRedoAdjustment, "quick undo restores the same photo transaction")
        model.applyPresetToCurrentPhoto(unchanged)
        try wait { !model.quickPresetState.isPreparing }
        guard case .unchanged = model.quickPresetState else { throw NSError(domain: "equal quick preset must report unchanged", code: 1) }
        try check(model.adjustmentSession!.transactions.count == initialHistory + 1 && model.canRedoAdjustment,
            "unchanged quick apply adds no history and keeps the redo branch")
        model.applyPresetToCurrentPhoto(preset)
        try wait { !model.quickPresetState.isPreparing }; try rendered(model)
        model.settings.saturation = 22
        try check(model.saveEdits(), "later ordinary edit saves after quick apply")
        let later = try model.editStore!.versionedState(for: second)
        model.undoQuickPreset()
        guard case .undoFailed = model.quickPresetState else { throw NSError(domain: "stale quick undo must report conflict", code: 1) }
        try check(try model.editStore!.versionedState(for: second) == later && model.settings.saturation == 22,
            "quick undo never substitutes the latest unrelated edit")

        for action in ["cancel", "close", "edit", "photo", "conflict", "restart"] {
            model.open(first); try rendered(model); model.open(second); try rendered(model)
            model.showQuickPresets()
            let before = try model.editStore!.versionedState(for: second)
            let history = model.adjustmentSession!.transactions.count
            let prepare = model.prepareQuickPresetOperation
            let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            model.prepareQuickPresetOperation = { session, payload, targets in
                let operation = try prepare(session, payload, targets)
                ready.signal(); release.wait()
                return operation
            }
            model.applyPresetToCurrentPhoto(unchanged)
            try wait(ready)
            model.applyPresetToCurrentPhoto(preset)
            switch action {
            case "restart":
                model.cancelQuickPreset(); model.prepareQuickPresetOperation = prepare
                model.applyPresetToCurrentPhoto(preset)
            case "close": model.closeQuickPresets()
            case "edit": model.settings.exposure = 1.1; try check(model.saveEdits(), "edit during prepare commits independently")
            case "photo": model.open(first); try rendered(model)
            case "conflict":
                var changed = before.state!; changed.settings.exposure = 1.8
                try EditPersistence(directory: directory.appendingPathComponent("edits")).save(second, state: changed)
            default: model.cancelQuickPreset()
            }
            let expected = try model.editStore!.versionedState(for: second)
            release.signal()
            model.quickPresetQueue.async { finished.signal() }
            try wait(finished)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            model.prepareQuickPresetOperation = prepare
            if action == "restart" {
                try check(model.settings.exposure == 0.7 && model.settings.saturation == 22,
                    "a newer quick request alone applies after the older request is cancelled")
            } else {
                try check(try model.editStore!.versionedState(for: second) == expected,
                    "\(action) rejects the late quick result without replacing current storage")
            }
            try check(model.adjustmentSession!.transactions.count == history + (["edit", "restart"].contains(action) ? 1 : 0),
                "\(action) and duplicate clicks create no quick preset transaction")
            try check(model.adjustmentClipboard == clipboard, "\(action) keeps the clipboard")
            if action == "conflict" {
                guard case .failed = model.quickPresetState else { throw NSError(domain: "external revision must report failure", code: 1) }
            } else if action == "restart" {
                guard case .saved = model.quickPresetState else { throw NSError(domain: "older completion must not dismiss the newer result", code: 1) }
            } else {
                guard case .idle = model.quickPresetState else { throw NSError(domain: "invalidated quick result must stay dismissed", code: 1) }
            }
        }

        model.open(first); try rendered(model)
        try check(model.beginGeometryDraft(), "quick preset fixture enters a geometry draft")
        try rendered(model); model.updateGeometryDraft { $0.cropWidth = 0.8 }
        let draft = model.geometryDraft, beforeDraftAction = try model.editStore!.versionedState(for: first)
        model.showQuickPresets()
        try check(model.quickPresetsVisible && model.geometryDraft == draft && !model.geometryDraftDeparturePending,
            "browsing quick presets preserves an unfinished geometry draft")
        model.applyPresetToCurrentPhoto(unchanged)
        try check(model.geometryDraftDeparturePending, "quick apply asks for the shared draft decision")
        model.resolveGeometryDraftDeparture(.stay)
        try check(try model.editStore!.versionedState(for: first) == beforeDraftAction && model.geometryDraft == draft,
            "Continue Editing cancels quick apply without saving the draft")
        model.closeQuickPresets()
        try check(model.geometryDraft == draft && model.adjustmentNavigation.tool.usesGeometryDraft,
            "closing quick browsing returns to the preserved geometry controls")
        model.cancelGeometryDraft()
        try rendered(model)
        try check(model.beginGeometryDraft(), "quick preset enters an unchanged geometry draft")
        try rendered(model)
        model.showQuickPresets(); model.applyPresetToCurrentPhoto(unchanged)
        try wait { !model.quickPresetState.isPreparing }; try rendered(model)
        guard case .saved = model.quickPresetState else { throw NSError(domain: "unchanged geometry departure must continue quick apply", code: 1) }
        try check(model.quickPresetsVisible && model.geometryDraft == nil && model.settings.exposure == -0.2,
            "automatic departure from an unchanged draft keeps the quick request and visible result")
        try failureAndRetry(root: directory, photo: second, preset: preset)
    }

    private static func failureAndRetry(root: URL, photo: URL, preset: AdjustmentPreset) throws {
        let directory = root.appendingPathComponent("failed-writes")
        let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"), editDirectory: directory.appendingPathComponent("edits"),
            batchDirectory: directory.appendingPathComponent("batch"), presetDirectory: directory.appendingPathComponent("presets"))
        var failWrites = true
        model.editStore = try EditPersistence(directory: directory.appendingPathComponent("edits"), writeData: { data, url in
            if failWrites { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        model.open(photo); try rendered(model); model.showQuickPresets()
        let before = try model.editStore!.versionedState(for: photo)
        model.applyPresetToCurrentPhoto(preset)
        try wait { !model.quickPresetState.isPreparing }
        guard case .failed = model.quickPresetState else { throw NSError(domain: "failed quick save must not report saved", code: 1) }
        try check(try model.editStore!.versionedState(for: photo) == before && model.adjustmentSession!.transactions.isEmpty,
            "failed quick persistence preserves the target and creates no history")
        failWrites = false
        model.applyPresetToCurrentPhoto(preset)
        try wait { !model.quickPresetState.isPreparing }; try rendered(model)
        try check(model.settings.exposure == 0.7 && model.adjustmentSession!.transactions.count == 1,
            "quick retry prepares again and commits once after storage recovers")
        let missingPayload = try AdjustmentTransferPayload(source: preset.payload.source,
            values: ["looks.reference": .object(["kind": .string("managed"), "id": .string("missing-quick-look")])])
        let missing = try model.presetStore.create(name: "Missing quick look", payload: missingPayload)
        let saved = try model.editStore!.versionedState(for: photo)
        model.applyPresetToCurrentPhoto(missing)
        try wait { !model.quickPresetState.isPreparing }
        guard case .failed(_, let message) = model.quickPresetState else { throw NSError(domain: "missing quick look must be blocked", code: 1) }
        try check(message == model.adjustmentErrorMessage(AdjustmentTransferError.missingLook("missing-quick-look")) &&
            model.adjustmentSession!.transactions.count == 1 && model.editStore!.versionedState(for: photo) == saved,
            "missing quick look reports its preflight error before any save")
    }
}
