import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

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
        try check(!store!.snapshot.canResumeTether, "A recorded camera without registered originals has no resume action")
        try store!.markShutterRequested(owner: owner)
        try store!.acknowledgeShutter(owner: owner)
        try store!.finishConfirmedShutter(owner: UUID())
        try check(store!.snapshot.tether?.shutterRequestedAt != nil, "A reconnected owner cannot complete or replay an old shutter request")
        let extra = CameraRemoteAsset(owner: UUID(), snapshot: CameraAssetSnapshot(content: 2, file: 1, storage: 0, format: 0,
            name: "DSC00002.JPG", size: 7, created: "1700000000001", modified: ""))
        let remoteOnly = CameraDeviceIdentity(manufacturer: identity.manufacturer, model: identity.model,
            firmware: identity.firmware, serial: identity.serial, operations: [])
        func rejectUnprovenTether(_ device: CameraDeviceIdentity, _ card: [CameraRemoteAsset], _ message: String) throws {
            do {
                try store!.resumeTether(device: device, connectionKey: "fixture", assets: card, verifySaved: { _ in
                    throw CameraProtocolError.invalid("Unproven tether must not download anything")
                }, receivePending: { _, _ in
                    throw CameraProtocolError.invalid("Unproven tether must not receive anything")
                })
                try check(false, message)
            } catch CameraProtocolError.tetherRecoveryRequired { print("PASS: \(message)") }
        }
        try rejectUnprovenTether(remoteOnly, [asset], "A remote-only camera cannot resume a card transfer")
        try rejectUnprovenTether(identity, [asset], "Unregistered baseline files do not prove that the card stayed the same")
        try store!.beginTether(device: identity, connectionKey: "fixture", baseline: [])
        try check(!store!.snapshot.canResumeTether, "An empty tether record has no resume action")
        let jobsBeforeResume = store!.snapshot.jobs.count
        for currentCard in [[], [extra]] {
            try rejectUnprovenTether(identity, currentCard, "An empty baseline without registered originals requires manual import")
            try check(store!.snapshot.jobs.count == jobsBeforeResume && store!.snapshot.tether!.baseline.isEmpty,
                      "Rejected recovery does not enqueue offline photos")
        }
        let pending = try store!.enqueue(device: identity, connectionKey: "fixture", assets: [snapshot], listingOwner: asset.owner)
        let interrupted = try store!.begin(job: pending.id, item: pending.items[0].id)
        try interrupted.handle.write(contentsOf: bytes.prefix(3)); try interrupted.handle.close()
        store = nil
        store = try CameraOriginalStore(directory: root)
        try check(!FileManager.default.fileExists(atPath: interrupted.url.path), "Recovery removes only incomplete partial files")
        let restored = store!.snapshot.jobs.first { $0.id == pending.id }!
        let matching = try restored.pendingAssets(device: identity, connectionKey: "fixture",
            assets: [asset], allowAlternateConnection: true)
        try check(restored.items[0].phase == .interrupted && matching.first?.1 == asset, "An unfinished download can retry in its original listing session")
        let unverifiedReplacement = CameraRemoteAsset(owner: UUID(), snapshot: snapshot)
        do {
            _ = try restored.pendingAssets(device: identity, connectionKey: "SSID:camera",
                assets: [unverifiedReplacement], allowAlternateConnection: true)
            try check(false, "A new connection cannot prove original identity from metadata alone")
        } catch CameraProtocolError.importRecoveryRequired {
            print("PASS: A new connection cannot prove original identity from metadata alone")
        }
        let otherCamera = CameraDeviceIdentity(manufacturer: identity.manufacturer, model: identity.model,
            firmware: identity.firmware, serial: "different", operations: identity.operations)
        let missingSerial = CameraDeviceIdentity(manufacturer: identity.manufacturer, model: identity.model,
            firmware: identity.firmware, serial: "", operations: identity.operations)
        let historical = try store!.enqueue(device: missingSerial, connectionKey: "fixture", assets: [snapshot])
        try check(historical.matches(camera: missingSerial, connectionKey: "fixture") &&
                  historical.bindToListing([asset]).isEmpty, "A historical import without source proof still needs a new selection")
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
            } catch CameraProtocolError.importRecoveryRequired { rejected = true }
            catch CameraProtocolError.tetherRecoveryRequired { rejected = true }
            try check(rejected, "Resume rejects unverifiable camera, changed or ambiguous file, and alternate tether connection")
        }
        try Data([0xff, 0xd8, 0xff, 9, 9, 9, 9]).write(to: store!.originalURL(saved))
        do { _ = try store!.verifiedURL(saved.id); throw CameraProtocolError.invalid("Changed source must be rejected") }
        catch CameraProtocolError.invalid(let message) where message == "Changed source must be rejected" { throw CameraProtocolError.invalid(message) }
        catch { print("PASS: Modified saved original is not handed to the editor") }
        try check(store!.snapshot.originals[0].availability == .changed, "Source changes retain the record and editing identity")
        try resumeManualWithSourceDigest(identity: identity, asset: asset, bytes: bytes)
        try tetherRecoveryChecksSavedOriginals(identity: identity, original: asset, bytes: bytes)
        try manualOriginalsCleanup()
        try incrementalRecovery()
        try switchingFormatsFindsBothUnimportedJPEGs()
        try adjustedJPEG()
        if #available(macOS 15.0, iOS 18.0, *) { try isoGainMapJPEG() }
    }

    private static func tetherRecoveryChecksSavedOriginals(identity: CameraDeviceIdentity, original: CameraRemoteAsset, bytes: Data) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-camera-tether-proof-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
        let connection = "SSID:fixture"
        try store!.beginTether(device: identity, connectionKey: connection, baseline: [])
        let job = try store!.registerTetherAssets([original.snapshot], listingOwner: original.owner)
        try check(!store!.snapshot.canResumeTether, "A registered item without source bytes cannot resume")
        let saved = try write(bytes, item: job.items[0], job: job, store: store!)
        try check(store!.snapshot.canResumeTether, "A verified registered original still offers tether recovery")
        var legacy = store!.snapshot
        legacy.jobs[0].items[0].sourceDigest = nil
        try check(legacy.canResumeTether, "A saved tether original can use its legacy original digest")
        var broken = store!.snapshot
        broken.jobs = []
        try check(!broken.canResumeTether, "A dangling tether job reference cannot resume")
        let owner = UUID()
        let extra = CameraRemoteAsset(owner: owner, snapshot: .init(content: 2, file: 1, storage: 0, format: 0,
            name: "DSC00002.JPG", size: UInt64(bytes.count), created: "1700000000001", modified: ""))
        let current = CameraRemoteAsset(owner: owner, snapshot: original.snapshot)
        var changed = bytes
        changed[changed.count - 1] ^= 1
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func noPending(_ id: UUID, _ bindings: [CameraTransferJob.BoundItem]) throws {
            try check(false, "Already completed originals must not be published again")
        }
        do {
            try store!.resumeTether(device: identity, connectionKey: connection, assets: [current, extra],
                verifySaved: { _ in throw CameraProtocolError.response(0x923d, 0x2009) }, receivePending: noPending)
            try check(false, "An unavailable camera object must require manual import")
        } catch CameraProtocolError.tetherRecoveryRequired {
            try check(store!.snapshot.tether?.baseline == [original.snapshot.key] &&
                store!.snapshot.originals.map(\.id) == [saved.id],
                "A missing camera object routes to manual import without changing the saved original or baseline")
        }
        do {
            try store!.resumeTether(device: identity, connectionKey: connection, assets: [current],
                verifySaved: { _ in throw CameraProtocolError.response(0x923d, 0x2019) }, receivePending: noPending)
            try check(false, "A busy camera must still return its response")
        } catch CameraProtocolError.response(0x923d, 0x2019) {
            print("PASS: A busy camera is not classified as a missing original")
        }
        var checked: [CameraRemoteAsset] = []
        do {
            try store!.resumeTether(device: identity, connectionKey: connection, assets: [current, extra],
                verifySaved: { checked.append($0.asset); return digest(changed) }, receivePending: noPending)
            try check(false, "A completed original on a different card must block tether rebasing")
        } catch CameraProtocolError.tetherRecoveryRequired {
            try check(checked == [current] && store!.snapshot.tether?.baseline == [original.snapshot.key] &&
                store!.snapshot.originals.map(\.id) == [saved.id],
                "Mismatched completed bytes block rebasing and leave the extra file and saved original alone")
        }
        func remap(_ handle: UInt32, owner: UUID) -> CameraRemoteAsset {
            let asset = original.snapshot
            return CameraRemoteAsset(owner: owner, snapshot: .init(content: handle, file: asset.file, storage: asset.storage,
                format: asset.format, name: asset.name, size: asset.size, created: asset.created, modified: asset.modified))
        }
        let rebound = remap(42, owner: owner)
        try store!.resumeTether(device: identity, connectionKey: connection, assets: [rebound],
            verifySaved: { bound in try check(bound.asset == rebound, "Digest verification follows the reassigned handle"); return digest(bytes) },
            receivePending: noPending)
        try check(store!.snapshot.tether?.baseline == [rebound.snapshot.key], "A verified original may rebind to the new listing")

        store = nil
        store = try CameraOriginalStore(directory: root)
        let latest = remap(43, owner: owner)
        try store!.resumeTether(device: identity, connectionKey: connection, assets: [latest, extra],
            verifySaved: { bound in try check(bound.asset == latest, "A subsequent reconnect still checks the completed source"); return digest(bytes) },
            receivePending: noPending)
        try check(store!.snapshot.tether?.baseline == [latest.snapshot.key, extra.snapshot.key] &&
            store!.snapshot.jobs.map(\.id) == [job.id] && store!.snapshot.originals.map(\.id) == [saved.id],
            "Only a verified resume may use the offline listing as its baseline without importing extra files")
        try check(!store!.snapshot.canResumeTether, "An offline file without verified bytes prevents another automatic recovery")
        do {
            try store!.resumeTether(device: identity, connectionKey: connection, assets: [latest, extra],
                verifySaved: { _ in throw CameraProtocolError.invalid("Unknown baseline should fail before download") },
                receivePending: noPending)
            try check(false, "An untracked photo cannot act as verified evidence on the next reconnect")
        } catch CameraProtocolError.tetherRecoveryRequired {
            print("PASS: An untracked photo cannot act as verified evidence on the next reconnect")
        }
    }

    private static func resumeManualWithSourceDigest(identity: CameraDeviceIdentity, asset: CameraRemoteAsset, bytes: Data) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-camera-source-digest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
        let job = try store!.enqueue(device: identity, connectionKey: "BLE:camera", assets: [asset.snapshot], listingOwner: asset.owner)
        let item = job.items[0], saved = try write(bytes, item: item, job: job, store: store!)
        var prepared = store!.snapshot
        prepared.jobs[0].items[0].phase = .prepared
        prepared.originals[0].availability = .prepared
        try FileManager.default.removeItem(at: store!.originalURL(saved))
        store = nil
        try JSONEncoder().encode(prepared).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        store = try CameraOriginalStore(directory: root)
        let restored = store!.snapshot.jobs[0]
        let snapshot = asset.snapshot
        let rebound = CameraRemoteAsset(owner: UUID(), snapshot: CameraAssetSnapshot(content: 93, file: 5,
            storage: snapshot.storage, format: snapshot.format, name: snapshot.name, size: snapshot.size,
            created: snapshot.created, modified: snapshot.modified))
        let candidates = try restored.pendingAssets(device: identity, connectionKey: "SSID:camera", assets: [rebound],
                                                     allowAlternateConnection: true)
        try check(candidates.count == 1 && candidates[0].0.id == item.id && candidates[0].1 == rebound,
                  "A manual import can use a reassigned handle when a source checksum was recorded")
        try check(restored.bindToListing([rebound, CameraRemoteAsset(owner: rebound.owner, snapshot: snapshot)]).isEmpty,
                  "Two metadata matches cannot identify a unique current handle")
        var different = bytes
        different[different.count - 1] ^= 1
        do {
            _ = try write(different, item: item, job: restored, store: store!)
            try check(false, "A replacement with the same metadata cannot complete the old job")
        } catch CameraProtocolError.importRecoveryRequired {
            try check(store!.snapshot.originals.isEmpty && store!.snapshot.jobs[0].items[0].sourceDigest == saved.digest,
                      "A replacement with the same metadata cannot complete the old job")
            try store!.interrupt(job: job.id, item: item.id, error: nil, cancelled: false)
        }
        let recovered = try write(bytes, item: item, job: restored, store: store!)
        try check(recovered.digest == saved.digest && store!.snapshot.jobs[0].complete,
                  "Reassigned handle with verified bytes completes the original job")
    }

    // Q6：相机原件不自动删，手动清理只删「已导出且不再被引用」的任务与原件。
    private static func manualOriginalsCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "Fixture", firmware: "1.00", serial: "prune", operations: [])
        let jpegA = Data([0xff, 0xd8, 0xff, 1, 2, 3, 4]), jpegB = Data([0xff, 0xd8, 0xff, 5, 6, 7, 8])
        let tiff = Data([0x49, 0x49, 0x2a, 0, 1, 2, 3]), tiff2 = Data([0x49, 0x49, 0x2a, 0, 9, 8, 7])
        func snapshot(_ file: UInt32, _ ext: String) -> CameraAssetSnapshot {
            CameraAssetSnapshot(content: file, file: file, storage: 0, format: 0, name: "DSC000\(file).\(ext)",
                size: 7, created: "1700000000000", modified: "")
        }
        var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
        func saved(_ job: CameraTransferJob, _ payload: Data) throws -> CameraStoredOriginal {
            try write(payload, item: job.items[0], job: job, store: store!)
        }
        let jobOld = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(11, "JPG")])
        let oldOriginal = try saved(jobOld, jpegA)
        let jobNew = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(12, "JPG")])
        let recentOriginal = try saved(jobNew, jpegB)
        var pruned = try store!.pruneExportedOriginals()
        try check(pruned.originals == 1 && pruned.freedBytes == UInt64(jpegA.count),
                  "Manual cleanup deletes one fully saved job's original and reports the freed bytes")
        try check(store!.snapshot.jobs.map(\.id) == [jobNew.id] && store!.snapshot.originals.map(\.id) == [recentOriginal.id],
                  "The newest job and its original anchor stay")
        try check(!FileManager.default.fileExists(atPath: store!.originalURL(oldOriginal).path),
                  "The pruned original file leaves persistent storage")
        pruned = try store!.pruneExportedOriginals()
        try check(pruned.originals == 0 && store!.snapshot.jobs.count == 1, "Repeated cleanup is idempotent and never deletes the newest job")
        let jobShared = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(13, "JPG")])
        let sharedOriginal = try saved(jobShared, jpegB)
        try check(sharedOriginal.id == recentOriginal.id, "The re-imported original reuses the saved source identity")
        pruned = try store!.pruneExportedOriginals()
        try check(pruned.originals == 0 && store!.snapshot.jobs.map(\.id) == [jobShared.id] &&
                      FileManager.default.fileExists(atPath: store!.originalURL(recentOriginal).path),
                  "An original shared with the newest job survives cleanup of its earlier job")
        let tethered = CameraRemoteAsset(owner: UUID(), snapshot: snapshot(14, "JPG"))
        try store!.beginTether(device: device, connectionKey: "prune", baseline: [tethered])
        let jobTether = try store!.registerTetherAssets([tethered.snapshot], listingOwner: UUID())
        let tetherOriginal = try saved(jobTether, jpegA)
        let jobLatest = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(15, "JPG")])
        _ = try saved(jobLatest, jpegB)
        pruned = try store!.pruneExportedOriginals()
        try check(store!.snapshot.jobs.map(\.id) == [jobTether.id, jobLatest.id] &&
                      FileManager.default.fileExists(atPath: store!.originalURL(tetherOriginal).path),
                  "A tether-referenced saved job is never removed by manual cleanup")
        let owner = UUID()
        let plan1 = CameraIncrementalPlan(format: .rawAndJPEG, jpeg: CameraJPEGOptions(), boundary: nil, owner: owner, boundaries: [:])
        let plan2 = CameraIncrementalPlan(format: .rawAndJPEG, jpeg: CameraJPEGOptions(), boundary: nil, owner: owner, boundaries: [:])
        let jobInc1 = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(16, "ARW")], incremental: plan1)
        let inc1Original = try saved(jobInc1, tiff)
        let jobPlain = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(17, "JPG")])
        _ = try saved(jobPlain, jpegB)
        pruned = try store!.pruneExportedOriginals()
        try check(pruned.originals == 0 && store!.snapshot.jobs.contains { $0.id == jobInc1.id },
                  "The incremental owner's newest complete job is retained even when it is not the latest job")
        let jobInc2 = try store!.enqueue(device: device, connectionKey: "prune", assets: [snapshot(18, "ARW")], incremental: plan2)
        _ = try saved(jobInc2, tiff2)
        pruned = try store!.pruneExportedOriginals()
        try check(pruned.originals == 2 && !store!.snapshot.jobs.contains { $0.id == jobInc1.id }
                      && store!.snapshot.jobs.contains { $0.id == jobInc2.id }
                      && !FileManager.default.fileExists(atPath: store!.originalURL(inc1Original).path)
                      && FileManager.default.fileExists(atPath: store!.originalURL(tetherOriginal).path),
                  "A superseded incremental job is cleaned once a newer complete job anchors its owner")
        try check(store!.snapshot.savedIncrementalKeys(owner: owner, jpeg: CameraJPEGOptions()).contains(jobInc2.items[0].asset.key),
                  "Dedup keys survive through the retained newest incremental job")
    }

    private static func incrementalRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-incremental-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "Fixture", firmware: "1.00", serial: "camera", operations: [])
        let owner = UUID(), cutoff = Date(timeIntervalSince1970: 1_699_999_999)
        let raw = Data([0x49, 0x49, 0x2a, 0, 1, 2, 3])
        let jpeg = Data([0xff, 0xd8, 0xff, 1, 2, 3, 4])
        func asset(_ id: UInt32, _ ext: String, time: String = "1700000000000", session: UUID? = nil) -> CameraRemoteAsset {
            CameraRemoteAsset(owner: session ?? owner, snapshot: CameraAssetSnapshot(content: id, file: 0, storage: 0, format: 0,
                name: "DSC\(id).\(ext)", size: 7, created: time, modified: ""))
        }
        let first = asset(1, "ARW"), second = asset(2, "JPG")
        let older = asset(3, "JPG", time: "1699999998000"), undated = asset(4, "ARW", time: "0")
        let all = [first, second, older, undated]
        let scan = CameraIncrementalScan(assets: all, boundaries: [:], cutoff: cutoff, customCutoff: nil,
                                         format: .rawAndJPEG, includeUndated: false)
        try check(Set(scan.assets.map(\.id)) == [first.id, second.id] && scan.undatedCount == 1,
                  "Incremental planning selects RAW and JPEG by camera time and counts undated files separately")
        let rawOnly = CameraIncrementalScan(assets: all, boundaries: [:], cutoff: cutoff, customCutoff: nil,
                                            format: .raw, includeUndated: true)
        try check(Set(rawOnly.assets.map(\.id)) == [first.id, undated.id], "RAW format and explicit undated inclusion build the queue")
        let legacy = CameraAssetSnapshot(content: 42, file: 0, storage: 0x10001, format: 0x3801, name: "DSC00042.JPG",
                                         size: 7, created: "20231114T221320", modified: "")
        let malformed = CameraAssetSnapshot(content: 43, file: 0, storage: 0x10001, format: 0x3801, name: "DSC00043.JPG",
                                            size: 7, created: "20260231T000000", modified: "")
        try check(legacy.captureDate == Date(timeIntervalSince1970: 1_700_000_000) && malformed.captureDate == nil,
                  "Legacy camera wall time is parsed consistently and invalid dates stay unknown")

        var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
        let plan = CameraIncrementalPlan(format: .rawAndJPEG, jpeg: CameraJPEGOptions(), boundary: nil,
                                         owner: owner, boundaries: scan.nextBoundaries)
        let job = try store!.enqueue(device: device, connectionKey: "fixture", assets: scan.assets.map(\.snapshot), incremental: plan)
        let rawItem = job.items.first { $0.asset == first.snapshot }!
        let jpgItem = job.items.first { $0.asset == second.snapshot }!
        let saved = try write(raw, item: rawItem, job: job, store: store!)
        let partial = try store!.begin(job: job.id, item: jpgItem.id)
        try partial.handle.write(contentsOf: jpeg.prefix(3)); try partial.handle.close()
        store = nil
        store = try CameraOriginalStore(directory: root)
        try check(store!.snapshot.incrementalBoundaries(device: device, connectionKey: "fixture").isEmpty,
                  "Interrupted incremental jobs cannot advance the checkpoint")
        let resumed = store!.snapshot.jobs[0]
        try check(resumed.pendingItems.map(\.id) == [jpgItem.id] && resumed.items.first { $0.id == rawItem.id }?.sourceID == saved.id,
                  "Reconnect only queues the unfinished JPEG and retains the saved RAW")
        let newOwner = UUID()
        func rebound(_ locator: UInt32, slot: UInt32 = 0) -> CameraRemoteAsset {
            CameraRemoteAsset(owner: newOwner, snapshot: CameraAssetSnapshot(content: locator, file: 5, storage: slot,
                format: second.snapshot.format, name: second.snapshot.name, size: second.snapshot.size,
                created: second.snapshot.created, modified: second.snapshot.modified))
        }
        let newJPEG = rebound(92)
        try check(resumed.bindToListing([newJPEG])[jpgItem.id] == nil && resumed.bindToListing(all)[jpgItem.id] == second,
                  "The original card slot does not prove the identity of an unfinished JPEG")
        let savedJPEG = try write(jpeg, item: resumed.pendingItems[0], job: resumed, store: store!)
        let boundaries = store!.snapshot.incrementalBoundaries(device: device, connectionKey: "fixture")
        try check(boundaries.count == 2 && boundaries.values.allSatisfy { $0.date == Date(timeIntervalSince1970: 1_700_000_000) }
                  && store!.snapshot.originals.count == 2, "Saving the last item commits the two format checkpoints")
        let repeated = CameraIncrementalScan(assets: all, boundaries: boundaries, cutoff: cutoff, customCutoff: nil,
                                             format: .rawAndJPEG, includeUndated: false)
        try check(repeated.assets.isEmpty, "Scanning the same session again has no new files")
        let sameSecond = asset(5, "ARW")
        let continued = CameraIncrementalScan(assets: all + [sameSecond], boundaries: boundaries, cutoff: cutoff, customCutoff: nil,
                                              format: .rawAndJPEG, includeUndated: false)
        try check(continued.assets.map(\.id) == [sameSecond.id], "An unseen file at the last capture time remains eligible")
        let backfill = CameraIncrementalScan(assets: all, boundaries: boundaries, cutoff: cutoff,
                                             customCutoff: Date(timeIntervalSince1970: 1_699_999_990),
                                             format: .jpeg, includeUndated: false)
        try check(backfill.nextBoundaries.isEmpty && Set(backfill.assets.map(\.id)) == [older.id, second.id],
                  "Explicit backfill includes the earlier JPEG without replacing the normal checkpoint")
        let changed = CameraIncrementalScan(assets: [sameSecond], boundaries: boundaries, cutoff: cutoff, customCutoff: nil,
                                            format: .raw, includeUndated: false)
        try check(changed.needsCutoffConfirmation && changed.assets.isEmpty, "An unverified card requires a new cutoff")
        let nextOwner = UUID()
        let reconnected = [asset(1, "ARW", session: nextOwner), asset(2, "JPG", session: nextOwner)]
        let savedKeys = store!.snapshot.savedIncrementalKeys(owner: nextOwner, jpeg: plan.jpeg)
        let unconfirmed = CameraIncrementalScan(assets: reconnected, boundaries: boundaries, cutoff: cutoff, customCutoff: nil,
                                                format: .jpeg, includeUndated: false, savedKeys: savedKeys)
        try check(unconfirmed.needsCutoffConfirmation && unconfirmed.assets.isEmpty && unconfirmed.nextBoundaries.isEmpty,
                  "Matching metadata on another listing cannot authorize the previous cutoff")
        let checkAgain = CameraIncrementalScan(assets: reconnected, boundaries: boundaries, cutoff: cutoff, customCutoff: cutoff,
                                              format: .jpeg, includeUndated: false)
        try check(checkAgain.assets.map(\.snapshot) == [second.snapshot],
                  "A matching JPEG from a new listing still needs its bytes checked")
        let recheck = try store!.enqueue(device: device, connectionKey: "fixture", assets: checkAgain.assets.map(\.snapshot),
            incremental: CameraIncrementalPlan(format: .jpeg, jpeg: CameraJPEGOptions(), boundary: nil,
                                               owner: nextOwner, boundaries: checkAgain.nextBoundaries))
        let reuse = try write(jpeg, item: recheck.items[0], job: recheck, store: store!)
        try check(store!.snapshot.originals.count == 2 && reuse.id == savedJPEG.id && store!.snapshot.jobs.last?.items[0].reused == true,
                  "Rechecking an uncertain boundary reuses the published file")
        let otherOwner = UUID()
        let replacement = asset(2, "JPG", session: otherOwner)
        let olderReplacement = asset(3, "JPG", time: "1699999998000", session: otherOwner)
        let newCard = [replacement, olderReplacement]
        let previous = store!.snapshot.incrementalBoundaries(device: device, connectionKey: "fixture")
        let needsCutoff = CameraIncrementalScan(assets: newCard, boundaries: previous, cutoff: cutoff,
            customCutoff: nil, format: .jpeg, includeUndated: false)
        try check(needsCutoff.needsCutoffConfirmation && needsCutoff.assets.isEmpty,
                  "A new card with a matching boundary pauses before omitting earlier photos")
        let rescan = CameraIncrementalScan(assets: newCard, boundaries: previous, cutoff: cutoff,
            customCutoff: olderReplacement.snapshot.captureDate, format: .jpeg, includeUndated: false)
        try check(rescan.assets == [olderReplacement, replacement], "Confirming an earlier cutoff includes both photos on the new card")
        let replacementJob = try store!.enqueue(device: device, connectionKey: "fixture", assets: rescan.assets.map(\.snapshot),
            incremental: CameraIncrementalPlan(format: .jpeg, jpeg: plan.jpeg, boundary: nil, owner: otherOwner, boundaries: rescan.nextBoundaries))
        let replacementBytes = Data([0xff, 0xd8, 0xff, 4, 3, 2, 1])
        _ = try write(jpeg, item: replacementJob.items[0], job: replacementJob, store: store!)
        let newOriginal = try write(replacementBytes, item: replacementJob.items[1], job: replacementJob, store: store!)
        try check(newOriginal.id != reuse.id && Data(contentsOf: store!.verifiedURL(newOriginal.id)) == replacementBytes,
                  "A same-metadata JPEG with different bytes is saved as a distinct original")
        let after = store!.snapshot.incrementalBoundaries(device: device, connectionKey: "fixture")
        let sameListing = CameraIncrementalScan(assets: newCard, boundaries: after, cutoff: cutoff, customCutoff: nil,
            format: .jpeg, includeUndated: false)
        try check(after["JPEG"]?.owner == otherOwner && !sameListing.needsCutoffConfirmation && sameListing.assets.isEmpty,
                  "The confirmed scan commits a checkpoint for the current listing")
    }

    private static func switchingFormatsFindsBothUnimportedJPEGs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-camera-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "Fixture", firmware: "1.00", serial: "camera", operations: [])
        let store = try CameraOriginalStore(directory: root)
        let owner = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_699_999_999)
        let rawBytes = Data([0x49, 0x49, 0x2a, 0, 1, 2, 3])
        let raw = CameraAssetSnapshot(content: 1, file: 1, storage: 0, format: 0, name: "DSC001.ARW",
                                      size: 7, created: "1700000000000", modified: "")
        let pairedJPEG = CameraAssetSnapshot(content: 1, file: 2, storage: 0, format: 0, name: "DSC001.JPG",
                                             size: 7, created: "1700000000000", modified: "")
        let laterJPEG = CameraAssetSnapshot(content: 2, file: 1, storage: 0, format: 0, name: "DSC002.JPG",
                                            size: 7, created: "1700003600000", modified: "")
        let assets = [raw, pairedJPEG, laterJPEG].map { CameraRemoteAsset(owner: owner, snapshot: $0) }
        let rawScan = CameraIncrementalScan(assets: assets, boundaries: [:], cutoff: cutoff, customCutoff: nil,
                                            format: .raw, includeUndated: false)
        try check(rawScan.nextBoundaries.count == 1 && rawScan.nextBoundaries["RAW"]?.date == raw.captureDate,
                  "The scan advances only the kind and date of selected files")
        let legacy = CameraImportBoundary(date: laterJPEG.captureDate!, storage: [0], keys: [laterJPEG.key],
                                          anchors: [laterJPEG.anchorKey], owner: owner)
        let job = try store.enqueue(device: device, connectionKey: "fixture", assets: rawScan.assets.map(\.snapshot),
            incremental: CameraIncrementalPlan(format: .raw, jpeg: CameraJPEGOptions(), boundary: legacy, owner: owner))
        _ = try write(rawBytes, item: job.items[0], job: job, store: store)
        let migrated = store.snapshot.incrementalBoundaries(device: device, connectionKey: "fixture")
        try check(migrated["RAW"]?.date == raw.captureDate && migrated["JPEG"] == nil,
                  "Legacy manifests rebuild the checkpoint from published items")
        let jpegScan = CameraIncrementalScan(assets: assets, boundaries: migrated, cutoff: cutoff,
                                            customCutoff: nil, format: .jpeg, includeUndated: false)
        try check(jpegScan.assets.map(\.snapshot) == [pairedJPEG, laterJPEG],
                  "A completed RAW import leaves both unimported JPEGs eligible")
        let combined = CameraIncrementalScan(assets: assets, boundaries: migrated, cutoff: cutoff,
                                            customCutoff: nil, format: .rawAndJPEG, includeUndated: false)
        try check(combined.assets.map(\.snapshot) == [pairedJPEG, laterJPEG],
                  "A combined scan applies the checkpoint of each format")
    }

    private static func adjustedJPEG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-adjusted-jpeg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "Fixture", firmware: "1.00", serial: "camera", operations: [])
        let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let source = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(source, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:11 10:00:00"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CameraProtocolError.invalid("JPEG fixture could not be written") }
        let bytes = source as Data
        let photo = CameraAssetSnapshot(content: 1, file: 0, storage: 0, format: 0, name: "DSC001.JPG",
                                        size: UInt64(bytes.count), created: "1700000000000", modified: "")
        let plan = CameraIncrementalPlan(format: .jpeg, jpeg: CameraJPEGOptions(adjust: true, longEdge: 40, quality: 72), boundary: nil)
        let first = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo], incremental: plan)
        let saved = try write(bytes, item: first.items[0], job: first, store: store)
        let url = try store.verifiedURL(saved.id)
        let output = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        try check(props?[kCGImagePropertyPixelWidth] as? Int == 20 && props?[kCGImagePropertyPixelHeight] as? Int == 40
                  && (props?[kCGImagePropertyOrientation] as? Int ?? 1) == 1
                  && exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:11 10:00:00",
                  "Adjusted JPEG respects the long edge, orientation and original capture date")
        let retry = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo], incremental: plan)
        let reused = try write(bytes, item: retry.items[0], job: retry, store: store)
        let plain = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo])
        let original = try write(bytes, item: plain.items[0], job: plain, store: store)
        try check(reused.id == saved.id && original.id != saved.id && store.snapshot.originals.count == 2,
                  "Repeated JPEG settings reuse the derivative while original JPEG remains distinct")
        try check(try Data(contentsOf: store.verifiedURL(original.id)) == bytes, "Original JPEG remains byte-for-byte intact")
        let lowerQuality = CameraIncrementalPlan(format: .jpeg, jpeg: CameraJPEGOptions(adjust: true, longEdge: 40, quality: 18), boundary: nil)
        let low = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo], incremental: lowerQuality)
        let compressed = try write(bytes, item: low.items[0], job: low, store: store)
        try check(compressed.digest != saved.digest && compressed.id != saved.id, "Changing quality changes the encoded JPEG at the same size")
        let noUpscale = CameraIncrementalPlan(format: .jpeg, jpeg: CameraJPEGOptions(adjust: true, longEdge: 2048, quality: 90), boundary: nil)
        let largerLimit = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo], incremental: noUpscale)
        let kept = try write(bytes, item: largerLimit.items[0], job: largerLimit, store: store)
        let keptSource = try CGImageSourceCreateWithURL(store.verifiedURL(kept.id) as CFURL, nil)!
        let keptImage = CGImageSourceCreateImageAtIndex(keptSource, 0, nil)
        try check(keptImage?.width == 40 && keptImage?.height == 80, "A long-edge ceiling never enlarges the camera JPEG")
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func isoGainMapJPEG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-iso-camera-jpeg-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CameraOriginalStore(directory: root)
        let device = CameraDeviceIdentity(manufacturer: "Sony", model: "Fixture", firmware: "1.00", serial: "camera", operations: [])
        let bytes: Data
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_ISO_JPEG"] {
            bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            bytes = try makeISOGainMapFixture()
        }
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
        try check(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil &&
                  CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil,
                  "Fixture has an ISO gain map without an Apple HDR gain map")
        let photo = CameraAssetSnapshot(content: 1, file: 0, storage: 0, format: 0, name: "DSCISO.JPG",
            size: UInt64(bytes.count), created: "1700000000000", modified: "")
        let plan = CameraIncrementalPlan(format: .jpeg, jpeg: CameraJPEGOptions(adjust: true, longEdge: 32), boundary: nil)
        let adjusted = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo], incremental: plan)
        do {
            _ = try write(bytes, item: adjusted.items[0], job: adjusted, store: store)
            try check(false, "JPEG adjustment must preserve the ISO gain map by declining re-encoding")
        } catch CameraProtocolError.jpegGainMapAdjustment {
            try check(store.snapshot.originals.isEmpty && !store.snapshot.jobs[0].complete,
                      "JPEG adjustment must preserve the ISO gain map by declining re-encoding")
        }
        let original = try store.enqueue(device: device, connectionKey: "fixture", assets: [photo])
        let saved = try write(bytes, item: original.items[0], job: original, store: store)
        try check(try Data(contentsOf: store.verifiedURL(saved.id)) == bytes, "Saving the ISO JPEG as original preserves every byte")
        if let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_GAIN_MAP_OUTPUT"] {
            try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    private static func makeISOGainMapFixture() throws -> Data {
        let edge = 64
        let pixels = (0..<(edge * edge * 4)).map { $0 % 4 == 3 ? 1 : Float($0 % 64) / 16 }
        let provider = pixels.withUnsafeBytes { CGDataProvider(data: Data($0) as CFData)! }
        let flags = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union([.floatComponents, .byteOrder32Little])
        let hdr = CGImage(width: edge, height: edge, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: edge * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: flags, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let input = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(input, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, CGImageCreateCopyWithContentHeadroom(4, hdr)!, [
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap
        ] as CFDictionary)
        try check(CGImageDestinationFinalize(encoder), "Encode the ISO-only JPEG fixture")
        return input as Data
    }

    private static func write(_ bytes: Data, item: CameraTransferItem, job: CameraTransferJob, store: CameraOriginalStore) throws -> CameraStoredOriginal {
        let target = try store.begin(job: job.id, item: item.id)
        try target.handle.write(contentsOf: bytes)
        try target.handle.close()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try store.complete(job: job.id, item: item.id, digest: digest)
    }
}
