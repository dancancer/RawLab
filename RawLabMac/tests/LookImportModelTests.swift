import AppKit
import Foundation
import ImageIO

@main
struct LookImportModelTests {
    static func check(_ value: Bool, _ label: String) {
        print("\(value ? "PASS" : "FAIL") \(label)")
        if !value { exit(1) }
    }

    static func settle(_ model: EditorModel) {
        let deadline = Date().addingTimeInterval(10)
        while model.lookLibraryBusy && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(!model.lookLibraryBusy, "look operation completes without blocking the main thread")
    }

    static func main() throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("rawlab-look-model-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let directory = root.appendingPathComponent("library")
        let edits = root.appendingPathComponent("edits"), jobs = root.appendingPathComponent("batch")
        let source = root.appendingPathComponent("My look.cube")
        let text = "#Gamma:F-Log2 to Model Test\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 2\n" +
            Array(repeating: "0.2 0.4 0.6\n", count: 8).joined()
        try text.write(to: source, atomically: true, encoding: .utf8)
        let model = EditorModel(lookDirectory: directory, editDirectory: edits, batchDirectory: jobs)
        model.importLook(source)
        settle(model)
        guard let imported = model.selectedFilm, let id = imported.managedID else {
            check(false, "successful import selects a managed look")
            return
        }
        check(model.error == nil && imported.name == "My look", "successful import selects a managed look")
        check(imported.id == id && imported.url != source, "rendering receives the managed file, not the external source")
        try manager.removeItem(at: source)
        let restored = EditorModel(lookDirectory: directory, editDirectory: edits, batchDirectory: jobs)
        check(restored.films.contains { $0.id == id }, "new editor restores imported looks")
        restored.selectedFilmID = id
        let bad = root.appendingPathComponent("bad.cube")
        try "LUT_3D_SIZE 2\n".write(to: bad, atomically: true, encoding: .utf8)
        restored.importLook(bad)
        settle(restored)
        check(restored.selectedFilmID == id && restored.lookImportReport != nil, "failed import preserves selection and reports failure")
        restored.renameLook(id: id, name: "Renamed")
        settle(restored)
        check(restored.selectedFilm?.name == "Renamed" && restored.selectedFilmID == id, "rename refreshes the selected label without changing identity")
        restored.removeLook(id: id)
        settle(restored)
        check(restored.selectedFilmID == id && restored.missingFilm && !restored.films.contains { $0.id == id }, "removing the active look preserves identity instead of silently selecting neutral")
        check(!manager.fileExists(atPath: imported.url.path), "removing the active look removes its managed bytes")
        let afterDelete = EditorModel(lookDirectory: directory, editDirectory: edits, batchDirectory: jobs)
        check(!afterDelete.films.contains { $0.id == id }, "removed look does not return on restart")

        let first = root.appendingPathComponent("First batch look.cube")
        let last = root.appendingPathComponent("Last batch look.cube")
        try text.write(to: first, atomically: true, encoding: .utf8)
        try text.write(to: last, atomically: true, encoding: .utf8)
        afterDelete.importLooks([first, bad, last])
        settle(afterDelete)
        let batch = afterDelete.films.filter { $0.managedID != nil }
        check(batch.count == 2, "batch continues after an invalid file and preserves both valid imports")
        check(afterDelete.selectedFilm?.name == "Last batch look", "batch selects the last successful import")
        check(afterDelete.lookImportReport?.contains("bad.cube") == true, "batch failure identifies the failed file")
        check(try Data(contentsOf: first) == Data(text.utf8) && Data(contentsOf: last) == Data(text.utf8),
              "batch import preserves source files")
        let selected = afterDelete.selectedFilmID
        let invalidSecond = root.appendingPathComponent("also-bad.cube")
        try "bad".write(to: invalidSecond, atomically: true, encoding: .utf8)
        afterDelete.importLooks([bad, invalidSecond])
        settle(afterDelete)
        check(afterDelete.selectedFilmID == selected && afterDelete.films.filter { $0.managedID != nil }.count == 2,
              "all-failed batch preserves selection and existing library")
        check(afterDelete.lookImportReport?.contains("bad.cube") == true && afterDelete.lookImportReport?.contains("also-bad.cube") == true,
              "all-failed batch reports every failed filename")
        let previousError = afterDelete.lookImportReport
        afterDelete.importLooks([])
        check(!afterDelete.lookLibraryBusy && afterDelete.lookImportReport == previousError, "cancelling multi-selection changes nothing")
        afterDelete.importLooks([first, last])
        settle(afterDelete)
        check(afterDelete.lookImportReport == nil && afterDelete.films.filter { $0.managedID != nil }.count == 4,
              "successful batch clears old errors without overwriting same-name imports")
        let reloadedBatch = EditorModel(lookDirectory: directory, editDirectory: edits, batchDirectory: jobs)
        check(reloadedBatch.films.filter { $0.managedID != nil }.count == 4, "all batch imports survive restart")

        let dcp = root.appendingPathComponent("Camera look.dcp")
        let unsupportedDCP = root.appendingPathComponent("No curve.dcp")
        let ready = root.appendingPathComponent("Ready.rlook")
        try DCPTestFixtures.make().write(to: dcp)
        try DCPTestFixtures.make(missing: [50940]).write(to: unsupportedDCP)
        try DCPCompiler.compile(source: dcp).write(to: ready)
        reloadedBatch.importLooks([dcp, unsupportedDCP, ready, first])
        settle(reloadedBatch)
        check(reloadedBatch.films.filter { $0.managedID != nil }.count == 7, "mixed DCP/RLOOK/CUBE batch retains every supported import")
        check(reloadedBatch.films.contains { $0.name == "Camera look" && $0.url.pathExtension == "rlook" }, "DCP import feeds a managed RLOOK into rendering")
        check(reloadedBatch.selectedFilm?.name == "First batch look", "mixed batch selects its last successful import")
        check(reloadedBatch.lookImportReport?.contains("No curve.dcp") == true &&
              reloadedBatch.lookImportReport?.contains(DCPCompilerError.missingToneCurve.localizedDescription) == true,
              "mixed-batch report retains the source filename and specific DCP reason")
        let dcpSelection = reloadedBatch.selectedFilmID
        reloadedBatch.importLooks([unsupportedDCP])
        settle(reloadedBatch)
        check(reloadedBatch.selectedFilmID == dcpSelection && reloadedBatch.films.filter { $0.managedID != nil }.count == 7,
              "unsupported DCP preserves the active look and existing library")

        if let rawPath = ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"] {
            let raw = URL(fileURLWithPath: rawPath)
            var film = reloadedBatch.films.first { $0.name == "Camera look" }!
            if let profilePath = ProcessInfo.processInfo.environment["RAWLAB_TEST_DCP"] {
                let profile = URL(fileURLWithPath: profilePath)
                let original = try Data(contentsOf: profile)
                reloadedBatch.importLook(profile)
                settle(reloadedBatch)
                check(reloadedBatch.lookImportReport == nil && reloadedBatch.selectedFilm?.url.pathExtension == "rlook",
                      "a privately owned real DCP imports through the actual Mac model")
                check(try Data(contentsOf: profile) == original, "real source profile remains unchanged")
                film = reloadedBatch.selectedFilm!
            }
            let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            let automatic = try RenderEngine()
            let forced = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
            let reference = try cpu.render(raw, settings: Adjustments(), lut: film.url, edge: 400)!
            for (engine, name) in [(automatic, "Auto"), (forced, "Force Metal")] {
                let actual = try engine.render(raw, settings: Adjustments(), lut: film.url, edge: 400)!
                let expected = reference.image.dataProvider!.data! as Data
                let bytes = actual.image.dataProvider!.data! as Data
                let difference = zip(expected, bytes).map { abs(Int($0) - Int($1)) }.max() ?? 999
                check(expected.count == bytes.count && !bytes.isEmpty && difference <= 2,
                      "imported DCP renders real RAW consistently on CPU/\(name), max DN=\(difference)")
            }
            for suffix in ["jpg", "png"] {
                let output = root.appendingPathComponent("dcp-export.\(suffix)")
                _ = try automatic.render(raw, settings: Adjustments(), lut: film.url, edge: nil, output: output, exportLongEdge: 400)
                guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    check(false, "DCP export must decode as an actual image"); return
                }
                check(image.width == reference.image.width && image.height == reference.image.height,
                      "imported DCP exports correctly sized \(suffix.uppercased())")
                if suffix == "png" { check(image.bitsPerComponent == 16, "DCP PNG export retains sixteen-bit precision") }
            }
        }
    }
}
