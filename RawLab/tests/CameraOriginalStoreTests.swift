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
        try check(store!.snapshot.jobs.first { $0.id == pending.id }!.items[0].phase == .interrupted, "Unfinished work remains explicitly resumable")
        try Data([0xff, 0xd8, 0xff, 9, 9, 9, 9]).write(to: store!.originalURL(saved))
        do { _ = try store!.verifiedURL(saved.id); throw CameraProtocolError.invalid("Changed source must be rejected") }
        catch CameraProtocolError.invalid(let message) where message == "Changed source must be rejected" { throw CameraProtocolError.invalid(message) }
        catch { print("PASS: Modified saved original is not handed to the editor") }
        try check(store!.snapshot.originals[0].availability == .changed, "Source changes retain the record and editing identity")
        try incrementalRecovery()
        try adjustedJPEG()
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
        let scan = CameraIncrementalScan(assets: all, boundary: nil, cutoff: cutoff, customCutoff: nil,
                                         format: .rawAndJPEG, includeUndated: false)
        try check(Set(scan.assets.map(\.id)) == [first.id, second.id] && scan.undatedCount == 1,
                  "Incremental planning selects RAW and JPEG by camera time and counts undated files separately")
        let rawOnly = CameraIncrementalScan(assets: all, boundary: nil, cutoff: cutoff, customCutoff: nil,
                                            format: .raw, includeUndated: true)
        try check(Set(rawOnly.assets.map(\.id)) == [first.id, undated.id], "RAW format and explicit undated inclusion build the queue")
        let legacy = CameraAssetSnapshot(content: 42, file: 0, storage: 0x10001, format: 0x3801, name: "DSC00042.JPG",
                                         size: 7, created: "20231114T221320", modified: "")
        let malformed = CameraAssetSnapshot(content: 43, file: 0, storage: 0x10001, format: 0x3801, name: "DSC00043.JPG",
                                            size: 7, created: "20260231T000000", modified: "")
        try check(legacy.captureDate == Date(timeIntervalSince1970: 1_700_000_000) && malformed.captureDate == nil,
                  "Legacy camera wall time is parsed consistently and invalid dates stay unknown")

        var store: CameraOriginalStore? = try CameraOriginalStore(directory: root)
        let plan = CameraIncrementalPlan(format: .rawAndJPEG, jpeg: CameraJPEGOptions(), boundary: scan.nextBoundary)
        let job = try store!.enqueue(device: device, connectionKey: "fixture", assets: scan.assets.map(\.snapshot), incremental: plan)
        let rawItem = job.items.first { $0.asset == first.snapshot }!
        let jpgItem = job.items.first { $0.asset == second.snapshot }!
        let saved = try write(raw, item: rawItem, job: job, store: store!)
        let partial = try store!.begin(job: job.id, item: jpgItem.id)
        try partial.handle.write(contentsOf: jpeg.prefix(3)); try partial.handle.close()
        store = nil
        store = try CameraOriginalStore(directory: root)
        try check(store!.snapshot.incrementalBoundary(device: device, connectionKey: "fixture") == nil,
                  "Interrupted incremental jobs cannot advance the checkpoint")
        let resumed = store!.snapshot.jobs[0]
        try check(resumed.pendingItems.map(\.id) == [jpgItem.id] && resumed.items.first { $0.id == rawItem.id }?.sourceID == saved.id,
                  "Reconnect only queues the unfinished JPEG and retains the saved RAW")
        let savedJPEG = try write(jpeg, item: resumed.pendingItems[0], job: resumed, store: store!)
        let boundary = store!.snapshot.incrementalBoundary(device: device, connectionKey: "fixture")
        try check(boundary?.date == Date(timeIntervalSince1970: 1_700_000_000) && store!.snapshot.originals.count == 2,
                  "Saving the last item commits the original batch checkpoint")
        let repeated = CameraIncrementalScan(assets: all, boundary: boundary, cutoff: cutoff, customCutoff: nil,
                                             format: .rawAndJPEG, includeUndated: false)
        try check(repeated.assets.isEmpty, "Scanning the same session again has no new files")
        let sameSecond = asset(5, "ARW")
        let continued = CameraIncrementalScan(assets: all + [sameSecond], boundary: boundary, cutoff: cutoff, customCutoff: nil,
                                              format: .rawAndJPEG, includeUndated: false)
        try check(continued.assets.map(\.id) == [sameSecond.id], "An unseen file at the last capture time remains eligible")
        let backfill = CameraIncrementalScan(assets: all, boundary: boundary, cutoff: cutoff,
                                             customCutoff: Date(timeIntervalSince1970: 1_699_999_990),
                                             format: .jpeg, includeUndated: false)
        try check(backfill.nextBoundary == nil && Set(backfill.assets.map(\.id)) == [older.id, second.id],
                  "Explicit backfill includes the earlier JPEG without replacing the normal checkpoint")
        let changed = CameraIncrementalScan(assets: [sameSecond], boundary: boundary, cutoff: cutoff, customCutoff: nil,
                                            format: .raw, includeUndated: false)
        try check(changed.needsCutoffConfirmation && changed.assets.isEmpty, "An unverified card requires a new cutoff")
        let nextOwner = UUID()
        let reconnected = [asset(1, "ARW", session: nextOwner), asset(2, "JPG", session: nextOwner)]
        let checkAgain = CameraIncrementalScan(assets: reconnected, boundary: boundary, cutoff: cutoff, customCutoff: nil,
                                              format: .jpeg, includeUndated: false)
        let recheck = try store!.enqueue(device: device, connectionKey: "fixture", assets: checkAgain.assets.map(\.snapshot),
            incremental: CameraIncrementalPlan(format: .jpeg, jpeg: CameraJPEGOptions(), boundary: checkAgain.nextBoundary))
        let reuse = try write(jpeg, item: recheck.items[0], job: recheck, store: store!)
        try check(store!.snapshot.originals.count == 2 && reuse.id == savedJPEG.id && store!.snapshot.jobs.last?.items[0].reused == true,
                  "Rechecking an uncertain boundary reuses the published file")
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

    private static func write(_ bytes: Data, item: CameraTransferItem, job: CameraTransferJob, store: CameraOriginalStore) throws -> CameraStoredOriginal {
        let target = try store.begin(job: job.id, item: item.id)
        try target.handle.write(contentsOf: bytes)
        try target.handle.close()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try store.complete(job: job.id, item: item.id, digest: digest)
    }
}
