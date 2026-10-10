import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main struct EditMemoryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a/same.ARW")
        let b = root.appendingPathComponent("b/same.ARW")
        for file in [a, b] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("raw fixture".utf8).write(to: file)
        }
        let directory = root.appendingPathComponent("records")
        let store = try EditPersistence(directory: directory)
        var settings = Adjustments()
        settings.exposure = 0.75
        settings.rawNoiseReduction = 2
        settings.setEffect(.vignetteAmount, to: -40)
        settings.setEffect(.vignetteFeather, to: 70)
        settings.setEffect(.grainAmount, to: 60)
        settings.setEffect(.grainRoughness, to: 30)
        settings.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 8))
        settings.set(.temperature, to: 6000)
        try store.save(a, state: PhotoEditState(settings: settings, filmID: "look-id"))
        let reopened = try EditPersistence(directory: directory)
        let restored = try reopened.state(for: a)
        try check(restored?.settings == settings, "all settings survive reopening the store")
        try check(restored?.filmID == "look-id", "look identity survives restart")
        try check(try reopened.state(for: b) == nil, "same basename must not share edits")
        settings.denoiseMode = 2
        try reopened.save(a, state: PhotoEditState(settings: settings, filmID: "look-id"))
        let chroma = try EditPersistence(directory: directory).state(for: a)?.settings
        try check(chroma?.chromaNoiseReduction == 2 && chroma?.rawNoiseReduction == 0,
                  "new denoise mode survives restart without re-enabling legacy FBDD")
        settings.applyDenoisePreset(.clean)
        settings.setDenoiseParameter(.luma, to: 53)
        settings.setDenoiseEnabled(false)
        try reopened.save(a, state: PhotoEditState(settings: settings, filmID: "look-id"))
        let wavelet = try EditPersistence(directory: directory).state(for: a)?.settings
        try check(wavelet?.waveletSettings.luma == 53 && wavelet?.waveletSettings.preset == .custom &&
                  wavelet?.waveletSettings.enabled == false && wavelet?.chromaNoiseReduction == nil,
                  "disabled custom wavelet settings survive restart without reviving old algorithms")
        settings.resetAll()
        try reopened.save(a, state: PhotoEditState(settings: settings, filmID: "look-id"))
        try check(try EditPersistence(directory: directory).state(for: a)?.settings.exposure == 0,
                  "reset must persist, not resurrect old values")
        try Data("replacement raw".utf8).write(to: a)
        try check(try reopened.state(for: a) == nil, "a replaced file must not inherit prior edits")
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let cannotSave = try EditPersistence(directory: blocked)
        do {
            try cannotSave.save(b, state: PhotoEditState(settings: settings, filmID: ""))
            throw Failure(message: "failed write must propagate")
        } catch is CocoaError { }
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("edits.json"))
        do {
            _ = try EditPersistence(directory: directory)
            throw Failure(message: "corrupt store must not be silently replaced")
        } catch is DecodingError { }
        print("PASS: edit restart, identity, reset, all fields, failed writes and corrupt store")
    }
}
