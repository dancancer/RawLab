import Foundation

@main struct EditorToolDraftTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }
    static func main() throws {
        var original = RawSettings.default
        original.saturation = 1.2
        var draft = EditorToolDraft(tool: .adjustment(.exposure), original: original)
        var requested = original; requested.exposure = 1.5; requested.saturation = 1.8
        draft.update(requested, interactive: true)
        requested.exposure = 2
        draft.update(requested, interactive: false)
        var committed = original; committed.saturation = 1.4
        let projected = draft.projecting(on: committed)
        try check(projected.exposure == 2 && projected.saturation == 1.4, "Scalar draft projects only its own fields")
        try check(draft.undoSteps.count == 1, "A drag makes one local undo step")
        draft.undo()
        try check(draft.value == original, "Undo restores the entry values")
        draft.redo()
        try check(draft.value.exposure == 2 && draft.value.saturation == 1.2, "Redo restores only the tool scope")
        var hsl = EditorToolDraft(tool: .adjustment(.hsl), original: original)
        requested = original; requested.hsl.set(.saturation, channel: 2, value: 30); requested.exposure = 3
        hsl.update(requested)
        try check(hsl.value.hsl.saturation[2] == 30 && hsl.value.exposure == original.exposure, "HSL preserves unrelated fields")
        var hdr = RawSettings.default; hdr.hdr = HDRSettings()
        try check(!EditorToolDraft(tool: .film, original: hdr).changed, "Opening an HDR look does not change its version")
        let encoded = try JSONEncoder().encode(draft)
        let reopened = try JSONDecoder().decode(EditorToolDraft.self, from: encoded)
        try check(reopened == draft, "Tool content and local history survive a disk round trip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorToolDraftStore(directory: directory)
        let identity = PhotoIdentity(resourceIdentifier: "source", contentIdentifier: "original-bytes")
        try store.save(identity: identity, draft: draft)
        try check(try store.load(identity: identity, committed: original) == draft, "The same photo restores its draft separately from committed settings")
        try check(try store.load(identity: PhotoIdentity(contentIdentifier: "different"), committed: original) == nil, "Another photo never receives the draft")
        try check(try store.load(identity: identity, committed: committed) == nil, "Changed committed settings invalidate recovery")
        try store.clear(identity: identity)
        try check(try store.load(identity: identity, committed: original) == nil, "Cancel removes the matching draft")
        // V-UIIOS #291 seam：换图（sourceRevision 变化）必须清掉上一张照片留下的子工具状态，
        // 否则收起面板再展开会被旧照片的镜头/配方子工具劫持（ContentView :380-405/:428）。
        let staleLens = EditorToolSourceState(collapsedEditorTool: .lens)
        try check(staleLens.afterSourceChange.collapsedEditorTool == nil,
            "A new photo never inherits the collapsed editor tool of the old one")
        let staleRecipe = EditorToolSourceState(choosingMasterRecipe: true)
        try check(!staleRecipe.afterSourceChange.choosingMasterRecipe,
            "A new photo never stays inside the old master recipe picker")
        try check(EditorToolSourceState().afterSourceChange == EditorToolSourceState(),
            "The overview tool state survives a source change unchanged")

        // D-05 UI draft layer regression: editing one vignette/grain slider or saving/reloading a draft
        // must preserve exact decimals on untouched sibling parameters in both SDR and HDR modes.
        let sdrFx = PhotoEffectsSettings(vignetteAmount: -12.5, vignetteMidpoint: 62.5,
            vignetteRoundness: -12.5, vignetteFeather: 50.5, vignetteHighlights: 12.5,
            grainAmount: 12.25, grainSize: 37.75, grainRoughness: 50.5)
        var sdrDecimalBase = RawSettings.default
        sdrDecimalBase.photoEffects = sdrFx
        try check(!EditorToolDraft(tool: .adjustment(.vignette), original: sdrDecimalBase).changed,
            "Opening a vignette draft with decimals does not mark it changed")
        try check(!EditorToolDraft(tool: .adjustment(.grain), original: sdrDecimalBase).changed,
            "Opening a grain draft with decimals does not mark it changed")

        var vigDraft = EditorToolDraft(tool: .adjustment(.vignette), original: sdrDecimalBase)
        var vigEdit = vigDraft.value
        vigEdit.setEditingEffect(.vignetteAmount, to: -10.3)
        vigDraft.update(vigEdit)
        let vigIdentity = PhotoIdentity(resourceIdentifier: "vig-decimal", contentIdentifier: "vig-bytes")
        try store.save(identity: vigIdentity, draft: vigDraft)
        let loadedVig = try checkPresent(try store.load(identity: vigIdentity, committed: sdrDecimalBase),
            "Vignette decimal draft reloads from store")
        let projectedVig = loadedVig.projecting(on: sdrDecimalBase)
        try check(projectedVig.photoEffects.vignetteAmount == -10.0,
            "Edited vignette UI slider narrows to integer UI step (-10.0)")
        try check(projectedVig.photoEffects.vignetteMidpoint == 62.5
            && projectedVig.photoEffects.vignetteRoundness == -12.5
            && projectedVig.photoEffects.vignetteFeather == 50.5
            && projectedVig.photoEffects.vignetteHighlights == 12.5,
            "Untouched SDR vignette draft siblings preserve decimals after store reload")
        try check(projectedVig.photoEffects.grainAmount == 12.25
            && projectedVig.photoEffects.grainSize == 37.75
            && projectedVig.photoEffects.grainRoughness == 50.5,
            "Vignette draft projection preserves SDR grain decimals")

        var grainDraft = EditorToolDraft(tool: .adjustment(.grain), original: sdrDecimalBase)
        var grainEdit = grainDraft.value
        grainEdit.setEditingEffect(.grainAmount, to: 15.0)
        grainDraft.update(grainEdit)
        let grainIdentity = PhotoIdentity(resourceIdentifier: "grain-decimal", contentIdentifier: "grain-bytes")
        try store.save(identity: grainIdentity, draft: grainDraft)
        let loadedGrain = try checkPresent(try store.load(identity: grainIdentity, committed: sdrDecimalBase),
            "Grain decimal draft reloads from store")
        let projectedGrain = loadedGrain.projecting(on: sdrDecimalBase)
        try check(projectedGrain.photoEffects.grainAmount == 15.0,
            "Edited grain UI slider updates to 15.0")
        try check(projectedGrain.photoEffects.grainSize == 37.75
            && projectedGrain.photoEffects.grainRoughness == 50.5,
            "Untouched SDR grain draft siblings preserve decimals after store reload")

        var hdrDecimalBase = try RawSettings.default.withHDRMode(true, sourceIsHDR: true)
        hdrDecimalBase.hdr?.effectsSettings = HDRPhotoEffectsSettings(
            vignetteAmount: -12.5, vignetteMidpoint: 62.5,
            vignetteRoundness: -12.5, vignetteFeather: 50.5, vignetteHighlights: 12.5,
            grainAmount: 12.25, grainSize: 37.75, grainRoughness: 50.5)
        try check(!EditorToolDraft(tool: .adjustment(.vignette), original: hdrDecimalBase).changed,
            "Opening an HDR vignette draft with decimals does not mark it changed")
        var hdrVigDraft = EditorToolDraft(tool: .adjustment(.vignette), original: hdrDecimalBase)
        var hdrVigEdit = hdrVigDraft.value
        hdrVigEdit.setEditingEffect(.vignetteAmount, to: -10.3)
        hdrVigDraft.update(hdrVigEdit)
        let hdrVigIdentity = PhotoIdentity(resourceIdentifier: "hdr-vig-decimal", contentIdentifier: "hdr-vig-bytes")
        try store.save(identity: hdrVigIdentity, draft: hdrVigDraft)
        let loadedHdrVig = try checkPresent(try store.load(identity: hdrVigIdentity, committed: hdrDecimalBase),
            "HDR vignette decimal draft reloads from store")
        let projectedHdrVig = loadedHdrVig.projecting(on: hdrDecimalBase)
        try check(projectedHdrVig.hdr?.effectsSettings.vignetteAmount == -10.0,
            "Edited HDR vignette UI slider narrows to integer UI step (-10.0)")
        try check(projectedHdrVig.hdr?.effectsSettings.vignetteMidpoint == 62.5
            && projectedHdrVig.hdr?.effectsSettings.vignetteRoundness == -12.5
            && projectedHdrVig.hdr?.effectsSettings.vignetteFeather == 50.5
            && projectedHdrVig.hdr?.effectsSettings.vignetteHighlights == 12.5
            && projectedHdrVig.hdr?.effectsSettings.grainAmount == 12.25
            && projectedHdrVig.hdr?.effectsSettings.grainSize == 37.75
            && projectedHdrVig.hdr?.effectsSettings.grainRoughness == 50.5,
            "Untouched HDR effects preserve exact decimals after draft store reload")

        var hdrGrainDraft = EditorToolDraft(tool: .adjustment(.grain), original: hdrDecimalBase)
        var hdrGrainEdit = hdrGrainDraft.value
        hdrGrainEdit.setEditingEffect(.grainAmount, to: 15.0)
        hdrGrainDraft.update(hdrGrainEdit)
        let hdrGrainIdentity = PhotoIdentity(resourceIdentifier: "hdr-grain-decimal", contentIdentifier: "hdr-grain-bytes")
        try store.save(identity: hdrGrainIdentity, draft: hdrGrainDraft)
        let loadedHdrGrain = try checkPresent(try store.load(identity: hdrGrainIdentity, committed: hdrDecimalBase),
            "HDR grain decimal draft reloads from store")
        let projectedHdrGrain = loadedHdrGrain.projecting(on: hdrDecimalBase)
        try check(projectedHdrGrain.hdr?.effectsSettings.grainAmount == 15.0
            && projectedHdrGrain.hdr?.effectsSettings.grainSize == 37.75
            && projectedHdrGrain.hdr?.effectsSettings.grainRoughness == 50.5,
            "Untouched HDR grain draft siblings preserve exact decimals after store reload")
    }

    static func checkPresent<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
        return value
    }
}
