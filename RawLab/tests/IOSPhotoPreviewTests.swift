import RawLabKit
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UIKit

enum HDRCameraProfileAssetStore {
    static var directory: URL = FileManager.default.temporaryDirectory
    static func url(for profile: HDRCameraProfile, in dir: URL = directory) throws -> URL {
        dir.appendingPathComponent("\(profile.sha256).dcp")
    }
}

extension HDRSettings {
    func previewSettings() -> HDRSettings { self }
}

enum HDRPresentation {
    static func makeSDRImage(_ image: HDRImage) throws -> CGImage { image.cgImage }
}

struct HDRImage {
    let cgImage: CGImage
}

struct Sony2FujiProcessor {
    struct Frame {
        let buffer: Buffer
        let orientation: UIImage.Orientation
    }
    struct Buffer {}
    struct RasterInput {
        let buffer: Buffer
    }
    func defaultSettings(for url: URL, isRaw: Bool) throws -> RawSettings { .default }
    func processHDR(url: URL, settings: HDRSettings, previewLongEdge: Int?, exportLongEdge: Int? = nil,
                    processing: ProcessingIdentity = .current, proRAWDecodeVersion: Int? = nil,
                    cancelled: () -> Bool = { false }) throws -> HDRImage {
        HDRImage(cgImage: try Self.solidCGImage())
    }
    func processRaw(url: URL, settings: RawSettings, previewLongEdge: CGFloat, lutURL: URL?, viewportPreview: Bool) throws -> Frame {
        Frame(buffer: Buffer(), orientation: .up)
    }
    func loadRasterBuffer(url: URL, previewLongEdge: Int) throws -> RasterInput { RasterInput(buffer: Buffer()) }
    func processBuffer(buffer: Buffer, settings: RawSettings, previewLongEdge: CGFloat, lutURL: URL?, viewportPreview: Bool) throws -> Buffer { Buffer() }
    func makeUIImage(from buffer: Buffer, orientation: UIImage.Orientation) -> UIImage? {
        guard let cg = try? Self.solidCGImage() else { return nil }
        return UIImage(cgImage: cg)
    }
    private static func solidCGImage() throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        var px: [UInt8] = [200, 120, 60, 255]
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

@main struct IOSPhotoPreviewTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await verifyHundredPhotoReloadAndPartialCorruption(in: root)
        try await verifyPreviewHashDeduplicationAndCurrency(in: root)
        try await verifyLegacyNormalX3fPreviewRepair(in: root)
    }

    private static func verifyHundredPhotoReloadAndPartialCorruption(in root: URL) async throws {
        let editsDir = root.appendingPathComponent("p2-04-edits")
        let recentsDir = root.appendingPathComponent("p2-04-recents")
        let cacheDir = root.appendingPathComponent("p2-04-cache")

        let editStore = try EditPersistence(directory: editsDir)
        let recentStore = try RecentPhotoStore(directory: recentsDir, maximumEntries: 100, maximumOriginalBytes: 256 * 1024 * 1024)
        var firstPhoto: RecentPhoto!
        var secondPhoto: RecentPhoto!
        for i in 0..<100 {
            let f = root.appendingPathComponent("p204-\(i).dng")
            try Data("photo-\(i)".utf8).write(to: f)
            let id = try PhotoIdentity.fallback(for: f, resourceIdentifier: "res-\(i)")
            let recent = try recentStore.recordOpened(url: f, identity: id, displayName: "p204-\(i).dng", isRaw: true, now: Date(timeIntervalSince1970: Double(i)))
            if i == 0 { firstPhoto = recent }
            if i == 1 { secondPhoto = recent }
            if i < 50 {
                var s = RawSettings.default
                s.exposure = 0.5
                try editStore.save(id, state: PhotoEditState(settings: s))
            }
        }

        let library = await MainActor.run { IOSPhotoPreviewLibrary(recentStore: recentStore, cacheDirectory: cacheDir) }
        let readsBefore = EditPersistence.registryDiskReadCount(forDirectory: editsDir)
        var updated = RawSettings.default
        updated.exposure = 1.5
        try editStore.save(firstPhoto.identity, state: PhotoEditState(settings: updated))
        await library.reload(editDirectory: editsDir)
        let readsDelta = EditPersistence.registryDiskReadCount(forDirectory: editsDir) - readsBefore
        try check(readsDelta <= 2, "P2-04 IOSPhotoPreviewLibrary save+reload of 100 photos performs \(readsDelta) <= 2 edits.json reads")
        let editedSnapshot = await MainActor.run { library.edited }
        let countSnapshot = await MainActor.run { library.photos.count }
        let errorSnapshot = await MainActor.run { library.error }
        try check(countSnapshot == 100 && errorSnapshot == nil, "P2-04 reload populated all 100 recent photos with nil error")
        try check(editedSnapshot[firstPhoto.id] == true, "P2-04 edited photo flagged true after commit+reload")

        // Corrupt a single photo's record inside edits.json without breaking JSON container.
        let editsFile = editsDir.appendingPathComponent("edits.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: editsFile)) as! [String: Any]
        var records = json["records"] as! [String: Any]
        let corruptKey = "photo-content:\(secondPhoto.identity.resourceIdentifier!.utf8.count):\(secondPhoto.identity.resourceIdentifier!):\(secondPhoto.identity.contentIdentifier!)"
        records[corruptKey] = ["broken": true]
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: editsFile)

        await library.reload(editDirectory: editsDir)
        let partialEdited = await MainActor.run { library.edited }
        let partialError = await MainActor.run { library.error }
        try check(partialError == nil, "P2-04 partial corrupt edits.json reload preserves healthy list without store error")
        try check(partialEdited[firstPhoto.id] == true, "P2-04 healthy entry retains edited status beside corrupt sibling")
        try check(partialEdited[secondPhoto.id] == nil, "P2-04 corrupt sibling entry is isolated without crashing or false flag")
    }

    private static func verifyPreviewHashDeduplicationAndCurrency(in root: URL) async throws {
        let editsDir = root.appendingPathComponent("p2-05-edits")
        let recentsDir = root.appendingPathComponent("p2-05-recents")
        let cacheDir = root.appendingPathComponent("p2-05-cache")
        let profileDir = root.appendingPathComponent("p2-05-profiles")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        HDRCameraProfileAssetStore.directory = profileDir

        let editStore = try EditPersistence(directory: editsDir)
        let recentStore = try RecentPhotoStore(directory: recentsDir, maximumEntries: 100, maximumOriginalBytes: 64 * 1024 * 1024)

        let rawFile = root.appendingPathComponent("hdr-sample.dng")
        try Data("raw-hdr-bytes".utf8).write(to: rawFile)
        let rawID = try PhotoIdentity.fallback(for: rawFile, resourceIdentifier: "hdr-asset")
        let recent = try recentStore.recordOpened(url: rawFile, identity: rawID, displayName: "hdr-sample.dng", isRaw: true)

        let lookData = Data("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n".utf8)
        let lookSHA = SHA256.hash(data: lookData).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: HDRLookSettings.directory, withIntermediateDirectories: true)
        let hdrLookURL = HDRLookSettings.directory.appendingPathComponent("\(lookSHA).cube")
        try lookData.write(to: hdrLookURL)
        defer { try? FileManager.default.removeItem(at: hdrLookURL) }

        let lutURL = root.appendingPathComponent("custom.cube")
        try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: lutURL)

        let profileData = Data("dcp-profile".utf8)
        let profileSHA = SHA256.hash(data: profileData).map { String(format: "%02x", $0) }.joined()
        let profileURL = profileDir.appendingPathComponent("\(profileSHA).dcp")
        try profileData.write(to: profileURL)

        var hdr = HDRSettings()
        hdr.mode = .hdr
        hdr.lookSettings = HDRLookSettings(sha256: lookSHA, name: "FilmHDR", strength: 1)
        hdr.cameraDevelopmentSettings.cameraProfile = HDRCameraProfile(sha256: profileSHA, name: "Sony")
        var hdrRaw = RawSettings.default
        hdrRaw.exposure = 0.75
        hdrRaw.hdr = hdr
        let hdrRecord = PhotoEditRecord(identity: rawID, state: PhotoEditState(settings: hdrRaw))
        try editStore.save(rawID, state: hdrRecord.state!)

        let digestCache = FileDigestCache(maximumEntries: 32)
        let library = await MainActor.run {
            IOSPhotoPreviewLibrary(recentStore: recentStore, cacheDirectory: cacheDir, digestCache: digestCache)
        }

        let retainedSource = try recentStore.sourceURL(for: recent)
        let previewSource = IOSPhotoPreviewSource(identity: rawID, file: .externallyManaged(retainedSource), displayName: recent.displayName, isRaw: true)

        // Cold render with 4 distinct uncached files: each file must be hashed at most once (total = 4).
        let hBeforeCold = digestCache.digestComputeCount
        let rBeforeCold = EditPersistence.registryDiskReadCount(forDirectory: editsDir)
        let coldImage = try await library.image(previewSource, record: hdrRecord, look: lutURL, editDirectory: editsDir)
        let coldHashes = digestCache.digestComputeCount - hBeforeCold
        let coldReads = EditPersistence.registryDiskReadCount(forDirectory: editsDir) - rBeforeCold
        try check(coldHashes == 4 &&
                  digestCache.digestComputeCount(for: retainedSource) == 1 &&
                  digestCache.digestComputeCount(for: lutURL) == 1 &&
                  digestCache.digestComputeCount(for: hdrLookURL) == 1 &&
                  digestCache.digestComputeCount(for: profileURL) == 1,
                  "P2-05 cold HDR+LUT+profile thumbnail hashes each file once (total \(coldHashes) == 4)")
        try check(coldReads <= 1, "P2-05 cold thumbnail render reads edits.json <= 1 time (actual \(coldReads))")

        // Warm render must perform 0 hashes and 0 reads.
        let hBeforeWarm = digestCache.digestComputeCount
        let rBeforeWarm = EditPersistence.registryDiskReadCount(forDirectory: editsDir)
        _ = try await library.image(previewSource, record: hdrRecord, look: lutURL, editDirectory: editsDir)
        try check(digestCache.digestComputeCount - hBeforeWarm == 0, "P2-05 warm thumbnail render performs 0 hashes")
        try check(EditPersistence.registryDiskReadCount(forDirectory: editsDir) - rBeforeWarm == 0, "P2-05 warm thumbnail render performs 0 edits.json reads")

        // Full tile load cycle (record + sourceURL + image) must perform 0 redundant hashes on warm cache (at most 1 initial source hash on shared cache).
        FileDigestCache.shared.invalidateAll()
        let sharedBeforeInitialTile = FileDigestCache.shared.digestComputeCount(for: retainedSource)
        let sharedWarmRec = try await library.record(for: rawID, isX3f: recent.isX3f, editDirectory: editsDir)
        let sharedWarmSrc = try await library.source(for: recent)
        try check(FileDigestCache.shared.digestComputeCount(for: retainedSource) == sharedBeforeInitialTile + 1, "P2-05 initial tile sourceURL hashes retained photo once")
        let sharedBeforeSecondTile = FileDigestCache.shared.digestComputeCount
        _ = try await library.record(for: rawID, isX3f: recent.isX3f, editDirectory: editsDir)
        _ = try await library.source(for: recent)
        _ = try await library.image(sharedWarmSrc, record: sharedWarmRec, look: lutURL, editDirectory: editsDir)
        try check(FileDigestCache.shared.digestComputeCount - sharedBeforeSecondTile == 0 &&
                  digestCache.digestComputeCount == coldHashes,
                  "P2-05 subsequent tile load performs 0 extra hashes")

        // accept() uses plan + two isCurrent() checks with 0 hashes.
        let hBeforeAccept = digestCache.digestComputeCount
        await library.accept(previewSource, record: hdrRecord, image: coldImage, look: lutURL, editDirectory: editsDir)
        try check(digestCache.digestComputeCount - hBeforeAccept == 0, "P2-05 library.accept performs 0 redundant hashes")

        // Cache invalidation on modified LUT / HDR look / source / adjustments.
        try Data("LUT_3D_SIZE 2\n1 1 1\n".utf8).write(to: lutURL)
        let plan = try IOSPhotoPreviewPlan(source: previewSource, record: hdrRecord, look: lutURL, digestCache: digestCache)
        try check(try plan.isCurrent(in: editStore, digestCache: digestCache), "Fresh plan is current")
        try Data("LUT_3D_SIZE 2\n2 2 2\n".utf8).write(to: lutURL)
        try check(try plan.isCurrent(in: editStore, digestCache: digestCache) == false, "P2-05 LUT rewrite invalidates FileDigestCache and marks plan non-current")

        var editedAfter = hdrRaw; editedAfter.exposure = 2.0
        try editStore.save(rawID, state: PhotoEditState(settings: editedAfter))
        try check(try plan.isCurrent(in: editStore, digestCache: digestCache) == false, "P2-04 adjustment commit marks plan non-current")

        // Tampered HDR look file must fail closed (CocoaError.fileNoSuchFile).
        try editStore.save(rawID, state: hdrRecord.state!)
        try Data("tampered-hdr-cube".utf8).write(to: hdrLookURL)
        do {
            _ = try await library.image(previewSource, record: hdrRecord, look: lutURL, editDirectory: editsDir)
            try check(false, "Expected missing/tampered HDR look error")
        } catch let err as CocoaError where err.code == .fileNoSuchFile {
            print("PASS: P2-05 tampered HDR look .cube invalidates cache and fails closed")
        }

        // Remove temporary profile & source tampering check via isCurrent.
        try Data("tampered-raw".utf8).write(to: retainedSource)
        do {
            _ = try plan.isCurrent(in: editStore, digestCache: digestCache)
            try check(false, "Expected RecentPhotoError.originalChanged")
        } catch RecentPhotoError.originalChanged {
            print("PASS: P2-05 tampered retained original invalidates digest cache and throws originalChanged")
        }
    }

    private static func verifyLegacyNormalX3fPreviewRepair(in root: URL) async throws {
        let editsDir = root.appendingPathComponent("x3f-preview-edits")
        let recentsDir = root.appendingPathComponent("x3f-preview-recents")
        let cacheDir = root.appendingPathComponent("x3f-preview-cache")
        let seedStore = try EditPersistence(directory: editsDir)
        let recentStore = try RecentPhotoStore(directory: recentsDir, maximumEntries: 100, maximumOriginalBytes: 64 * 1024 * 1024)

        let flagsOnlyFile = root.appendingPathComponent("flags-only.X3F")
        let editedFile = root.appendingPathComponent("edited.X3F")
        let arwFile = root.appendingPathComponent("sony.ARW")
        try Data("FOVb-flags-only".utf8).write(to: flagsOnlyFile)
        try Data("FOVb-edited".utf8).write(to: editedFile)
        try Data("II*\0sony".utf8).write(to: arwFile)

        let flagsID = try PhotoIdentity.fallback(for: flagsOnlyFile, resourceIdentifier: "x3f-flags")
        let editedID = try PhotoIdentity.fallback(for: editedFile, resourceIdentifier: "x3f-edited")
        let arwID = try PhotoIdentity.fallback(for: arwFile, resourceIdentifier: "arw-normal")

        let flagsRecent = try recentStore.recordOpened(url: flagsOnlyFile, identity: flagsID, displayName: "flags-only.X3F", isRaw: true)
        let editedRecent = try recentStore.recordOpened(url: editedFile, identity: editedID, displayName: "edited.X3F", isRaw: true)
        let arwRecent = try recentStore.recordOpened(url: arwFile, identity: arwID, displayName: "sony.ARW", isRaw: true)

        var flagsOnly = RawSettings.default
        flagsOnly.x3fMode = .normal
        flagsOnly.aiDenoiseEnabled = true
        flagsOnly.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)
        try seedStore.save(flagsID, state: PhotoEditState(settings: flagsOnly))
        try seedStore.save(arwID, state: PhotoEditState(settings: flagsOnly))

        var edited = flagsOnly
        edited.exposure = 0.6
        edited.lensCorrection?.profileID = "sigma-35"
        try seedStore.save(editedID, state: PhotoEditState(settings: edited))

        let editsJSON = editsDir.appendingPathComponent("edits.json")
        let rawBefore = try Data(contentsOf: editsJSON)

        let library = await MainActor.run {
            IOSPhotoPreviewLibrary(recentStore: recentStore, cacheDirectory: cacheDir)
        }
        await library.reload(editDirectory: editsDir)
        let editedMap = await MainActor.run { library.edited }
        try check(editedMap[flagsRecent.id] == false, "Flags-only legacy normal X3F recent photo must not be marked edited")
        try check(editedMap[editedRecent.id] == true, "Edited legacy normal X3F recent photo remains marked edited")
        try check(editedMap[arwRecent.id] == true, "Non-X3F normal photo with lens flags remains marked edited")

        let editedSource = try await library.source(for: editedRecent)
        try check(flagsRecent.isX3f && editedRecent.isX3f && editedSource.isX3f && !arwRecent.isX3f,
                  "RecentPhoto and IOSPhotoPreviewSource classify X3F purely by extension without file IO")
        let flagsRecord = try await library.record(for: flagsID, isX3f: flagsRecent.isX3f, editDirectory: editsDir)
        try check(!IOSPhotoPreviewPlan.isEdited(flagsRecord, isRaw: flagsRecent.isRaw, isX3f: flagsRecent.isX3f),
                  "Thumbnail load path for flags-only normal X3F must evaluate as unedited")
        let rawRecord = try await library.record(for: editedID, isX3f: editedRecent.isX3f, editDirectory: editsDir)
        let plan = try IOSPhotoPreviewPlan(source: editedSource, record: rawRecord, look: nil)
        try check(plan.settings.aiDenoiseEnabled == false &&
                  plan.settings.lensSettings.isEnabled == false &&
                  plan.settings.lensCorrection?.profileID == "sigma-35" &&
                  plan.settings.exposure == 0.6,
                  "IOSPhotoPreviewPlan repairs legacy normal X3F in memory")
        try check(try plan.isCurrent(in: seedStore), "Repaired IOSPhotoPreviewPlan matches store in isCurrent without mutating disk")
        try check((try Data(contentsOf: editsJSON)) == rawBefore, "iOS preview read-only path must leave edits.json untouched on disk")
        print("PASS: iOS photo preview repairs legacy normal X3F in memory without mutating disk")
    }
}
