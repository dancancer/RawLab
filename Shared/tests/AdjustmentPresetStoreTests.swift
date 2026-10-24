import Foundation

@main struct AdjustmentPresetStoreTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1; print("PASS: \(message)")
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection: \(message)") }
        catch { check(true, message) }
    }
    static func payload(_ exposure: Double = 1.25) throws -> AdjustmentTransferPayload {
        try .init(source: .init(identifier: "/deleted/original.ARW", isRaw: true, processingVersion: 2, recipe: nil),
                  values: ["light.exposure": .number(exposure), "color.hsl.hue.red": .number(37.25)])
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory, clock: { 1000 })
        let file = directory.appendingPathComponent("presets.json")
        check(try store.list().isEmpty, "Missing preset library is empty without creating a registry")
        check(!FileManager.default.fileExists(atPath: file.path), "Listing is read-only")
        rejects("Whitespace names do not create a preset") { _ = try store.create(name: " \n\t", payload: payload()) }
        let original = try store.create(name: "  日光  ", payload: payload())
        check(original.name == "日光" && original.createdAt == 1000 && original.updatedAt == 1000, "Create trims the name and records independent timestamps")
        check(UUID(uuidString: original.id) != nil && original.payload.source.identifier == "preset:\(original.id)", "Preset identity is independent of its source photo")
        check(original.payload.values == (try payload()).values, "Preset preserves exact selected logical values")
        check(try AdjustmentPresetStore(directory: directory).list() == [original], "A new store instance restores the persisted preset")
        do {
            _ = try store.create(name: "日光", payload: payload(2))
            fatalError("Duplicate should require a decision")
        } catch AdjustmentPresetError.duplicateName(let existing) {
            check(existing == original, "Duplicate name reports the exact existing preset for confirmation")
        }
        let beforeDuplicate = try Data(contentsOf: file)
        rejects("Failed duplicate does not replace content") { _ = try store.create(name: "日光", payload: payload(2)) }
        check(try Data(contentsOf: file) == beforeDuplicate, "Rejected create preserves registry bytes")
        let renamed = try store.rename(original, name: "午后")
        check(renamed.id == original.id && renamed.createdAt == original.createdAt && renamed.payload == original.payload, "Rename preserves ID, creation time and payload")
        check(renamed.updatedAt > original.updatedAt, "Modified receipt advances even when the clock has not advanced")
        rejects("Stale overwrite confirmation cannot replace a renamed preset") { _ = try store.overwrite(original, payload: payload(2)) }
        rejects("Stale delete confirmation cannot delete a renamed preset") { try store.delete(original) }
        let replaced = try store.overwrite(renamed, payload: payload(2))
        check(replaced.id == original.id && replaced.name == "午后" && replaced.createdAt == original.createdAt, "Overwrite preserves the existing preset identity and name")
        check(replaced.payload[.exposure] == .number(2) && replaced.payload.source.identifier == "preset:\(original.id)", "Overwrite stores frozen logical content under the same preset identity")
        let second = try store.create(name: "另一项", payload: payload(3))
        try store.delete(replaced)
        let retiredCollision = AdjustmentPresetStore(directory: directory, makeID: { original.id })
        rejects("Deleted preset identities cannot be generated again for a different preset") {
            _ = try retiredCollision.create(name: "曾用 ID", payload: payload())
        }
        let third = try store.create(name: "第三项", payload: payload(4))
        check(Set([original.id, second.id, third.id]).count == 3, "Deleting one preset and creating another never reuses a live identity")
        check(try store.list().contains(second), "Deleting another preset preserves the exact surviving entry")
        let accent = try store.create(name: "Cafe\u{301}", payload: payload())
        check(accent.name.utf8.elementsEqual("Café".utf8), "Names are stored as canonical NFC bytes")
        check(AdjustmentPreset.normalizedName("\u{200B}\u{85}Cafe\u{301}\u{A0}").utf8.elementsEqual("Café".utf8),
              "Name trimming uses the shared Unicode whitespace set before normalization")
        rejects("Canonically equivalent name is a duplicate") { _ = try store.create(name: "Café", payload: payload()) }
        rejects("Rename cannot collide with another preset name") { _ = try store.rename(second, name: "Café") }
        let stableBytes = try Data(contentsOf: file)
        check(try store.rename(second, name: " 另一项 ") == second, "Unchanged rename keeps the original receipt")
        check(try Data(contentsOf: file) == stableBytes, "Unchanged rename does not rewrite the file")

        let collisionStore = AdjustmentPresetStore(directory: directory, makeID: { second.id })
        rejects("Exhausted UUID collisions cannot overwrite an existing preset") { _ = try collisionStore.create(name: "碰撞", payload: payload()) }
        check(try Data(contentsOf: file) == stableBytes, "ID collision preserves the entire library")
        let unavailable = AdjustmentPresetStore(directory: directory, writeData: { _, _ in throw CocoaError(.fileWriteUnknown) })
        rejects("Atomic write failure is surfaced") { _ = try unavailable.overwrite(second, payload: payload(7)) }
        check(try Data(contentsOf: file) == stableBytes, "Failed overwrite preserves the original registry")
        rejects("Failed delete is surfaced") { try unavailable.delete(second) }
        check(try store.list().contains(second), "Failed delete leaves the preset usable")

        let group = DispatchGroup(), lock = NSLock()
        var successes: [AdjustmentPreset] = [], failures: [Error] = []
        for index in 0..<4 {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let item = try AdjustmentPresetStore(directory: directory).create(name: "Concurrent \(index)", payload: payload(Double(index)))
                    lock.lock(); successes.append(item); lock.unlock()
                } catch { lock.lock(); failures.append(error); lock.unlock() }
            }
        }
        group.wait()
        check(failures.isEmpty && successes.count == 4, "Independent concurrent stores create successfully")
        let savedIDs = Set(try store.list().map(\.id))
        check(successes.allSatisfy { savedIDs.contains($0.id) }, "Locked fresh reads preserve every concurrent create")
        let external = AdjustmentPresetStore(directory: directory)
        let externalRename = try external.rename(second, name: "Changed externally")
        rejects("Another instance invalidates the old edit confirmation") { _ = try store.rename(second, name: "Lost update") }
        check(try store.list().contains(externalRename), "Rejected stale operation preserves the other instance's change")

        let fixtureFile = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureFile)) as! [[String: Any]]
        for fixture in fixtures {
            let bytes: Data
            if let raw = fixture["registry_json"] as? String { bytes = Data(raw.utf8) }
            else { bytes = try JSONSerialization.data(withJSONObject: fixture["registry"]!, options: [.sortedKeys]) }
            try bytes.write(to: file, options: .atomic)
            if fixture["valid"] as! Bool {
                let restored = try store.list()
                check(restored.count == 1 && restored[0].payload[.exposure] == .number(1.25), "Shared accepted preset fixture: \(fixture["id"]!)")
            } else {
                rejects("Shared rejected preset fixture: \(fixture["id"]!)") { _ = try store.list() }
                rejects("Invalid library blocks all mutations: \(fixture["id"]!)") { _ = try store.create(name: "New", payload: payload()) }
                check(try Data(contentsOf: file) == bytes, "Invalid library is preserved byte-for-byte: \(fixture["id"]!)")
            }
        }
        let broken = Data("{broken".utf8); try broken.write(to: file)
        rejects("Malformed JSON blocks reading") { _ = try store.list() }
        rejects("Malformed JSON cannot be overwritten by a new preset") { _ = try store.create(name: "New", payload: payload()) }
        check(try Data(contentsOf: file) == broken, "Malformed registry remains available for recovery")
        print("PASS \(checks) adjustment preset store checks")
    }
}
