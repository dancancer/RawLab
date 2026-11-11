import Foundation
import CryptoKit

@main struct CameraOriginalStoreTests {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw CameraProtocolError.invalid(message) }
        print("PASS: \(message)")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-camera-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = CameraDeviceIdentity(manufacturer: "Sony", model: "Other Sony", firmware: "9.99", serial: "fixture", operations: [0x923c, 0x923d])
        let bytes = Data([0xff, 0xd8, 0xff, 1, 2, 3, 4])
        let snapshot = CameraAssetSnapshot(content: 1, file: 1, storage: 0, format: 0, name: "DSC00001.JPG",
            size: UInt64(bytes.count), created: "1700000000000", modified: "")
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
        let job = try store!.enqueue(device: identity, connectionKey: "fixture", assets: [snapshot])
        let item = job.items[0]
        let destination = try store!.begin(job: job.id, item: item.id)
        try destination.handle.write(contentsOf: bytes); try destination.handle.close()
        let saved = try store!.complete(job: job.id, item: item.id, digest: digest)
        try check(try Data(contentsOf: store!.verifiedURL(saved.id)) == bytes, "Only complete validated originals become editable")
        let duplicate = try store!.enqueue(device: identity, connectionKey: "fixture", assets: [snapshot])
        let second = try store!.begin(job: duplicate.id, item: duplicate.items[0].id)
        try second.handle.write(contentsOf: bytes); try second.handle.close()
        let reused = try store!.complete(job: duplicate.id, item: duplicate.items[0].id, digest: digest)
        try check(reused.id == saved.id && store!.snapshot.originals.count == 1, "Content dedup retains the original source identity")
        var prepared = store!.snapshot
        prepared.jobs[0].items[0].phase = .prepared
        prepared.originals[0].availability = .prepared
        store = nil
        try JSONEncoder().encode(prepared).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        store = try CameraOriginalStore(directory: root)
        try check(store!.snapshot.jobs[0].items[0].phase == .saved && store!.snapshot.originals[0].id == saved.id,
                  "A crash after publishing reclaims the same original without downloading again")
        let owner = UUID(), asset = CameraRemoteAsset(owner: UUID(), snapshot: snapshot)
        try store!.beginTether(device: identity, connectionKey: "fixture", baseline: [asset])
        try store!.markShutterRequested(owner: owner)
        try store!.acknowledgeShutter(owner: owner)
        try store!.finishConfirmedShutter(owner: UUID())
        try check(store!.snapshot.tether?.shutterRequestedAt != nil, "A reconnected owner cannot complete or replay an old shutter request")
        let extra = CameraRemoteAsset(owner: UUID(), snapshot: CameraAssetSnapshot(content: 2, file: 1, storage: 0, format: 0,
            name: "DSC00002.JPG", size: 7, created: "1700000000001", modified: ""))
        try store!.validateTetherResume(device: identity, connectionKey: "fixture", assets: [asset, extra])
        try store!.rebaseResumedTether([asset, extra])
        try check(store!.snapshot.tether!.baseline.contains(extra.snapshot.key), "Offline unregistered files become a new baseline, never automatic new-shot imports")
        do { try store!.validateTetherResume(device: identity, connectionKey: "fixture", assets: [asset]); throw CameraProtocolError.invalid("Expected changed baseline rejection") }
        catch CameraProtocolError.invalid(let message) where message == "Expected changed baseline rejection" { throw CameraProtocolError.invalid(message) }
        catch CameraProtocolError.tetherRecoveryRequired { print("PASS: A changed card requires manual import instead of automatic recovery") }
        try store!.beginTether(device: identity, connectionKey: "fixture", baseline: [])
        let jobsBeforeResume = store!.snapshot.jobs.count
        for currentCard in [[], [extra]] {
            do {
                try store!.validateTetherResume(device: identity, connectionKey: "fixture", assets: currentCard)
                throw CameraProtocolError.invalid("An empty baseline must not resume automatically")
            } catch CameraProtocolError.tetherRecoveryRequired {
                try check(store!.snapshot.jobs.count == jobsBeforeResume && store!.snapshot.tether!.baseline.isEmpty,
                          "An unverifiable empty baseline requests manual import without enqueuing offline photos")
            }
        }
        let pending = try store!.enqueue(device: identity, connectionKey: "fixture", assets: [snapshot])
        let interrupted = try store!.begin(job: pending.id, item: pending.items[0].id)
        try interrupted.handle.write(contentsOf: bytes.prefix(3)); try interrupted.handle.close()
        store = nil
        store = try CameraOriginalStore(directory: root)
        try check(!FileManager.default.fileExists(atPath: interrupted.url.path), "Recovery removes only incomplete partial files")
        let restored = store!.snapshot.jobs.first { $0.id == pending.id }!
        try check(restored.items[0].phase == .interrupted, "Unfinished work remains explicitly resumable")
        let matching = try restored.pendingAssets(device: identity, connectionKey: "SSID:camera",
            assets: [asset], allowAlternateConnection: true)
        try check(matching.count == 1 && matching[0].1 == asset, "Import resumes across connections with matching serial and file")
        let otherCamera = CameraDeviceIdentity(manufacturer: identity.manufacturer, model: identity.model,
            firmware: identity.firmware, serial: "different", operations: identity.operations)
        let missingSerial = CameraDeviceIdentity(manufacturer: identity.manufacturer, model: identity.model,
            firmware: identity.firmware, serial: "", operations: identity.operations)
        let historical = try store!.enqueue(device: missingSerial, connectionKey: "fixture", assets: [snapshot])
        let reusedHandle = CameraRemoteAsset(owner: asset.owner, snapshot: CameraAssetSnapshot(content: snapshot.content,
            file: snapshot.file, storage: snapshot.storage, format: snapshot.format, name: snapshot.name,
            size: snapshot.size, created: snapshot.created, modified: "changed"))
        for (job, camera, card, allowAlternate) in [
            (restored, otherCamera, [asset], true), (restored, identity, [], true),
            (restored, identity, [reusedHandle], true), (restored, identity, [asset, asset], true),
            (historical, missingSerial, [asset], true), (restored, identity, [asset], false)
        ] {
            var rejected = false
            do {
                _ = try job.pendingAssets(device: camera, connectionKey: "SSID:camera",
                    assets: card, allowAlternateConnection: allowAlternate)
            } catch CameraProtocolError.invalid { rejected = true }
            try check(rejected, "Resume rejects unverifiable camera, changed or ambiguous file, and alternate tether connection")
        }
        try check(try historical.pendingAssets(device: missingSerial, connectionKey: "fixture",
            assets: [asset], allowAlternateConnection: true).count == 1, "Serial-less historical import can use its original connection")
        try Data([0xff, 0xd8, 0xff, 9, 9, 9, 9]).write(to: store!.originalURL(saved))
        do { _ = try store!.verifiedURL(saved.id); throw CameraProtocolError.invalid("Changed source must be rejected") }
        catch CameraProtocolError.invalid(let message) where message == "Changed source must be rejected" { throw CameraProtocolError.invalid(message) }
        catch { print("PASS: Modified saved original is not handed to the editor") }
        try check(store!.snapshot.originals[0].availability == .changed, "Source changes retain the record and editing identity")
    }
}
