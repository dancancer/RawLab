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
    }
}
