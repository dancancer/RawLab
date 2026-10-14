import AppKit

private struct Failure: Error { let message: String }
private var checks = 0
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    if try !value() { throw Failure(message: message) }
}

@main struct GeometryEditSessionTests {
    static func main() throws {
        var committed = GeometrySettings()
        committed.cropX = 0.1; committed.cropY = 0.15
        committed.cropWidth = 0.7; committed.cropHeight = 0.6
        committed.perspectiveHorizontal = 0.08
        var session = GeometryEditSession(committed)
        try check(session.draft == committed && !session.hasChanges, "session starts from the committed geometry")
        try check(session.previewGeometry.cropWidth == 1 && session.previewGeometry.cropHeight == 1 &&
                  session.previewGeometry.cropX == 0 && session.previewGeometry.cropY == 0 &&
                  session.previewGeometry.perspectiveHorizontal == 0.08, "draft preview keeps transforms on the full canvas")
        var crop = committed; crop.cropWidth = 0.5
        try check(!session.update(crop) && session.hasChanges, "crop movement updates draft without rendering")
        try check(!session.update(crop), "repeating a draft update does not render")
        var transform = crop; transform.quarterTurns = 1
        try check(session.update(transform), "rotation requests a new transformed canvas")
        var invalid = transform; invalid.cropWidth = 2
        try check(!session.update(invalid) && session.draft == transform, "invalid draft does not replace a valid selection")
        try check(session.update(GeometrySettings()) && session.draft.isIdentity && session.original == committed,
                  "reset changes only the draft")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-geometry-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let a = root.appendingPathComponent("a.dng"), b = root.appendingPathComponent("b.dng")
        try FileManager.default.copyItem(at: source, to: a)
        try FileManager.default.copyItem(at: source, to: b)
        let original = try Data(contentsOf: a)
        let editDirectory = root.appendingPathComponent("edits")
        let model = EditorModel(lookDirectory: root.appendingPathComponent("looks"), editDirectory: editDirectory,
                                batchDirectory: root.appendingPathComponent("batch"))
        model.films = []; model.selectedFilmID = ""
        func waitForRender() throws {
            let deadline = Date().addingTimeInterval(60)
            while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            try check(!model.busy && model.error == nil && model.result != nil, "render completes")
        }
        func saved() throws -> GeometrySettings {
            try EditPersistence(directory: editDirectory).state(for: a)!.settings.geometrySettings
        }
        model.open(a)
        try waitForRender()
        model.settings.geometry = committed
        model.settings.exposure = 0.35
        try check(model.saveEdits(), "committed baseline saves")
        try waitForRender()
        let croppedWidth = model.result!.nativeWidth!
        let baselineRecord = try Data(contentsOf: editDirectory.appendingPathComponent("edits.json"))

        model.beginGeometryEditing()
        try waitForRender()
        try check(model.geometryPreviewReady && model.isEditingGeometry, "editing publishes a full transformed canvas")
        try check(model.result!.nativeWidth! > croppedWidth, "editing preview removes committed crop")
        let uncroppedWidth = model.result!.nativeWidth!
        let fullFrame = model.result!.image
        for index in 0..<24 {
            var draft = model.geometryDraft
            draft.cropX = 0.12 + Double(index) * 0.001
            draft.cropWidth = 0.5
            model.updateGeometryDraft(draft)
        }
        let selected = model.geometryDraft
        try check(!model.busy && model.result!.image === fullFrame, "repeated crop drags trigger no RAW render")
        try check(model.settings.geometrySettings == committed && model.settings.exposure == 0.35,
                  "draft does not mutate committed adjustments")
        try check(model.saveEdits() && saved() == committed, "explicit save never persists the draft")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try check(try Data(contentsOf: editDirectory.appendingPathComponent("edits.json")) == baselineRecord,
                  "draft changes do not schedule autosave")
        try check(!model.canApplySettings && !model.prepareBatch(), "copy and batch export are guarded during editing")
        var copyRejected = false
        do { _ = try model.applyCurrentSettings(to: [b]) } catch { copyRejected = true }
        try check(copyRejected, "copy settings cannot bypass the editing guard")
        _ = NSApplication.shared
        model.export(format: .jpeg)
        try check(NSApp.modalWindow == nil && !model.exporting, "single export cannot open while editing")

        model.applyGeometryEditing()
        try check(!model.isEditingGeometry && model.settings.geometrySettings == selected && saved() == selected,
                  "apply commits and persists the selected geometry")
        try waitForRender()
        let appliedSize = CGSize(width: CGFloat(model.result!.nativeWidth!), height: CGFloat(model.result!.nativeHeight!))
        try check(model.result!.nativeWidth! < uncroppedWidth,
                  "apply renders the selected crop")
        model.beginGeometryEditing(); try waitForRender()
        model.applyGeometryEditing(); try waitForRender()
        try check(model.result!.nativeWidth! == Int(appliedSize.width), "unchanged apply restores the final cropped render")

        let appliedRecord = try Data(contentsOf: editDirectory.appendingPathComponent("edits.json"))
        model.beginGeometryEditing(); try waitForRender()
        model.rotateGeometryDraft(clockwise: true)
        model.setGeometryDraft(.perspectiveVertical, to: 0.4)
        model.cancelGeometryEditing()
        try waitForRender()
        try check(model.settings.geometrySettings == selected && model.result!.nativeWidth! == Int(appliedSize.width) &&
                  model.result!.nativeHeight! == Int(appliedSize.height), "cancel and late draft renders restore the committed canvas")
        try check(try Data(contentsOf: editDirectory.appendingPathComponent("edits.json")) == appliedRecord,
                  "cancel performs no save")

        model.beginGeometryEditing(); try waitForRender()
        model.selectGeometryAspect(.square)
        try check(abs(model.geometryDraft.cropWidth * Double(model.geometryCanvasSize.width) /
                      (model.geometryDraft.cropHeight * Double(model.geometryCanvasSize.height)) - 1) < 0.000001,
                  "preset ratio uses native physical dimensions")
        model.setGeometryDraft(.cropWidth, to: 0.3)
        try check(abs(model.geometryDraft.cropWidth - 0.3) < 0.000001 &&
                  abs(model.geometryDraft.cropWidth * Double(model.geometryCanvasSize.width) /
                      (model.geometryDraft.cropHeight * Double(model.geometryCanvasSize.height)) - 1) < 0.000001,
                  "precise width keeps the selected aspect ratio")
        model.rotateGeometryDraft(clockwise: true)
        try check(!model.geometryPreviewReady && model.busy, "rotation marks its previous canvas unavailable for apply")
        model.applyGeometryEditing()
        try check(model.isEditingGeometry && model.settings.geometrySettings == selected && saved() == selected,
                  "rapid apply cannot commit against the previous canvas")
        try waitForRender()
        try check(model.geometryPreviewReady && abs(model.geometryDraft.cropWidth * Double(model.geometryCanvasSize.width) /
                  (model.geometryDraft.cropHeight * Double(model.geometryCanvasSize.height)) - 1) < 0.000001,
                  "the matching rotated canvas refits the physical square before enabling apply")
        model.rotateGeometryDraft(clockwise: false)
        try waitForRender()
        model.resetGeometryDraft()
        try check(model.geometryDraft.isIdentity && model.settings.geometrySettings == selected && saved() == selected,
                  "reset stays inside the draft")
        try waitForRender()
        model.applyGeometryEditing(); try waitForRender()
        try check(model.settings.geometry == nil && saved().isIdentity, "applying reset persists identity")
        try check(model.prepareBatch(), "batch remains available after applying")
        model.beginGeometryEditing(); try waitForRender()
        try check(model.batch?.sourceEditingGeometry == true && !model.batch!.canRun,
                  "an already-open batch window cannot export during editing")
        model.setGeometryDraft(.cropWidth, to: 0.5)
        model.open(b); try waitForRender()
        try check(!model.isEditingGeometry && model.settings.geometrySettings.isIdentity &&
                  model.batch?.sourceEditingGeometry == false, "opening another photo discards the session and unlocks the batch")
        model.open(a); try waitForRender()
        try check(model.settings.geometrySettings.isIdentity && saved().isIdentity, "switching photos never saves a pending crop")
        try check(try Data(contentsOf: a) == original && Data(contentsOf: b) == original, "RAW originals remain unchanged")
        print("PASS: \(checks) geometry draft, persistence, render and export checks")
    }
}
