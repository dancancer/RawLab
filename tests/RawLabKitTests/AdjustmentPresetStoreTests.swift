import Foundation
import XCTest
@testable import RawLabKit

final class AdjustmentPresetStoreTests: XCTestCase {
    private func payload(_ exposure: Double = 1.25) throws -> AdjustmentTransferPayload {
        try .init(
            source: .init(identifier: "/deleted/original.ARW", isRaw: true, processingVersion: 2, recipe: nil),
            values: ["light.exposure": .number(exposure), "color.hsl.hue.red": .number(37.25)]
        )
    }

    private func sameJSON(_ lhs: String, _ rhs: Data) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: Data(lhs.utf8)),
              let right = try? JSONSerialization.jsonObject(with: rhs) else { return false }
        return (left as AnyObject).isEqual(right as AnyObject)
    }

    func testCreateRenameOverwriteDeleteAndConcurrency() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory, clock: { 1000 })
        let file = directory.appendingPathComponent("presets.json")

        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try store.create(name: " \n\t", payload: payload()))

        let original = try store.create(name: "  日光  ", payload: payload())
        XCTAssertEqual(original.name, "日光")
        XCTAssertEqual(original.createdAt, 1000)
        XCTAssertEqual(original.updatedAt, 1000)
        XCTAssertNotNil(UUID(uuidString: original.id))
        XCTAssertEqual(original.payload.source.identifier, "preset:\(original.id)")
        XCTAssertEqual(original.payload.values, (try payload()).values)
        XCTAssertEqual(try AdjustmentPresetStore(directory: directory).list(), [original])

        do {
            _ = try store.create(name: "日光", payload: payload(2))
            XCTFail("Duplicate should require a decision")
        } catch AdjustmentPresetError.duplicateName(let existing) {
            XCTAssertEqual(existing, original)
        }

        let beforeDuplicate = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.create(name: "日光", payload: payload(2)))
        XCTAssertEqual(try Data(contentsOf: file), beforeDuplicate)

        let renamed = try store.rename(original, name: "午后")
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.createdAt, original.createdAt)
        XCTAssertEqual(renamed.payload, original.payload)
        XCTAssertGreaterThan(renamed.updatedAt, original.updatedAt)

        XCTAssertThrowsError(try store.overwrite(original, payload: payload(2)))
        XCTAssertThrowsError(try store.delete(original))

        let replaced = try store.overwrite(renamed, payload: payload(2))
        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.name, "午后")
        XCTAssertEqual(replaced.createdAt, original.createdAt)
        XCTAssertEqual(replaced.payload[.exposure], .number(2))
        XCTAssertEqual(replaced.payload.source.identifier, "preset:\(original.id)")

        let second = try store.create(name: "另一项", payload: payload(3))
        try store.delete(replaced)

        let retiredCollision = AdjustmentPresetStore(directory: directory, makeID: { original.id })
        XCTAssertThrowsError(try retiredCollision.create(name: "曾用 ID", payload: payload()))

        let third = try store.create(name: "第三项", payload: payload(4))
        XCTAssertEqual(Set([original.id, second.id, third.id]).count, 3)
        XCTAssertTrue(try store.list().contains(second))

        let accent = try store.create(name: "Cafe\u{301}", payload: payload())
        XCTAssertTrue(accent.name.utf8.elementsEqual("Café".utf8))
        XCTAssertTrue(AdjustmentPreset.normalizedName("\u{200B}\u{85}Cafe\u{301}\u{A0}").utf8.elementsEqual("Café".utf8))
        XCTAssertThrowsError(try store.create(name: "Café", payload: payload()))
        XCTAssertThrowsError(try store.rename(second, name: "Café"))

        let stableBytes = try Data(contentsOf: file)
        XCTAssertEqual(try store.rename(second, name: " 另一项 "), second)
        XCTAssertEqual(try Data(contentsOf: file), stableBytes)

        let collisionStore = AdjustmentPresetStore(directory: directory, makeID: { second.id })
        XCTAssertThrowsError(try collisionStore.create(name: "碰撞", payload: payload()))
        XCTAssertEqual(try Data(contentsOf: file), stableBytes)

        let unavailable = AdjustmentPresetStore(directory: directory, writeData: { _, _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertThrowsError(try unavailable.overwrite(second, payload: payload(7)))
        XCTAssertEqual(try Data(contentsOf: file), stableBytes)
        XCTAssertThrowsError(try unavailable.delete(second))
        XCTAssertTrue(try store.list().contains(second))

        let group = DispatchGroup(), lock = NSLock()
        var successes: [AdjustmentPreset] = []
        var failures: [Error] = []
        for index in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let item = try AdjustmentPresetStore(directory: directory).create(
                        name: "Concurrent \(index)",
                        payload: self.payload(Double(index))
                    )
                    lock.lock(); successes.append(item); lock.unlock()
                } catch {
                    lock.lock(); failures.append(error); lock.unlock()
                }
            }
        }
        group.wait()
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(successes.count, 4)
        let savedIDs = Set(try store.list().map(\.id))
        XCTAssertTrue(successes.allSatisfy { savedIDs.contains($0.id) })

        let external = AdjustmentPresetStore(directory: directory)
        let externalRename = try external.rename(second, name: "Changed externally")
        XCTAssertThrowsError(try store.rename(second, name: "Lost update"))
        XCTAssertTrue(try store.list().contains(externalRename))
    }

    func testSharedPresetFixturesAndMalformedRegistry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetFixtureTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory, clock: { 1000 })
        let file = directory.appendingPathComponent("presets.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixtureFile = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/fixtures/adjustment-presets-v1.json")
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureFile)) as? [[String: Any]])
        let registryFailures: Set<String> = [
            "future-registry", "unknown-registry-field", "duplicate-id", "duplicate-name",
            "invalid-retired-id", "overlapping-retired-id", "duplicate-retired-id", "registry-decimal", "registry-exponent",
            "registry-rounded-fraction", "registry-boolean", "registry-string", "registry-null", "json-unquoted-metadata-key",
            "json-single-quoted-key", "json-trailing-document", "json-trailing-comma", "json-comment",
            "duplicate-root-key", "duplicate-escaped-root-key"
        ]

        for fixture in fixtures {
            let bytes: Data
            if let raw = fixture["registry_json"] as? String {
                bytes = Data(raw.utf8)
            } else {
                bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["registry"]), options: [.sortedKeys])
            }
            try bytes.write(to: file, options: .atomic)
            let id = try XCTUnwrap(fixture["id"] as? String)
            if (fixture["valid"] as? Bool) == true {
                let restored = try store.list()
                XCTAssertEqual(restored.count, 1, "Shared accepted preset fixture: \(id)")
                XCTAssertEqual(restored[0].payload[.exposure], .number(1.25), "Shared accepted preset fixture: \(id)")
            } else if !registryFailures.contains(id) {
                let root = (fixture["registry"] as? [String: Any])
                    ?? ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]) ?? [:]
                let presets = try XCTUnwrap(root["presets"] as? [Any])
                let entryData = try JSONSerialization.data(withJSONObject: presets[0], options: [.sortedKeys])
                XCTAssertTrue(try store.list().isEmpty, "Bad entry leaves an empty readable list: \(id)")
                let unreadable = try store.listUnreadable()
                XCTAssertEqual(unreadable.count, 1, "Bad entry is isolated as unreadable: \(id)")
                XCTAssertTrue(sameJSON(unreadable[0].json, entryData), "Bad entry is isolated as unreadable: \(id)")
                _ = try store.create(name: "Writable", payload: payload())
                XCTAssertEqual(try store.list().count, 1)
                XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(unreadable[0].json))
            } else {
                XCTAssertThrowsError(try store.list(), "Shared rejected preset fixture: \(id)")
                XCTAssertThrowsError(try store.create(name: "New", payload: payload()), "Invalid library blocks mutations: \(id)")
                XCTAssertEqual(try Data(contentsOf: file), bytes, "Invalid library is preserved byte-for-byte: \(id)")
            }
        }

        let broken = Data("{broken".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.create(name: "New", payload: payload()))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testUnreadableEntryIsolationAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetUnreadable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory, clock: { 1000 })
        let goodA = try store.create(name: "Alpha", payload: payload())
        let goodB = try store.create(name: "Beta", payload: payload(2))
        let file = directory.appendingPathComponent("presets.json")
        let futureID = "2f8f1e0a-0b0c-4d5e-8f90-112233445566"
        let raw = "{ \"id\": \"\(futureID)\", \"name\": \"Future\", \"created_at\": 1, \"updated_at\": 1,\n  \"payload\": { \"payload_version\": 9 }, \"future_field\": \"caf\\u00e9\" }"
        try String(decoding: Data(contentsOf: file), as: UTF8.self)
            .replacingOccurrences(of: "\"presets\":[", with: "\"presets\":[" + raw + ",")
            .write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(try store.list().map(\.name), ["Alpha", "Beta"])
        let unreadable = try store.listUnreadable()
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable[0].id, futureID)
        XCTAssertEqual(unreadable[0].name, "Future")
        XCTAssertEqual(unreadable[0].json, raw)

        _ = try store.create(name: "Created", payload: payload(3))
        _ = try store.rename(goodA, name: "Renamed")
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(raw))
        XCTAssertEqual(try store.list().count, 3)

        XCTAssertThrowsError(try store.create(name: "Future", payload: payload()))
        XCTAssertThrowsError(try AdjustmentPresetStore(directory: directory, makeID: { futureID }).create(name: "Collision", payload: payload()))

        try store.delete(goodB)
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(raw))

        try store.delete(unreadable[0])
        XCTAssertTrue(try store.listUnreadable().isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(raw))
        XCTAssertThrowsError(try store.delete(unreadable[0]))
    }

    func testUnreadableIdentityOverlapsAndRetiredDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetOverlaps-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AdjustmentPresetStore(directory: directory, clock: { 1000 })
        let valid = try store.create(name: "Valid", payload: payload())
        let file = directory.appendingPathComponent("presets.json")
        let twin = "{ \"id\": \"\(valid.id)\", \"name\": \"Twin\", \"created_at\": 1, \"updated_at\": 1, \"payload\": { \"payload_version\": 9 }, \"future_field\": \"keep\" }"
        let alpha = "{ \"id\": \"0\", \"name\": \"Alpha\", \"created_at\": 1, \"updated_at\": 1, \"payload\": { \"payload_version\": 9 } }"
        let beta = "{ \"id\": \"0\", \"name\": \"Beta\", \"created_at\": 1, \"updated_at\": 1, \"payload\": { \"payload_version\": 9 } }"
        try String(decoding: Data(contentsOf: file), as: UTF8.self)
            .replacingOccurrences(of: "\"presets\":[", with: "\"presets\":[" + twin + "," + alpha + "," + beta + ",")
            .write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.list().first?.id, valid.id)
        XCTAssertEqual(try store.listUnreadable().count, 3)

        let twinEntry = try XCTUnwrap(try store.listUnreadable().first { $0.json == twin })
        try store.delete(twinEntry)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.listUnreadable().map(\.json), [alpha, beta])

        let afterTwin = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(afterTwin["retired_ids"] as? [String], [])

        let betaEntry = try XCTUnwrap(try store.listUnreadable().first { $0.json == beta })
        try store.delete(betaEntry)
        let afterBeta = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertEqual(try store.listUnreadable().map(\.json), [alpha])
        XCTAssertTrue(afterBeta.contains(alpha))
        XCTAssertFalse(afterBeta.contains(beta))
        XCTAssertThrowsError(try store.delete(betaEntry))

        let retiredDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLabPresetRetiredGhost-\(UUID())")
        defer { try? FileManager.default.removeItem(at: retiredDirectory) }
        try FileManager.default.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
        let retiredStore = AdjustmentPresetStore(directory: retiredDirectory, clock: { 1000 })
        let retiredFile = retiredDirectory.appendingPathComponent("presets.json")
        let id = "2f8f1e0a-0b0c-4d5e-8f90-112233445566"
        let raw = "{ \"id\": \"\(id)\", \"name\": \"Ghost\", \"created_at\": 1, \"updated_at\": 1, \"payload\": { \"payload_version\": 9 }, \"future_field\": \"keep\" }"
        try "{\"registry_version\":1,\"presets\":[\(raw)],\"retired_ids\":[\"\(id)\"]}"
            .write(to: retiredFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(try retiredStore.list().isEmpty)
        XCTAssertEqual(try retiredStore.listUnreadable().count, 1)
        let entry = try XCTUnwrap(try retiredStore.listUnreadable().first)
        try retiredStore.delete(entry)
        let written = String(decoding: try Data(contentsOf: retiredFile), as: UTF8.self)
        XCTAssertFalse(written.contains(raw))
        XCTAssertEqual(written.components(separatedBy: id).count, 2)
        XCTAssertTrue(try retiredStore.list().isEmpty)
        XCTAssertTrue(try retiredStore.listUnreadable().isEmpty)
    }
}
