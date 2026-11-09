import Foundation

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main struct EditMemoryTests {
    static func processingMigrationChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("migration.dng")
        try Data("original".utf8).write(to: photo)
        let directory = root.appendingPathComponent("edits")
        let store = try EditPersistence(directory: directory)
        var settings = Adjustments(); settings.processing = .c5; settings.exposure = 0.5
        settings.highlights = -20; settings.vibrance = 17.5
        let original = PhotoEditState(settings: settings, filmID: "saved-look")
        try store.save(photo, state: original)
        let expected = try store.readState(for: photo)
        let quality = ProcessingMigrationQuality(rgbRMSE: 0.001, p99Error: 0.003, worstTileRMSE: 0.002,
            detailRMSE: 0.001, evaluations: 24)
        var candidate = original; candidate.settings.processing = .current; candidate.settings.highlights = -14
        let failing = try EditPersistence(directory: directory, writeData: { _, _ in throw Failure(message: "disk full") })
        let file = directory.appendingPathComponent("edits.json"), before = try Data(contentsOf: file)
        do {
            _ = try failing.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
            throw Failure(message: "failed migration save must throw")
        } catch let error as Failure { try check(error.message == "disk full", "migration write failure is propagated") }
        try check(try Data(contentsOf: file) == before, "failed atomic write preserves old pixels and does not lose backup")
        _ = try store.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
        let reopened = try EditPersistence(directory: directory)
        try check(try reopened.state(for: photo) == candidate, "accepted migration survives restart")
        try check(try reopened.processingMigration(for: photo)?.original == original, "full original look and settings are durable")
        do {
            _ = try reopened.commitProcessingMigration(expected: expected, candidate: candidate, quality: quality)
            throw Failure(message: "stale fit must fail")
        } catch AdjustmentCommitError.expired { }
        var later = candidate; later.settings.exposure = 1.25
        try reopened.save(photo, state: later)
        let rollbackExpected = try reopened.readState(for: photo)
        let restored = try reopened.rollbackProcessingMigration(expected: rollbackExpected)
        try check(restored.state == original, "rollback restores all original parameters, version and look after later edits")
        let receipt = try reopened.processingMigration(for: photo)!
        try check(receipt.status == .rolledBack && !receipt.shouldAttempt(current: original, sourceVersion: 2),
            "rollback suppresses repeated automatic migration after restart")

        let rejectedPhoto = root.appendingPathComponent("rejected.dng")
        try Data("second".utf8).write(to: rejectedPhoto)
        try store.save(rejectedPhoto, state: original)
        let rejectedExpected = try store.readState(for: rejectedPhoto)
        let highError = ProcessingMigrationQuality(rgbRMSE: 0.1, p99Error: 0.2, worstTileRMSE: 0.2, detailRMSE: 0.02, evaluations: 161)
        _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: nil, quality: highError)
        try check(try store.readState(for: rejectedPhoto) == rejectedExpected, "rejected fit preserves the complete old record")
        let kept = try store.processingMigration(for: rejectedPhoto)!
        try check(!kept.shouldAttempt(current: original, sourceVersion: 2), "unchanged rejected settings do not retry")
        var edited = original; edited.settings.shadows = 25
        try check(kept.shouldAttempt(current: edited, sourceVersion: 2), "changed rejected settings may be reconsidered")
        try store.save(rejectedPhoto, state: edited)
        do {
            _ = try store.commitProcessingMigration(expected: rejectedExpected, candidate: candidate, quality: quality)
            throw Failure(message: "cross-instance concurrent edit must win")
        } catch AdjustmentCommitError.expired { }
        try check(try store.state(for: rejectedPhoto) == edited, "stale candidate cannot overwrite another save")
        print("PASS: processing migration atomic CAS, rejection, persistence and rollback")
    }

    static func protectedStoreChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("photo.ARW")
        try Data("fixture".utf8).write(to: input)
        let store = try EditPersistence(directory: root)
        let state = PhotoEditState(settings: Adjustments(), filmID: "")
        try store.save(input, state: state)
        let file = root.appendingPathComponent("edits.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var records = object["records"] as! [String: Any]
        let key = records.keys.first!
        var record = records[key] as! [String: Any]
        var savedState = record["state"] as! [String: Any]
        var settings = savedState["settings"] as! [String: Any]
        settings["processing"] = ["family": "rawlab", "version": 99, "quality": "standard"]
        savedState["settings"] = settings; record["state"] = savedState; records[key] = record; object["records"] = records
        let protectedBytes = try JSONSerialization.data(withJSONObject: object)
        try protectedBytes.write(to: file)
        do {
            _ = try EditPersistence(directory: root)
            throw Failure(message: "unknown processing must reject the registry")
        } catch is DecodingError { }
        do {
            try store.save(input, state: state)
            throw Failure(message: "an already-open store must not replace unknown processing records")
        } catch is DecodingError { }
        try check(try Data(contentsOf: file) == protectedBytes, "unsupported records stay byte-identical")
    }

    static func processingIdentityChecks() throws {
        func identity(_ settings: Adjustments) throws -> NSDictionary? {
            let data = try JSONEncoder().encode(settings)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return object["processing"] as? NSDictionary
        }
        let legacy: NSDictionary = ["family": "rawlab", "version": 1, "quality": "standard"]
        let current: NSDictionary = ["family": "rawlab", "version": 3, "quality": "standard"]
        for endpoint in [-5.0, 5.0] {
            var settings = Adjustments(); settings.exposure = endpoint
            try settings.validateResetValues()
            let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
            try check(restored.exposure == endpoint, "ordinary exposure endpoints survive persistence")
            let hdr = try settings.withHDRMode(true, sourceIsHDR: true)
            try check(AdjustmentParameter.exposure.spec(for: settings).range == -5...5 &&
                      AdjustmentParameter.exposure.spec(for: hdr).range == -4...4,
                      "HDR UI retains its separate exposure range")
        }
        try check(try identity(Adjustments()) == current, "new desktop edits explicitly store processing v3")
        var restored = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        try check(try identity(restored) == legacy, "missing processing identity restores legacy, not the new default")
        restored.exposure = 0.7
        restored.applyDenoisePreset(.clean)
        try check(try identity(restored) == legacy, "ordinary edits and denoise presets cannot upgrade processing")
        restored.resetAll()
        try check(try identity(restored) == legacy, "reset keeps the restored processing identity")
        try check(try identity(restored.neutralGeometrySettings) == legacy, "neutral geometry keeps processing identity")
        for version in [1, 2, 3] {
            let bytes = try JSONSerialization.data(withJSONObject: ["processing":
                ["family": "rawlab", "version": version, "quality": "standard"]])
            var saved = try JSONDecoder().decode(Adjustments.self, from: bytes)
            saved.exposure = 0.5
            saved.resetAll()
            try check((try identity(saved))?["version"] as? Int == version,
                      "explicit versions survive editing and reset without upgrades")
        }
        for invalid: Any in [
            NSNull(),
            ["family": "other", "version": 1, "quality": "standard"],
            ["family": "rawlab", "version": 4, "quality": "standard"],
            ["family": "rawlab", "version": 0, "quality": "standard"],
            ["family": "rawlab", "version": true, "quality": "standard"],
            ["family": "rawlab", "version": 1, "quality": "fast"],
            ["family": "rawlab", "version": 1],
            ["family": "rawlab", "version": 2, "quality": "standard", "future": true],
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["processing": invalid])
            do {
                _ = try JSONDecoder().decode(Adjustments.self, from: data)
                throw Failure(message: "unknown or malformed processing identity must not become default settings")
            } catch is DecodingError { }
        }
        print("PASS: explicit processing identity, legacy decode, reset preservation and unknown-version rejection")
    }

    static func main() throws {
        var x3f = Adjustments()
        try check(x3f.x3fMode == .normal, "new edits select normal X3F rendering")
        x3f.x3fMode = .legacy
        x3f.resetAll()
        try check(x3f.x3fMode == .legacy && x3f.neutralSettings.x3fMode == .legacy, "reset/reference preserve X3F identity")
        let oldX3f = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        try check(oldX3f.x3fMode == .legacy, "old edits never silently adopt normal X3F rendering")
        for invalid in ["null", "\"future\"", "1"] {
            do {
                _ = try JSONDecoder().decode(Adjustments.self, from: Data("{\"x3fMode\":\(invalid)}".utf8))
                throw Failure(message: "unknown X3F identity must be rejected")
            } catch is DecodingError { }
        }
        x3f.x3fMode = .normal
        try check(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(x3f)).x3fMode == .normal,
                  "X3F mode survives save/reopen and batch serialization")
        try processingIdentityChecks()
        try processingMigrationChecks()
        try protectedStoreChecks()
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
        settings.exposureMode = .sensor
        settings.setHSL(.hue, channel: 5, value: 40)
        settings.rawNoiseReduction = 2
        settings.setEffect(.vignetteAmount, to: -40)
        settings.setEffect(.vignetteFeather, to: 70)
        settings.setEffect(.grainAmount, to: 60)
        settings.setEffect(.grainRoughness, to: 30)
        settings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false,
            mode: .manual, profileID: "saved-lens-profile")
        settings.setGeometry(.cropWidth, to: 0.6)
        settings.setGeometry(.cropX, to: 0.2)
        settings.setGeometry(.cropHeight, to: 0.75)
        settings.setGeometry(.cropY, to: 0.1)
        settings.rotateGeometry(clockwise: true)
        settings.flipGeometry(horizontal: true)
        settings.setGeometry(.straightenDegrees, to: -7.5)
        settings.resolveWhiteBalance(WhiteBalance(temperature: 5200, tint: 8))
        settings.set(.temperature, to: 6000)
        try store.save(a, state: PhotoEditState(settings: settings, filmID: "look-id"))
        let reopened = try EditPersistence(directory: directory)
        let restored = try reopened.state(for: a)
        try check(restored?.settings == settings, "all settings survive reopening the store")
        try check(restored?.settings.geometrySettings == settings.geometrySettings, "geometry survives persistence restart")
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
