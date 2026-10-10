import Foundation

@main
struct EditMemoryTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawlab-edit-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = PhotoIdentity(resourceIdentifier: "asset-a")
        let second = PhotoIdentity(resourceIdentifier: "asset-b")
        let sameNameA = root.appendingPathComponent("one/IMG_0001.ARW")
        let sameNameB = root.appendingPathComponent("two/IMG_0001.ARW")
        try FileManager.default.createDirectory(at: sameNameA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sameNameB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: sameNameA)
        try Data("second".utf8).write(to: sameNameB)
        let store = try EditPersistence(directory: root)
        var changed = RawSettings.default
        changed.exposure = 0.75
        changed.whiteBalanceMode = .custom
        changed.temperature = 4250
        changed.denoise = RawDenoiseSettings(enabled: true, luma: 10, chroma: 72, coarse: 100)
        changed.photoEffects.vignetteMidpoint = 62
        changed.photoEffects.grainSize = 60
        try store.save(first, state: PhotoEditState(settings: changed, filmID: "provia"))

        let reopened = try EditPersistence(directory: root)
        check(reopened.state(for: first)?.settings.exposure == 0.75, "edit survives restart")
        check(reopened.state(for: first)?.settings.denoise == changed.denoise, "denoise survives restart")
        check(reopened.state(for: first)?.settings.photoEffects == changed.photoEffects,
              "photo effects auxiliary values survive restart even when amount is zero")
        check(reopened.state(for: first)?.settings.whiteBalanceMode == .custom, "white balance mode survives restart")
        check(reopened.state(for: second) == nil, "unseen photo uses no previous record")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as! [String: Any]
        legacy.removeValue(forKey: "denoise")
        legacy.removeValue(forKey: "photoEffects")
        legacy.removeValue(forKey: "displayChromaDenoise")
        let legacySettings = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(legacySettings.denoise == RawDenoiseSettings(), "older records default to disabled denoise")
        check(legacySettings.photoEffects == PhotoEffectsSettings(), "older records default to disabled photo effects")

        try store.save(sameNameA, state: PhotoEditState(settings: changed))
        var other = RawSettings.default
        other.exposure = -1
        try store.save(sameNameB, state: PhotoEditState(settings: other))
        check(store.state(for: sameNameA)?.settings.exposure == 0.75, "same names in different locations stay separate")
        check(store.state(for: sameNameB)?.settings.exposure == -1, "second same-named input keeps its own record")

        try store.reset(first)
        check(store.state(for: first) == nil, "reset removes the persisted record")
        let failureDirectory = root.appendingPathComponent("failure-store")
        let failureStore = try EditPersistence(directory: failureDirectory)
        try failureStore.save(first, state: PhotoEditState(settings: changed))
        let backup = root.appendingPathComponent("last-good")
        try FileManager.default.moveItem(at: failureDirectory, to: backup)
        try Data("not a directory".utf8).write(to: failureDirectory)
        do {
            try failureStore.save(first, state: PhotoEditState(settings: other))
            fatalError("failed write was accepted")
        } catch { }
        check(failureStore.state(for: first)?.settings == changed, "failed save does not commit in-memory records")
        let lastGood = try EditPersistence(directory: backup)
        check(lastGood.state(for: first)?.settings == changed, "failed replacement preserves previous durable records")
        var manualTint = RawSettings.default.customWhiteBalance(cameraTemperature: 5200, cameraTint: 8)
        manualTint.tint = 12
        check(manualTint.temperature == 5200 && manualTint.whiteBalanceMode == .custom,
              "editing tint from camera WB preserves the camera temperature")
        var manualTemperature = RawSettings.default.customWhiteBalance(cameraTemperature: 5200, cameraTint: 8)
        manualTemperature.temperature = 6000
        check(manualTemperature.tint == 8, "editing temperature preserves the camera tint")
        let retained = try PhotoImportFile.retain(sameNameA)
        try FileManager.default.removeItem(at: sameNameA)
        let retainedBytes = try Data(contentsOf: retained)
        check(retainedBytes == Data("first".utf8), "picker callback owns bytes after provider file expires")
        PhotoImportFile.release(retained)
        check(!FileManager.default.fileExists(atPath: retained.path), "temporary picker ownership is released after use")
        PhotoImportFile.release(sameNameB)
        check(FileManager.default.fileExists(atPath: sameNameB.path), "temporary cleanup never removes unrelated inputs")
        print("PASS: edit memory regression suite")
    }
}
