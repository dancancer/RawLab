import Foundation

@main struct AdjustmentPersistenceTests {
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: label, code: 1) }; print("PASS: \(label)")
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { print("PASS: \(label)"); return }
        throw NSError(domain: label, code: 1)
    }
    static func main() throws {
        try refinedRecipe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try EditPersistence(directory: root), second = try EditPersistence(directory: root)
        let a = PhotoIdentity(resourceIdentifier: "a"), b = PhotoIdentity(resourceIdentifier: "b")
        var settings = RawSettings.default; settings.exposure = 1
        try first.save(a, state: .init(settings: settings))
        settings.exposure = 2; try second.save(b, state: .init(settings: settings))
        let reopened = try EditPersistence(directory: root)
        try check(reopened.state(for: a)?.settings.exposure == 1 && reopened.state(for: b)?.settings.exposure == 2,
            "Independent store instances preserve both photos")
        try check(first.state(for: b)?.settings.exposure == 2, "Existing readers observe another instance's save")
        let saved = try first.versionedState(for: a)
        try check(saved.revision != nil, "A successful edit creates a per-photo revision")
        let metadataOnly = PhotoEditState(settings: saved.state!.settings, updatedAt: Date(timeIntervalSince1970: 999))
        let unchanged = try first.compareAndSave(expected: saved, state: metadataOnly)
        try check(unchanged == saved, "Timestamp-only changes keep the complete stored receipt")
        settings.exposure = 3
        let changed = try first.compareAndSave(expected: saved, state: .init(settings: settings))
        try check(changed.revision != saved.revision && changed.state?.settings.exposure == 3, "CAS saves a new revision atomically")
        try rejects("Stale CAS cannot overwrite a later save") { _ = try second.compareAndSave(expected: saved, state: metadataOnly) }
        let missing = PhotoIdentity(resourceIdentifier: "missing")
        let absent = try first.versionedState(for: missing)
        _ = try first.compareAndSave(expected: absent, state: metadataOnly)
        try first.reset(missing)
        let deleted = try first.versionedState(for: missing)
        try check(deleted.state == nil && deleted.revision != nil, "Deletion retains a revision tombstone")
        try rejects("Delete and recreate cannot bypass a prepared absence") { _ = try first.compareAndSave(expected: absent, state: metadataOnly) }
        let file = root.appendingPathComponent("edits.json"), bytes = try Data(contentsOf: file)
        let failing = try EditPersistence(directory: root, writeData: { _, _ in throw NSError(domain: "injected write", code: 1) })
        settings.exposure = -1
        try rejects("Injected atomic write failure is reported") { _ = try failing.compareAndSave(expected: changed, state: .init(settings: settings)) }
        try check(try Data(contentsOf: file) == bytes && first.versionedState(for: a) == changed, "Write failure preserves bytes and revision")
        var invalid = settings; invalid.exposure = .nan
        try rejects("Invalid JSON cannot replace the old registry") { try first.save(a, state: .init(settings: invalid)) }
        try check(try Data(contentsOf: file) == bytes, "Encoding failure preserves the registry")
        try rejects("Invalid identity cannot be saved") { try first.save(.init(resourceIdentifier: ""), state: metadataOnly) }
        try legacy(root.appendingPathComponent("legacy"))
        try corrupt(root.appendingPathComponent("corrupt"))
        try concurrent(root.appendingPathComponent("concurrent"))
        try unavailable(root.appendingPathComponent("unavailable"))
    }

    static func refinedRecipe() throws {
        let recipe = try JSONDecoder().decode(MasterRecipe.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Shared/fixtures/master-recipe-v4.json")))
        var state = RawSettings.default
        state.blackPoint = -20; state.clarity = -40; state.toneCurve = 0.35
        state.temperature = 8000; state.sharpening = 0.75
        state.applyMasterRecipe(recipe)
        try check(state.blackPoint == 50 && state.whitePoint == -60 && state.vibrance == 15 &&
                  state.clarity == 12 && state.dehaze == -6 && state.curveSettings.mode == .custom &&
                  state.gradingSettings.shadows.saturation == 8 && state.toneCurve == 0,
                  "Explicit refined recipe replaces all visible new controls")
        let restored = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(state))
        try check(restored == state, "Refined recipe survives photo settings round-trip")
        for strength in [0.0, 0.5, 1.0, 2.0] {
            state.lutStrength = strength
            let rendered = state.renderedRecipe(cameraTemperature: 6000, cameraTint: 0)
            try check(rendered.blackPoint == min(100, 50 * strength) && rendered.whitePoint == max(-100, -60 * strength) &&
                      rendered.vibrance == 15 * strength && rendered.clarity == 12 * strength && rendered.dehaze == -6 * strength &&
                      rendered.gradingSettings.shadows.hue == 210 && rendered.gradingSettings.shadows.saturation == 8 * strength,
                      "V4 strength scales final new controls once, preserving hue")
            try check(rendered.curveSettings.isValid && (strength != 0 || rendered.curveSettings.isIdentity),
                      "V4 curve remains valid and bypasses exactly at zero")
            try check(state.blackPoint == 50 && state.curveSettings.points.count == 5 && state.temperature == 8000 && state.sharpening == 0.75,
                      "Rendering preserves stored controls and unrelated adjustments")
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy.removeValue(forKey: "masterRecipeSettingsVersion")
        let old = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        let oldRendered = old.renderedRecipe(cameraTemperature: 6000, cameraTint: 0)
        try check(oldRendered.blackPoint == 50 && oldRendered.gradingSettings.shadows.saturation == 8 &&
                  oldRendered.curveSettings == old.curveSettings && oldRendered.hsl == old.hsl.scaled(by: 2),
                  "Missing version retains old independent controls and scaled HSL")
        legacy["masterRecipeSettingsVersion"] = 5
        try rejects("Unknown recipe versions cannot silently change old photos") {
            _ = try JSONDecoder().decode(RawSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
    }

    static func unavailable(_ directory: URL) throws {
        let store = try EditPersistence(directory: directory), identity = PhotoIdentity(resourceIdentifier: "loaded")
        var settings = RawSettings.default; settings.exposure = 0.4
        try store.save(identity, state: .init(settings: settings))
        let receipt = try store.versionedState(for: identity)
        let backup = directory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data([1]).write(to: directory)
        try check(store.state(for: identity)?.settings == settings, "Legacy read retains the last accepted record during storage failure")
        try rejects("Strict transaction read never falls back to cached records") { _ = try store.versionedState(for: identity) }
        try rejects("Unavailable store cannot commit using the cache") { _ = try store.compareAndSave(expected: receipt, state: nil) }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        try check(try store.versionedState(for: identity) == receipt, "Restored storage reads the original receipt")
    }

    static func legacy(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = PhotoIdentity(contentIdentifier: "stable-hash")
        var settings = RawSettings.default; settings.lutID = "PROVIA"
        let state = PhotoEditState(settings: settings).replacing(settings: settings, preservingFilmID: nil)
        let file = directory.appendingPathComponent("edits.json")
        let bytes = try JSONEncoder().encode(["records": [identity.key: state]])
        try bytes.write(to: file)
        let store = try EditPersistence(directory: directory), before = try store.versionedState(for: identity)
        try check(before.state == state && before.revision == nil && Data(contentsOf: file) == bytes,
            "Legacy records read without rewriting or inventing a revision")
        settings.exposure = 1
        let next = try store.compareAndSave(expected: before, state: state.replacing(settings: settings, preservingFilmID: nil))
        try check(next.state?.filmID == nil && next.revision != nil, "Legacy CAS preserves explicit nil look metadata")
    }

    static func corrupt(_ directory: URL) throws {
        let store = try EditPersistence(directory: directory), identity = PhotoIdentity(resourceIdentifier: "future")
        let before = try store.versionedState(for: identity), file = directory.appendingPathComponent("edits.json")
        let future = Data("{\"version\":99,\"records\":{}}".utf8)
        try future.write(to: file)
        try rejects("Future registry version blocks CAS") { _ = try store.compareAndSave(expected: before, state: .init(settings: .default)) }
        try check(try Data(contentsOf: file) == future, "Future registry bytes are preserved")
        try Data("broken".utf8).write(to: file)
        try rejects("Corrupt registry blocks existing writers") { try store.save(identity, state: .init(settings: .default)) }
    }

    static func concurrent(_ directory: URL) throws {
        let stores = try [EditPersistence(directory: directory), EditPersistence(directory: directory)]
        let group = DispatchGroup(), errorLock = NSLock()
        var errors: [Error] = []
        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    for item in 0..<8 {
                        try stores[index].save(.init(resourceIdentifier: "\(index)-\(item)"), state: .init(settings: .default))
                    }
                } catch { errorLock.lock(); errors.append(error); errorLock.unlock() }
            }
        }
        try check(group.wait(timeout: .now() + 10) == .success && errors.isEmpty, "Concurrent native store writers finish")
        let reader = try EditPersistence(directory: directory)
        try check((0..<2).allSatisfy { index in (0..<8).allSatisfy { reader.state(for: .init(resourceIdentifier: "\(index)-\($0)")) != nil } },
            "Concurrent writers retain every photo record")
    }
}
