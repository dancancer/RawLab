import AppKit

@main struct DenoiseModelTests {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        print("PASS: \(message)")
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel(lookDirectory: folder.appendingPathComponent("looks"),
                                editDirectory: folder.appendingPathComponent("edits"),
                                batchDirectory: folder.appendingPathComponent("batch"))
        func wait() {
            let deadline = Date().addingTimeInterval(120)
            while model.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(!model.busy && model.error == nil && model.result != nil, "RAW rendering completes")
        }
        model.open(URL(fileURLWithPath: CommandLine.arguments[1])); wait()
        let original = model.neutral!.image
        check(model.neutral!.isFullResolution, "Original records native pixel geometry")
        model.settings.applyDenoisePreset(.clean); wait()
        check(model.neutral!.image === original, "Denoise never replaces the original")
        model.settings.exposure = 1; wait()
        check(model.neutral!.image === original, "Exposure never replaces the original")
        model.settings.set(.temperature, to: 8000); wait()
        check(model.neutral!.image === original, "WB never replaces the original")
        model.fullResolution = true; wait()
        let exact = model.result!.image
        model.setInteracting(true)
        model.settings.setDenoiseParameter(.chroma, to: 68)
        let deadline = Date().addingTimeInterval(60)
        while model.result?.image === exact && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check(model.result?.image !== exact && model.neutral!.image === original, "Proxy publishes without changing original")
        model.setInteracting(false); wait()
        check(model.result!.isFullResolution && model.neutral!.image === original, "Exact render retains original and native output")
    }
}
