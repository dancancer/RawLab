import AppKit
import CryptoKit
import Foundation
import ImageIO

// Standalone model stub for RenderEngine / AIPreparation so MacEditedPhotoPreviews
// can be tested deterministically without linking the C++ ISP static libraries.
final class AIPreparation: @unchecked Sendable {
    init(onProgress: @escaping @Sendable (Int, Int, String) -> Void) {}
    func cancel() {}
}

enum HDRCameraProfileAssetStore {
    static var directory: URL { FileManager.default.temporaryDirectory }
    static func url(for profile: HDRCameraProfile) throws -> URL {
        directory.appendingPathComponent(String(describing: profile))
    }
}

final class RenderEngine {
    struct Frame {
        let image: CGImage
    }

    private static let lock = NSLock()
    private static var _renderCalls = 0
    private static var _failNextRender = false
    static var renderCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _renderCalls
    }
    static var failNextRender: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failNextRender }
        set { lock.lock(); _failNextRender = newValue; lock.unlock() }
    }
    static func resetCounts() {
        lock.lock(); _renderCalls = 0; _failNextRender = false; lock.unlock()
    }

    static var bundledAIModel: URL? { nil }

    static func isRasterInput(_ url: URL) -> Bool {
        !DirectoryContents.rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func validateAIInput(_ url: URL, settings: Adjustments) throws {}

    init() throws {}

    func prepareAI(_ url: URL, settings: Adjustments, progress: AIPreparation) throws {}

    func render(_ url: URL, settings: Adjustments, lut: URL?, edge: Int, viewportPreview: Bool = false) throws -> Frame? {
        Self.lock.lock()
        let shouldFail = Self._failNextRender
        Self._failNextRender = false
        Self.lock.unlock()
        if shouldFail {
            throw CocoaError(.coderInvalidValue)
        }
        if let lut, !FileManager.default.fileExists(atPath: lut.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        Self.lock.lock()
        Self._renderCalls += 1
        Self.lock.unlock()
        let width = max(16, min(edge, 240))
        let height = max(16, width * 2 / 3)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let normalized = max(0, min(1, (settings.exposure + 4) / 8))
        context.setFillColor(red: CGFloat(normalized), green: 0.35, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return Frame(image: context.makeImage()!)
    }
}

@main
struct ThumbnailCacheTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() {
            fputs("FAIL (line \(line)): \(message)\n", stderr)
            exit(1)
        }
    }

    private static func writePNG(to url: URL, width: Int = 360, height: Int = 240, red: CGFloat = 0.25) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: 0.45, blue: 0.65, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("rawlab-thumbnail-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await verifyUneditedCacheHitAndDeduplication(in: root)
        try await verifyKeyIsolationAndCostLimit(in: root)
        try await verifyEditedPreviewHitAndInvalidation(in: root)
        try await verifyFirstEditRacesInFlightOriginalDecode(in: root)
        try await verifyResetIdempotentSingleInvalidation(in: root)
        try await verifyLookRemovalAndRenderFailureClearStaleTile(in: root)
        try await verifyFolderRefreshInvalidation(in: root)
        try await verifyLUTResourceDigestCacheAndInvalidation(in: root)
        try await verifyCommitEditPersistenceReadBudget(in: root)

        print("PASS: thumbnail cache hit without re-decode, edited/unedited key isolation, byte-cost eviction, and edit/reset/refresh invalidation")
    }

    @MainActor
    private static func verifyUneditedCacheHitAndDeduplication(in root: URL) async throws {
        let dir = root.appendingPathComponent("unedited", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("sample.png")
        try writePNG(to: photo)

        let thumbnails = PhotoThumbnails()
        check(thumbnails.totalCostLimit == PhotoThumbnails.defaultTotalCostLimit, "Default totalCostLimit configured")
        check(thumbnails.decodeCount == 0, "Fresh cache starts at 0 decodes")

        let first = await thumbnails.image(for: photo)
        check(first != nil, "First fetch decodes thumbnail")
        check(thumbnails.decodeCount == 1, "First fetch performs 1 decode")

        let second = await thumbnails.image(for: photo)
        check(second === first, "Second fetch returns identical cached NSImage instance")
        check(thumbnails.decodeCount == 1, "Second fetch hits NSCache without re-decoding")

        // Concurrent requests for the same cold key coalesce into a single decode.
        let photo2 = dir.appendingPathComponent("concurrent.png")
        try writePNG(to: photo2, red: 0.6)
        async let concurrentA = thumbnails.image(for: photo2)
        async let concurrentB = thumbnails.image(for: photo2)
        let (resA, resB) = await (concurrentA, concurrentB)
        check(resA != nil && resA === resB, "Concurrent requests share decoded image")
        check(thumbnails.decodeCount == 2, "Concurrent requests decode cold photo only once")

        // Symlink to same file resolves to the same canonical cache key and hits without re-decoding.
        let symlink = dir.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: photo)
        let viaSymlink = await thumbnails.image(for: symlink)
        check(viaSymlink === first && thumbnails.decodeCount == 2, "Symlink resolves to canonical cached entry")
    }

    @MainActor
    private static func verifyKeyIsolationAndCostLimit(in root: URL) async throws {
        let dir = root.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("photo.png")
        try writePNG(to: photo, width: 320, height: 240)

        let unedited180 = PhotoThumbnailCacheKey(uneditedFileAt: photo, maxPixelSize: 180)!
        let unedited256 = PhotoThumbnailCacheKey(uneditedFileAt: photo, maxPixelSize: 256)!
        check(unedited180 != unedited256, "Cache key distinguishes maxPixelSize")

        let editedV1 = PhotoThumbnailCacheKey(
            path: unedited180.path, fileSize: unedited180.fileSize,
            modified: unedited180.modified, fileNumber: unedited180.fileNumber,
            maxPixelSize: 256, appliesAdjustments: true, adjustmentRevision: "rev-1"
        )
        let editedV2 = PhotoThumbnailCacheKey(
            path: unedited180.path, fileSize: unedited180.fileSize,
            modified: unedited180.modified, fileNumber: unedited180.fileNumber,
            maxPixelSize: 256, appliesAdjustments: true, adjustmentRevision: "rev-2"
        )
        let uneditedSameEdge = PhotoThumbnailCacheKey(
            path: unedited180.path, fileSize: unedited180.fileSize,
            modified: unedited180.modified, fileNumber: unedited180.fileNumber,
            maxPixelSize: 256, appliesAdjustments: false, adjustmentRevision: nil
        )
        check(editedV1 != unedited180 && editedV1 != uneditedSameEdge, "Cache key distinguishes edited vs unedited for identical path and edge")
        check(editedV1 != editedV2, "Cache key distinguishes adjustment revisions")

        let thumbnails = PhotoThumbnails()
        let rawImage = await thumbnails.image(for: photo)!
        let editedImage = NSImage(size: NSSize(width: 256, height: 170), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        thumbnails.store(editedImage, for: editedV1)
        check(thumbnails.cachedImage(for: unedited180) === rawImage, "Unedited entry preserved alongside edited entry")
        check(thumbnails.cachedImage(for: editedV1) === editedImage, "Edited entry stored under distinct key")
        check(thumbnails.cachedImage(for: editedV2) == nil, "Different adjustment revision misses cache")

        // Verify pixel-byte cost estimation and NSCache totalCostLimit eviction.
        let singleCost = PhotoThumbnails.imageCost(rawImage)
        check(singleCost >= 180 * 135 * 4, "Image cost reflects uncompressed RGBA pixel bytes (\(singleCost))")

        let bounded = PhotoThumbnails(totalCostLimit: singleCost * 2, countLimit: 100)
        var keys: [PhotoThumbnailCacheKey] = []
        for idx in 0..<6 {
            let file = dir.appendingPathComponent("item-\(idx).png")
            try writePNG(to: file, width: 320, height: 240, red: CGFloat(idx) / 10.0)
            keys.append(PhotoThumbnailCacheKey(uneditedFileAt: file)!)
            _ = await bounded.image(for: file)
        }
        let retainedCount = keys.filter { bounded.cachedImage(for: $0) != nil }.count
        check(retainedCount < keys.count && retainedCount <= 2,
              "NSCache totalCostLimit evicts older entries under memory budget (retained \(retainedCount)/\(keys.count))")
    }

    @MainActor
    private static func verifyEditedPreviewHitAndInvalidation(in root: URL) async throws {
        RenderEngine.resetCounts()
        let dir = root.appendingPathComponent("edited-flow", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let diskCacheDir = dir.appendingPathComponent("disk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let photo = dir.appendingPathComponent("frame.png")
        try writePNG(to: photo)

        let store = try EditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let thumbnails = PhotoThumbnails()
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: diskCacheDir, thumbnails: thumbnails)

        // 1. Prime unedited thumbnail first (as WorkspacePhotoTile does before edits).
        let initialRecord = try await previews.record(for: photo)
        check(!MacPhotoPreviewPlan.isEdited(initialRecord), "Initially unedited")
        let uneditedImg = await previews.originalImage(for: photo, identity: initialRecord.identity)
        check(uneditedImg != nil && thumbnails.decodeCount == 1, "Unedited thumbnail decoded once")
        check(previews.cachedThumbnail(for: photo)?.isEdited == false, "Active presentation tracks unedited thumbnail")

        // 2. Commit edit v1 (exposure = +1.0): EditPersistence automatically invalidates without manual calls.
        let revisionBeforeV1 = previews.revision
        var settingsV1 = Adjustments(); settingsV1.exposureMode = .sensor; settingsV1.exposure = 1.0
        let outcomeV1 = session.commitEdit(expected: initialRecord, state: PhotoEditState(settings: settingsV1, filmID: ""))
        check(outcomeV1.status == .applied, "Edit v1 committed")
        check(previews.revision > revisionBeforeV1, "Edit v1 automatically advances preview revision")

        // Active unedited presentation must not masquerade as current after automatic edit invalidation.
        check(previews.cachedThumbnail(for: photo) == nil, "Edit invalidation clears stale unedited active presentation")

        // 3. Render edited preview v1 once; second fetch (simulating view rebuild) must hit memory NSCache.
        let recordV1 = try await previews.record(for: photo)
        check(MacPhotoPreviewPlan.isEdited(recordV1), "Record v1 is edited")
        let planV1 = try MacPhotoPreviewPlan(record: recordV1, films: [])
        let keyV1 = PhotoThumbnailCacheKey(identity: recordV1.identity, previewKey: planV1.key)

        let renderedV1First = try await previews.image(for: recordV1)
        let statsAfterFirst = await previews.renderStats()
        check(RenderEngine.renderCalls == 1 && statsAfterFirst.renders == 1 && statsAfterFirst.decodes == 1,
              "Cold edited preview renders and decodes once")
        check(renderedV1First !== uneditedImg, "Edited thumbnail is distinct from unedited thumbnail")

        // Delete disk preview cache to prove subsequent rebuild hits in-memory NSCache rather than disk.
        try? FileManager.default.removeItem(at: diskCacheDir)

        let rebuildPresentation = previews.cachedThumbnail(for: photo)
        check(rebuildPresentation?.image === renderedV1First && rebuildPresentation?.isEdited == true,
              "View rebuild synchronously hits cached edited presentation")
        let cachedHit = await previews.cachedImage(for: recordV1)
        check(cachedHit === renderedV1First, "cachedImage(for:) hits NSCache")
        let renderedV1Second = try await previews.image(for: recordV1)
        let statsAfterSecond = await previews.renderStats()
        check(renderedV1Second === renderedV1First, "Second image(for:) returns same NSImage instance")
        check(RenderEngine.renderCalls == 1 && statsAfterSecond.renders == 1 && statsAfterSecond.diskReads == 0 && statsAfterSecond.decodes == 1,
              "Second fetch performs zero RAW renders, zero disk reads, and zero PNG decodes")

        // 4. Edit again to v2 (exposure = +2.2): v1 must be automatically evicted from NSCache without manual calls.
        let revisionBeforeV2 = previews.revision
        var settingsV2 = settingsV1; settingsV2.exposure = 2.2
        let outcomeV2 = session.commitEdit(expected: recordV1, state: PhotoEditState(settings: settingsV2, filmID: ""))
        check(outcomeV2.status == .applied, "Edit v2 committed")
        check(previews.revision > revisionBeforeV2, "Edit v2 automatically advances preview revision")

        check(thumbnails.cachedImage(for: keyV1) == nil, "Edit v2 automatically evicts v1 edited entry from NSCache")
        check(previews.cachedThumbnail(for: photo) == nil, "Edit v2 automatically clears v1 active presentation")
        let staleV1 = await previews.cachedImage(for: recordV1)
        check(staleV1 == nil, "Stale record v1 no longer resolves cached image")

        let recordV2 = try await previews.record(for: photo)
        let planV2 = try MacPhotoPreviewPlan(record: recordV2, films: [])
        let keyV2 = PhotoThumbnailCacheKey(identity: recordV2.identity, previewKey: planV2.key)
        let renderedV2 = try await previews.image(for: recordV2)
        check(RenderEngine.renderCalls == 2, "Edit v2 renders updated preview once")
        check(thumbnails.cachedImage(for: keyV2) === renderedV2, "Edit v2 stored in NSCache")

        // 5. Reset to unmodified: v2 must be automatically evicted without manual calls; unedited entry stays valid.
        let revisionBeforeReset = previews.revision
        let cleared = try session.resetToUnmodified(photo)
        check(cleared.state == nil, "Reset cleared persisted state")
        check(previews.revision > revisionBeforeReset, "Reset automatically advances preview revision")

        check(thumbnails.cachedImage(for: keyV2) == nil, "Reset automatically evicts edited entry from NSCache")
        check(previews.cachedThumbnail(for: photo) == nil, "Reset automatically clears edited active presentation")

        let recordAfterReset = try await previews.record(for: photo)
        check(!MacPhotoPreviewPlan.isEdited(recordAfterReset), "Record is unedited after reset")
        let restoredOriginal = await previews.originalImage(for: photo, identity: recordAfterReset.identity)
        check(restoredOriginal === uneditedImg && thumbnails.decodeCount == 1,
              "After reset, unedited thumbnail is served from unedited cache entry without re-decoding")
    }

    @MainActor
    private static func verifyFirstEditRacesInFlightOriginalDecode(in root: URL) async throws {
        RenderEngine.resetCounts()
        let dir = root.appendingPathComponent("first-edit-race", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let diskCacheDir = dir.appendingPathComponent("disk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        final class DecodeGate: @unchecked Sendable {
            private let lock = NSLock()
            private var armedPath: String?
            private var onEnter: (@Sendable () -> Void)?
            private var releaseSemaphore: DispatchSemaphore?

            func arm(for url: URL, onEnter: @escaping @Sendable () -> Void) -> DispatchSemaphore {
                let sem = DispatchSemaphore(value: 0)
                lock.lock()
                armedPath = PhotoThumbnailCacheKey.canonicalPath(for: url)
                self.onEnter = onEnter
                releaseSemaphore = sem
                lock.unlock()
                return sem
            }

            func interceptIfNeeded(for url: URL) {
                let path = PhotoThumbnailCacheKey.canonicalPath(for: url)
                lock.lock()
                guard armedPath == path, let sem = releaseSemaphore else {
                    lock.unlock()
                    return
                }
                let callback = onEnter
                armedPath = nil
                onEnter = nil
                releaseSemaphore = nil
                lock.unlock()
                callback?()
                _ = sem.wait(timeout: .now() + 5)
            }
        }

        let gate = DecodeGate()
        // Enable observesEditPersistence to match PhotoThumbnails.shared alongside MacEditedPhotoPreviews.
        let thumbnails = PhotoThumbnails(observesEditPersistence: true) { url, maxPixelSize in
            gate.interceptIfNeeded(for: url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                      kCGImageSourceShouldCache: false
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        let store = try EditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: diskCacheDir, thumbnails: thumbnails)

        // Case A: First edit committed AND edited thumbnail stored while pre-edit originalImage decode is in flight.
        let photo1 = dir.appendingPathComponent("race-after-render.png")
        try writePNG(to: photo1, red: 0.15)
        let path1 = PhotoThumbnailCacheKey.canonicalPath(for: photo1)
        let initial1 = try await previews.record(for: photo1)
        check(!MacPhotoPreviewPlan.isEdited(initial1), "Photo 1 starts unedited")
        check(thumbnails.editGeneration(forPath: path1) == 0, "Unedited photo starts at editGeneration 0")

        let (enteredStream1, enteredCont1) = AsyncStream<Void>.makeStream()
        let release1 = gate.arm(for: photo1) { enteredCont1.yield() }
        let inFlightOriginal1 = Task { @MainActor in
            await previews.originalImage(for: photo1, identity: initial1.identity, recordAsActive: true)
        }
        var iter1 = enteredStream1.makeAsyncIterator()
        _ = await iter1.next()

        // Commit the very first edit (before beginEditedRender or store has ever run for path1).
        var settings1 = Adjustments(); settings1.exposureMode = .sensor; settings1.exposure = 1.4
        let state1 = PhotoEditState(settings: settings1, filmID: "")
        let commit1 = session.commitEdit(expected: initial1, state: state1)
        check(commit1.status == .applied, "First edit committed while unedited decode is in flight")
        check(thumbnails.editGeneration(forPath: path1) == 1,
              "First edit immediately advances editGeneration from 0 to 1 without waiting for render")
        check(thumbnails.editedInvalidationCount == 1 && previews.editedInvalidationCount == 1,
              "First edit advances invalidation counters once even with dual persistence observers")

        // Verify idempotency: duplicate notifications / reconcile calls for the same edit state must not re-advance.
        let editedRecord1 = commit1.saved!
        let rev1 = EditPersistence.editedRevision(for: state1, atPath: path1)!
        let editedRev1 = PhotoThumbnails.EditedRevision(
            identity: editedRecord1.identity.thumbnailFileIdentity,
            revision: rev1
        )
        NotificationCenter.default.post(
            name: EditPersistence.didChangeRecordsNotification,
            object: nil,
            userInfo: [
                EditPersistence.directoryPathUserInfoKey: store.canonicalDirectoryPath,
                EditPersistence.changedRecordsUserInfoKey: [path1: editedRecord1],
                EditPersistence.invalidatedPathsUserInfoKey: Set([path1]),
                EditPersistence.editedRevisionsUserInfoKey: [path1: rev1],
                EditPersistence.fileIdentitiesUserInfoKey: [path1: (
                    editedRecord1.identity.size,
                    editedRecord1.identity.modified,
                    editedRecord1.identity.fileNumber
                )]
            ]
        )
        check(!thumbnails.reconcileEditedRevision(editedRev1, atPath: path1),
              "Duplicate reconcileEditedRevision for identical revision is a no-op")
        check(thumbnails.editGeneration(forPath: path1) == 1,
              "Duplicate notifications for same edit do not advance editGeneration again")
        check(thumbnails.editedInvalidationCount == 1 && previews.editedInvalidationCount == 1,
              "Duplicate notifications for same edit do not increment invalidation counts")

        // Render and store edited preview while unedited decode is still blocked in flight.
        let editedImg1 = try await previews.image(for: editedRecord1)
        check(previews.cachedThumbnail(for: photo1)?.image === editedImg1 && previews.cachedThumbnail(for: photo1)?.isEdited == true,
              "Edited thumbnail active at generation 1 before in-flight original decode finishes")

        // Release in-flight unedited decode captured at generation 0; it must NOT overwrite activeKeys.
        release1.signal()
        let lateOriginalImg1 = await inFlightOriginal1.value
        check(lateOriginalImg1 != nil && lateOriginalImg1 !== editedImg1, "In-flight unedited decode completed")
        check(previews.cachedThumbnail(for: photo1)?.image === editedImg1 && previews.cachedThumbnail(for: photo1)?.isEdited == true,
              "Late pre-edit originalImage decode rejected and did not overwrite edited active presentation")

        var tile1 = WorkspacePhotoTileState()
        tile1.appear(url: photo1, previews: previews)
        check(tile1.thumbnail === editedImg1 && tile1.edited && tile1.adjustedThumbnail,
              "Rebuilt tile onAppear displays edited image rather than late pre-edit original")
        await tile1.refresh(url: photo1, previews: previews)
        check(tile1.thumbnail === editedImg1 && tile1.edited && tile1.adjustedThumbnail && tile1.notice == nil,
              "Tile refresh keeps displaying edited image after late pre-edit decode")

        // Case B: Unedited WorkspacePhotoTileState.refresh starts decode, first edit commits, late decode finishes before edited render, then tile refreshes.
        let photo2 = dir.appendingPathComponent("race-before-render.png")
        try writePNG(to: photo2, red: 0.55)
        let path2 = PhotoThumbnailCacheKey.canonicalPath(for: photo2)

        let (enteredStream2, enteredCont2) = AsyncStream<Void>.makeStream()
        let release2 = gate.arm(for: photo2) { enteredCont2.yield() }
        var tile2 = WorkspacePhotoTileState()
        let staleTileTask = Task { @MainActor in
            var copy = tile2
            await copy.refresh(url: photo2, previews: previews)
            return copy
        }
        var iter2 = enteredStream2.makeAsyncIterator()
        _ = await iter2.next()

        let initial2 = try store.readState(for: photo2)
        let commit2 = session.commitEdit(expected: initial2, state: state1)
        check(commit2.status == .applied && thumbnails.editGeneration(forPath: path2) == 1,
              "First edit on photo 2 advances editGeneration from 0 to 1 while tile original decode is in flight")
        staleTileTask.cancel()
        release2.signal()
        _ = await staleTileTask.value

        check(previews.cachedThumbnail(for: photo2) == nil,
              "Late unedited decode from cancelled pre-edit tile refresh is rejected from activeKeys")
        await tile2.refresh(url: photo2, previews: previews)
        let uneditedKey2 = PhotoThumbnailCacheKey(uneditedFileAt: photo2)!
        let cachedUnedited2 = thumbnails.cachedImage(for: uneditedKey2)
        check(cachedUnedited2 != nil, "Unedited NSCache key remains intact without relaxing cache key dimensions")
        check(tile2.edited && tile2.adjustedThumbnail && tile2.thumbnail != nil && tile2.thumbnail !== cachedUnedited2 && tile2.notice == nil,
              "Tile ultimately displays edited image instead of pre-edit original")

        // Case C: Re-entering edited state after reset while a post-reset unedited decode is in flight.
        let cleared2 = try session.resetToUnmodified(photo2)
        check(cleared2.state == nil && thumbnails.editGeneration(forPath: path2) == 2,
              "Reset advances editGeneration to 2")
        thumbnails.invalidate(for: photo2)
        let genAfterFileInvalidate = thumbnails.editGeneration(forPath: path2)

        let (enteredStream3, enteredCont3) = AsyncStream<Void>.makeStream()
        let release3 = gate.arm(for: photo2) { enteredCont3.yield() }
        let inFlightPostReset = Task { @MainActor in
            await previews.originalImage(for: photo2, identity: cleared2.identity, recordAsActive: true)
        }
        var iter3 = enteredStream3.makeAsyncIterator()
        _ = await iter3.next()

        var settings3 = settings1; settings3.exposure = 2.1
        let commit3 = session.commitEdit(expected: cleared2, state: PhotoEditState(settings: settings3, filmID: ""))
        check(commit3.status == .applied && thumbnails.editGeneration(forPath: path2) == genAfterFileInvalidate + 1,
              "Re-editing after reset immediately advances editGeneration again")
        let editedImg3 = try await previews.image(for: commit3.saved!)
        release3.signal()
        _ = await inFlightPostReset.value
        check(previews.cachedThumbnail(for: photo2)?.image === editedImg3 && previews.cachedThumbnail(for: photo2)?.isEdited == true,
              "Post-reset in-flight unedited decode cannot overwrite newly re-edited presentation")

        // Case D: Same-name file replacement (idA -> idB) + invalidate(for:) (.invalidated) + recommitting identical edit parameters (R1).
        let photo3 = dir.appendingPathComponent("same-name-replaced.png")
        try writePNG(to: photo3, width: 360, height: 240, red: 0.25)
        let path3 = PhotoThumbnailCacheKey.canonicalPath(for: photo3)
        let initialA = try await previews.record(for: photo3)
        let idA = initialA.identity
        check(!MacPhotoPreviewPlan.isEdited(initialA) && thumbnails.editGeneration(forPath: path3) == 0,
              "Photo 3 (idA) starts unedited at editGeneration 0")

        let rev3 = EditPersistence.editedRevision(for: state1, atPath: path3)!
        let commitA = session.commitEdit(expected: initialA, state: state1)
        check(commitA.status == .applied && thumbnails.editGeneration(forPath: path3) == 1,
              "Editing idA advances editGeneration from 0 to 1")
        let editedImgA = try await previews.image(for: commitA.saved!)
        check(previews.cachedThumbnail(for: photo3)?.image === editedImgA && previews.cachedThumbnail(for: photo3)?.isEdited == true,
              "idA edited thumbnail cached as active")

        // Replace photo3 on disk at the same path with new file identity idB != idA; watchedFileDidChange / invalidate(for:) marks old state invalidated.
        try writePNG(to: photo3, width: 420, height: 280, red: 0.75)
        let unmodifiedB = try store.readState(for: photo3)
        let idB = unmodifiedB.identity
        check(idB != idA && unmodifiedB.state == nil && !MacPhotoPreviewPlan.isEdited(unmodifiedB),
              "Replaced file has distinct identity idB != idA and is unedited in EditPersistence")
        previews.invalidate(for: photo3)
        let genAfterReplaceInvalidate = thumbnails.editGeneration(forPath: path3)
        check(genAfterReplaceInvalidate == 2 && previews.cachedThumbnail(for: photo3) == nil,
              "invalidate(for:) after file replacement advances editGeneration to 2 and clears activeKeys")

        let (enteredStreamB, enteredContB) = AsyncStream<Void>.makeStream()
        let releaseB = gate.arm(for: photo3) { enteredContB.yield() }
        let inFlightOriginalB = Task { @MainActor in
            await previews.originalImage(for: photo3, identity: idB, recordAsActive: true)
        }
        var iterB = enteredStreamB.makeAsyncIterator()
        _ = await iterB.next()

        let thumbInvBeforeB = thumbnails.editedInvalidationCount
        let previewInvBeforeB = previews.editedInvalidationCount
        let commitB = session.commitEdit(expected: unmodifiedB, state: state1)
        let savedB = commitB.saved!
        check(commitB.status == .applied && EditPersistence.editedRevision(for: savedB.state, atPath: path3) == rev3,
              "Committed identical edit parameters (same revision R1) onto replacement file idB")
        check(thumbnails.editGeneration(forPath: path3) == genAfterReplaceInvalidate + 1,
              "Recommitting identical edit parameters onto replaced file idB advances editGeneration")
        check(thumbnails.editedInvalidationCount == thumbInvBeforeB + 1 && previews.editedInvalidationCount == previewInvBeforeB + 1,
              "Replacement edit advances invalidation counters once")

        // Duplicate notifications for (idB, R1) remain idempotent.
        let editedRevB = PhotoThumbnails.EditedRevision(identity: idB.thumbnailFileIdentity, revision: rev3)
        NotificationCenter.default.post(
            name: EditPersistence.didChangeRecordsNotification,
            object: nil,
            userInfo: [
                EditPersistence.directoryPathUserInfoKey: store.canonicalDirectoryPath,
                EditPersistence.changedRecordsUserInfoKey: [path3: savedB],
                EditPersistence.invalidatedPathsUserInfoKey: Set([path3]),
                EditPersistence.editedRevisionsUserInfoKey: [path3: rev3],
                EditPersistence.fileIdentitiesUserInfoKey: [path3: (idB.size, idB.modified, idB.fileNumber)]
            ]
        )
        check(!thumbnails.reconcileEditedRevision(editedRevB, atPath: path3),
              "Duplicate reconcileEditedRevision for same (idB, R1) is a no-op")
        check(thumbnails.editGeneration(forPath: path3) == genAfterReplaceInvalidate + 1 &&
              thumbnails.editedInvalidationCount == thumbInvBeforeB + 1 &&
              previews.editedInvalidationCount == previewInvBeforeB + 1,
              "Duplicate notifications for (idB, R1) keep editGeneration and editedInvalidationCount stable")

        let editedImgB = try await previews.image(for: savedB)
        releaseB.signal()
        let lateOriginalB = await inFlightOriginalB.value
        check(lateOriginalB != nil && lateOriginalB !== editedImgB,
              "In-flight originalImage(idB) decode completed")
        check(previews.cachedThumbnail(for: photo3)?.image === editedImgB && previews.cachedThumbnail(for: photo3)?.isEdited == true,
              "In-flight originalImage(idB) cannot overwrite edited active presentation after same-parameter recommit")
        let uneditedKeyB = PhotoThumbnailCacheKey(uneditedFileAt: photo3)!
        check(thumbnails.cachedImage(for: uneditedKeyB) === lateOriginalB,
              "Unedited NSCache key for idB remains intact alongside edited key")

        var tileB = WorkspacePhotoTileState()
        tileB.appear(url: photo3, previews: previews)
        check(tileB.thumbnail === editedImgB && tileB.edited && tileB.adjustedThumbnail,
              "Tile onAppear displays idB edited thumbnail rather than original")
        await tileB.refresh(url: photo3, previews: previews)
        check(tileB.thumbnail === editedImgB && tileB.edited && tileB.adjustedThumbnail && tileB.notice == nil,
              "Tile refresh keeps displaying idB edited thumbnail")

        // Case E: Unwatched same-name replacement (idB -> idC, no prior invalidate) + recommitting identical edit parameters (R1).
        try writePNG(to: photo3, width: 480, height: 320, red: 0.45)
        let unmodifiedC = try store.readState(for: photo3)
        let idC = unmodifiedC.identity
        check(idC != idB && unmodifiedC.state == nil,
              "Second same-name replacement produces distinct unedited identity idC != idB")
        let genBeforeC = thumbnails.editGeneration(forPath: path3)

        let (enteredStreamC, enteredContC) = AsyncStream<Void>.makeStream()
        let releaseC = gate.arm(for: photo3) { enteredContC.yield() }
        let inFlightOriginalC = Task { @MainActor in
            await previews.originalImage(for: photo3, identity: idC, recordAsActive: true)
        }
        var iterC = enteredStreamC.makeAsyncIterator()
        _ = await iterC.next()

        let previewInvBeforeC = previews.editedInvalidationCount
        let commitC = session.commitEdit(expected: unmodifiedC, state: state1)
        check(commitC.status == .applied && thumbnails.editGeneration(forPath: path3) == genBeforeC + 1,
              "Recommitting identical edit parameters onto unwatched replacement idC still advances editGeneration")
        check(thumbnails.cachedImage(for: uneditedKeyB) == nil,
              "Tracking idC drops the unedited thumbnail that was decoded from previous identity idB")
        releaseC.signal()
        let lateOriginalC = await inFlightOriginalC.value
        check(lateOriginalC != nil && previews.cachedThumbnail(for: photo3) == nil,
              "Late originalImage(idC) decode finishing before edited render is rejected from activeKeys")
        var tileC = WorkspacePhotoTileState()
        await tileC.refresh(url: photo3, previews: previews)
        check(tileC.edited && tileC.adjustedThumbnail && tileC.thumbnail != nil && tileC.thumbnail !== lateOriginalC && tileC.notice == nil,
              "Tile displays idC edited thumbnail rather than in-flight originalImage(idC)")
        check(previews.editedInvalidationCount == previewInvBeforeC + 1,
              "Tile refresh after the replacement does not count a second edited invalidation")
    }

    @MainActor
    private static func verifyResetIdempotentSingleInvalidation(in root: URL) async throws {
        RenderEngine.resetCounts()
        let dir = root.appendingPathComponent("reset-idempotency", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let diskCacheDir = dir.appendingPathComponent("disk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let photo = dir.appendingPathComponent("reset-photo.png")
        try writePNG(to: photo, red: 0.35)

        let store = try EditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let thumbnails = PhotoThumbnails()
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: diskCacheDir, thumbnails: thumbnails)

        let initial = try await previews.record(for: photo)
        let uneditedImg = await previews.originalImage(for: photo, identity: initial.identity)!

        // Commit edited state and render edited tile.
        var editedSettings = Adjustments(); editedSettings.exposureMode = .sensor; editedSettings.exposure = 1.5
        let editOutcome = session.commitEdit(expected: initial, state: PhotoEditState(settings: editedSettings, filmID: ""))
        check(editOutcome.status == .applied, "Initial edit committed")

        var tile = WorkspacePhotoTileState()
        await tile.refresh(url: photo, previews: previews)
        check(tile.adjustedThumbnail && tile.edited && tile.thumbnail !== uneditedImg, "Tile shows edited thumbnail")

        let thumbInvalidationsBeforeReset = thumbnails.editedInvalidationCount
        let previewInvalidationsBeforeReset = previews.editedInvalidationCount

        // Reset by committing neutral Adjustments (same as EditorModel Reset All via commitAdjustment).
        var neutralSettings = Adjustments(); neutralSettings.exposureMode = .sensor
        let neutralOutcome = session.commitEdit(expected: editOutcome.saved!, state: PhotoEditState(settings: neutralSettings, filmID: ""))
        check(neutralOutcome.status == .applied, "Neutral reset state committed")
        check(thumbnails.editedInvalidationCount == thumbInvalidationsBeforeReset + 1,
              "Reset invalidates PhotoThumbnails edited state exactly once")
        check(previews.editedInvalidationCount == previewInvalidationsBeforeReset + 1,
              "Reset invalidates MacEditedPhotoPreviews edited presentation exactly once")

        // Tile refreshes immediately to unedited thumbnail and records activeKeys[path] with isEdited = false.
        await tile.refresh(url: photo, previews: previews)
        check(!tile.edited && !tile.adjustedThumbnail && tile.thumbnail === uneditedImg,
              "Tile refreshes back to cached unedited thumbnail")
        check(previews.cachedThumbnail(for: photo)?.image === uneditedImg && previews.cachedThumbnail(for: photo)?.isEdited == false,
              "Unedited active presentation registered before late exact-frame callback")

        // Simulate late debounced .exact frame completion and duplicate invalidation calls on the neutral record.
        let neutralFrame = try RenderEngine().render(photo, settings: neutralSettings, lut: nil, edge: 256)!.image
        previews.accept(record: neutralOutcome.saved!, image: neutralFrame)
        previews.invalidateEdited(for: photo)
        _ = thumbnails.invalidateEdited(for: photo)

        check(thumbnails.editedInvalidationCount == thumbInvalidationsBeforeReset + 1,
              "Late exact frame / duplicate invalidation does not re-invalidate PhotoThumbnails")
        check(previews.editedInvalidationCount == previewInvalidationsBeforeReset + 1,
              "Late exact frame / duplicate invalidation does not re-invalidate MacEditedPhotoPreviews")

        // View rebuild (WorkspacePhotoTile.onAppear) must synchronously hit unedited thumbnail without nil flash.
        var rebuiltTile = WorkspacePhotoTileState()
        rebuiltTile.appear(url: photo, previews: previews)
        check(rebuiltTile.thumbnail === uneditedImg && !rebuiltTile.edited && !rebuiltTile.adjustedThumbnail,
              "Rebuilt tile synchronously hits unedited thumbnail without placeholder miss")
        check(thumbnails.decodeCount == 1, "Unedited thumbnail never re-decoded across edit, reset, and rebuild")
    }

    @MainActor
    private static func verifyLookRemovalAndRenderFailureClearStaleTile(in root: URL) async throws {
        RenderEngine.resetCounts()
        let dir = root.appendingPathComponent("look-removal", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let diskCacheDir = dir.appendingPathComponent("disk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let photo = dir.appendingPathComponent("look-photo.png")
        try writePNG(to: photo, red: 0.2)
        let lut = dir.appendingPathComponent("custom.cube")
        try Data("LUT_3D_SIZE 2\n".utf8).write(to: lut)
        let film = Film(name: "Custom", url: lut, managedID: "managed-custom-look")

        let store = try EditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let thumbnails = PhotoThumbnails()
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: diskCacheDir, thumbnails: thumbnails)
        previews.films = [film]

        let initial = try await previews.record(for: photo)
        let uneditedImg = await previews.originalImage(for: photo, identity: initial.identity)!

        // Apply custom look and render mounted tile.
        var lookSettings = Adjustments(); lookSettings.exposureMode = .sensor
        let lookCommit = session.commitEdit(expected: initial, state: PhotoEditState(settings: lookSettings, filmID: film.id))
        check(lookCommit.status == .applied, "Look edit committed")
        let lookPlan = try MacPhotoPreviewPlan(record: lookCommit.saved!, films: [film])
        let lookKey = PhotoThumbnailCacheKey(identity: lookCommit.saved!.identity, previewKey: lookPlan.key)

        var mountedTile = WorkspacePhotoTileState()
        await mountedTile.refresh(url: photo, previews: previews)
        let oldLookImg = mountedTile.thumbnail
        check(oldLookImg != nil && oldLookImg !== uneditedImg && mountedTile.adjustedThumbnail && mountedTile.notice == nil,
              "Mounted tile displays custom look edited thumbnail")
        check(thumbnails.cachedImage(for: lookKey) === oldLookImg, "Look edited thumbnail cached")

        // Remove the look (mirroring EditorModel.removeLook deleting LUT file and updating films).
        try FileManager.default.removeItem(at: lut)
        previews.films = []

        check(thumbnails.cachedImage(for: lookKey) == nil, "Removing look invalidates cached edited thumbnail")
        check(previews.cachedThumbnail(for: photo) == nil, "Removing look clears synchronous edited presentation")

        // Both a mounted tile and a freshly rebuilt tile must drop oldLookImg and fall back to original + notice.
        await mountedTile.refresh(url: photo, previews: previews)
        check(mountedTile.thumbnail !== oldLookImg && mountedTile.thumbnail === uneditedImg,
              "Mounted tile no longer displays removed look's stale thumbnail")
        check(mountedTile.edited && !mountedTile.adjustedThumbnail && mountedTile.notice == "预览未更新",
              "Mounted tile marks original fallback with outdated preview notice")

        var rebuiltTile = WorkspacePhotoTileState()
        rebuiltTile.appear(url: photo, previews: previews)
        check(rebuiltTile.thumbnail == nil, "Rebuilt tile onAppear does not resurrect removed look's stale thumbnail")
        await rebuiltTile.refresh(url: photo, previews: previews)
        check(rebuiltTile.thumbnail !== oldLookImg && rebuiltTile.thumbnail === uneditedImg && !rebuiltTile.adjustedThumbnail && rebuiltTile.notice == "预览未更新",
              "Rebuilt tile after look removal shows original fallback instead of stale look thumbnail")

        // Also verify render failure on an exposure-edited photo clears stale edited thumbnail.
        var expSettings = Adjustments(); expSettings.exposureMode = .sensor; expSettings.exposure = 1.0
        let expCommit = session.commitEdit(expected: lookCommit.saved!, state: PhotoEditState(settings: expSettings, filmID: ""))
        check(expCommit.status == .applied, "Exposure edit committed")
        await mountedTile.refresh(url: photo, previews: previews)
        let expEditedImg = mountedTile.thumbnail
        check(expEditedImg != nil && expEditedImg !== uneditedImg && mountedTile.adjustedThumbnail,
              "Mounted tile shows exposure-edited thumbnail")

        var expSettings2 = expSettings; expSettings2.exposure = 2.0
        let expCommit2 = session.commitEdit(expected: expCommit.saved!, state: PhotoEditState(settings: expSettings2, filmID: ""))
        check(expCommit2.status == .applied, "Second exposure edit committed")
        RenderEngine.failNextRender = true
        await mountedTile.refresh(url: photo, previews: previews)
        check(mountedTile.thumbnail !== expEditedImg && mountedTile.thumbnail === uneditedImg && !mountedTile.adjustedThumbnail && mountedTile.notice == "预览未更新",
              "Render failure clears stale prior edited thumbnail from mounted tile")
    }

    @MainActor
    private static func verifyFolderRefreshInvalidation(in root: URL) async throws {
        let dirA = root.appendingPathComponent("folder-a", isDirectory: true)
        let dirB = root.appendingPathComponent("folder-a-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let photoA = dirA.appendingPathComponent("a.png")
        let photoB = dirB.appendingPathComponent("b.png")
        try writePNG(to: photoA, red: 0.1)
        try writePNG(to: photoB, red: 0.9)

        let beforeCount = PhotoThumbnails.shared.decodeCount
        let imgA1 = await PhotoThumbnails.shared.image(for: photoA)
        let imgB1 = await PhotoThumbnails.shared.image(for: photoB)
        check(imgA1 != nil && imgB1 != nil, "Both folder thumbnails loaded")
        check(PhotoThumbnails.shared.decodeCount == beforeCount + 2, "Initial decodes recorded")

        let keyA = PhotoThumbnailCacheKey(uneditedFileAt: photoA)!
        let keyB = PhotoThumbnailCacheKey(uneditedFileAt: photoB)!
        check(PhotoThumbnails.shared.cachedImage(for: keyA) === imgA1, "Folder A entry cached")
        check(PhotoThumbnails.shared.cachedImage(for: keyB) === imgB1, "Sibling folder entry cached")

        // PhotoFolder.refresh() invalidates only entries under dirA, not dirA-sibling.
        let folder = PhotoFolder(dirA)
        await withCheckedContinuation { continuation in folder.load { continuation.resume() } }
        folder.refresh()
        await withCheckedContinuation { continuation in folder.load { continuation.resume() } }

        check(PhotoThumbnails.shared.cachedImage(for: keyA) == nil, "PhotoFolder.refresh() invalidates folder thumbnails")
        check(PhotoThumbnails.shared.cachedImage(for: keyB) === imgB1, "Sibling folder with shared prefix is not invalidated")

        let imgA2 = await PhotoThumbnails.shared.image(for: photoA)
        check(imgA2 != nil && PhotoThumbnails.shared.decodeCount == beforeCount + 3,
              "Fetching after folder refresh decodes fresh thumbnail once")

        // Verify directory invalidation during an in-flight decode isolates post-refresh callers and caches the fresh decode.
        let largePhoto = dirA.appendingPathComponent("inflight.png")
        try writePNG(to: largePhoto, width: 2400, height: 1600, red: 0.5)
        let isolated = PhotoThumbnails()
        async let preRefreshTask = isolated.image(for: largePhoto)
        isolated.invalidateDirectory(dirA)
        async let postRefreshTask = isolated.image(for: largePhoto)
        let (_, postRefreshImg) = await (preRefreshTask, postRefreshTask)
        let largeKey = PhotoThumbnailCacheKey(uneditedFileAt: largePhoto)!
        check(postRefreshImg != nil && isolated.cachedImage(for: largeKey) === postRefreshImg,
              "Post-refresh caller gets and caches fresh thumbnail even if invalidateDirectory fired mid-decode")

        PhotoThumbnails.shared.invalidateDirectory(root)
    }

    @MainActor
    private static func verifyCommitEditPersistenceReadBudget(in root: URL) async throws {
        RenderEngine.resetCounts()
        let dir = root.appendingPathComponent("commit-read-budget", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let diskCacheDir = dir.appendingPathComponent("disk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let visibleCount = 5
        var photos: [URL] = []
        for idx in 0..<visibleCount {
            let file = dir.appendingPathComponent("tile-\(idx).png")
            try writePNG(to: file, red: CGFloat(idx + 1) / 10.0)
            photos.append(file)
        }

        let store = try EditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let thumbnails = PhotoThumbnails()
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: diskCacheDir, thumbnails: thumbnails)

        // Seed edits.json before the measured commit so reads traverse an existing registry file.
        let seedRecord = try await previews.record(for: photos[visibleCount - 1])
        var seedSettings = Adjustments(); seedSettings.exposureMode = .sensor; seedSettings.exposure = 0.25
        let seedOutcome = session.commitEdit(expected: seedRecord, state: PhotoEditState(settings: seedSettings, filmID: ""))
        check(seedOutcome.status == .applied, "Seed edit applied")

        var tiles = Array(repeating: WorkspacePhotoTileState(), count: visibleCount)
        for idx in 0..<visibleCount {
            await tiles[idx].refresh(url: photos[idx], previews: previews)
        }

        // Measure total readRegistry disk parses caused by one commit plus refreshing all N visible tiles.
        let targetBefore = try await previews.record(for: photos[0])
        let readsBeforeCommit = EditPersistence.registryDiskReadCount(forDirectory: editsDir)
        var editSettings = Adjustments(); editSettings.exposureMode = .sensor; editSettings.exposure = 1.1
        let outcome = session.commitEdit(expected: targetBefore, state: PhotoEditState(settings: editSettings, filmID: ""))
        check(outcome.status == .applied, "Target commit applied")

        for idx in 0..<visibleCount {
            await tiles[idx].refresh(url: photos[idx], previews: previews)
        }
        // Re-check cached thumbnail lookup (simulates SwiftUI tile rebuild checking isCurrent).
        if let updatedRecord = outcome.saved {
            let hit = await previews.cachedImage(for: updatedRecord)
            check(hit === tiles[0].thumbnail, "Cached thumbnail returned for edited tile")
        }
        let readsDelta = EditPersistence.registryDiskReadCount(forDirectory: editsDir) - readsBeforeCommit
        check(readsDelta <= visibleCount + 1,
              "Single commit plus refreshing \(visibleCount) visible tiles performed \(readsDelta) readRegistry disk parses (limit \(visibleCount + 1))")

        // Cross-instance consistency and external edits.json overwrite/corruption invalidation.
        let reopened = try EditPersistence(directory: editsDir)
        let reopenedState = try reopened.state(for: photos[0])
        check(reopenedState?.settings.exposure == 1.1, "Separate EditPersistence instance observes committed state")

        let editsFile = editsDir.appendingPathComponent("edits.json")
        var externalSettings = Adjustments(); externalSettings.exposureMode = .sensor; externalSettings.exposure = 1.75
        try store.save(photos[1], state: PhotoEditState(settings: externalSettings, filmID: ""))
        let siblingState = try reopened.state(for: photos[1])
        check(siblingState?.settings.exposure == 1.75,
              "Second EditPersistence instance reflects state written by sibling instance")

        let externalDir = dir.appendingPathComponent("external-edits", isDirectory: true)
        let externalStore = try EditPersistence(directory: externalDir)
        var overwrittenSettings = Adjustments(); overwrittenSettings.exposureMode = .sensor; overwrittenSettings.exposure = 2.5
        try externalStore.save(photos[0], state: PhotoEditState(settings: overwrittenSettings, filmID: ""))
        let externalBytes = try Data(contentsOf: externalDir.appendingPathComponent("edits.json"))
        try externalBytes.write(to: editsFile)
        let overwrittenState = try reopened.state(for: photos[0])
        check(overwrittenState?.settings.exposure == 2.5,
              "Direct on-disk edits.json replacement invalidates registry cache")

        try Data("{\"version\":1,\"records\":{".utf8).write(to: editsFile)
        var threwCorrupt = false
        do {
            _ = try EditPersistence(directory: editsDir)
        } catch is CocoaError {
            threwCorrupt = true
        }
        check(threwCorrupt, "On-disk edits.json corruption invalidates cache and throws CocoaError")

        // External deletion of edits.json on an already-warmed instance must invalidate cache.
        let deleteDir = dir.appendingPathComponent("external-delete", isDirectory: true)
        let deleteStore = try EditPersistence(directory: deleteDir)
        try deleteStore.save(photos[0], state: PhotoEditState(settings: externalSettings, filmID: ""))
        let deleteWarm = try deleteStore.state(for: photos[0])
        check(deleteWarm?.settings.exposure == 1.75,
              "Warmed instance returns saved state before external deletion")
        let deleteReadsBeforeHit = EditPersistence.registryDiskReadCount(forDirectory: deleteDir)
        _ = try deleteStore.state(for: photos[0])
        check(EditPersistence.registryDiskReadCount(forDirectory: deleteDir) == deleteReadsBeforeHit,
              "Second read before external deletion hits cache")
        try FileManager.default.removeItem(at: deleteDir.appendingPathComponent("edits.json"))
        let afterDelete = try deleteStore.state(for: photos[0])
        check(afterDelete == nil,
              "External edits.json deletion invalidates already-warmed instance")

        // Corrupt edits.json throwing in RegistryCache.load must invalidate & evict rather than promote/occupy an LRU slot.
        let corruptLruRoot = dir.appendingPathComponent("corrupt-lru", isDirectory: true)
        let capCount = EditPersistence.registryCacheCapacity
        let corruptDir = corruptLruRoot.appendingPathComponent("corrupt-slot", isDirectory: true)
        let corruptStore = try EditPersistence(directory: corruptDir)
        try corruptStore.save(photos[0], state: PhotoEditState(settings: externalSettings, filmID: ""))
        _ = try corruptStore.state(for: photos[0])
        var healthyDirs: [URL] = []
        var healthyStores: [EditPersistence] = []
        for idx in 0..<(capCount - 1) {
            let hDir = corruptLruRoot.appendingPathComponent("healthy-\(idx)", isDirectory: true)
            let hStore = try EditPersistence(directory: hDir)
            try hStore.save(photos[0], state: PhotoEditState(settings: externalSettings, filmID: ""))
            _ = try hStore.state(for: photos[0])
            healthyDirs.append(hDir)
            healthyStores.append(hStore)
        }
        // Corrupt corruptDir (oldest slot); must remove from cache without touching/promoting it.
        try Data("{\"version\":1,\"records\":{".utf8).write(to: corruptDir.appendingPathComponent("edits.json"))
        _ = try? corruptStore.state(for: photos[0])
        let extraHealthyDir = corruptLruRoot.appendingPathComponent("healthy-extra", isDirectory: true)
        let extraHealthyStore = try EditPersistence(directory: extraHealthyDir)
        try extraHealthyStore.save(photos[0], state: PhotoEditState(settings: externalSettings, filmID: ""))
        _ = try extraHealthyStore.state(for: photos[0])
        let oldestHealthyReadsBefore = EditPersistence.registryDiskReadCount(forDirectory: healthyDirs[0])
        _ = try healthyStores[0].state(for: photos[0])
        let oldestHealthyReadsDelta = EditPersistence.registryDiskReadCount(forDirectory: healthyDirs[0]) - oldestHealthyReadsBefore
        check(oldestHealthyReadsDelta == 0,
              "Throwing on corrupt registry must evict corrupt entry instead of occupying/promoting LRU slot (healthy-0 disk reads delta=\(oldestHealthyReadsDelta))")

        // Symlink switching (dirA <-> dirB) when both targets exist and remain unchanged.
        let symRoot = dir.appendingPathComponent("symlink-switch", isDirectory: true)
        let symDirA = symRoot.appendingPathComponent("dirA", isDirectory: true)
        let symDirB = symRoot.appendingPathComponent("dirB", isDirectory: true)
        let symLink = symRoot.appendingPathComponent("current-edits", isDirectory: true)
        let storeA = try EditPersistence(directory: symDirA)
        let storeB = try EditPersistence(directory: symDirB)
        var settingsA = Adjustments(); settingsA.exposureMode = .sensor; settingsA.exposure = 1.2
        var settingsB = Adjustments(); settingsB.exposureMode = .sensor; settingsB.exposure = 2.4
        try storeA.save(photos[0], state: PhotoEditState(settings: settingsA, filmID: ""))
        try storeB.save(photos[0], state: PhotoEditState(settings: settingsB, filmID: ""))
        try FileManager.default.createSymbolicLink(at: symLink, withDestinationURL: symDirA)

        let symStore = try EditPersistence(directory: symLink)
        let symInitial = try symStore.state(for: photos[0])
        check(symInitial?.settings.exposure == 1.2,
              "Warmed symlink store initially observes dirA state")
        try FileManager.default.removeItem(at: symLink)
        try FileManager.default.createSymbolicLink(at: symLink, withDestinationURL: symDirB)
        let symAfterSwitchB = try symStore.state(for: photos[0])
        check(symAfterSwitchB?.settings.exposure == 2.4,
              "Symlink switch dirA -> dirB observes dirB without stale dirA cache hit (got \(String(describing: symAfterSwitchB?.settings.exposure)))")
        try FileManager.default.removeItem(at: symLink)
        try FileManager.default.createSymbolicLink(at: symLink, withDestinationURL: symDirA)
        let symAfterSwitchA = try symStore.state(for: photos[0])
        check(symAfterSwitchA?.settings.exposure == 1.2,
              "Symlink switch dirB -> dirA observes dirA without stale dirB cache hit")

        // Atomic write replacing an edits.json symlink must invalidate both old and new resolved paths.
        let atomicTargetDir = symRoot.appendingPathComponent("atomic-target", isDirectory: true)
        let atomicLinkDir = symRoot.appendingPathComponent("atomic-link", isDirectory: true)
        try FileManager.default.createDirectory(at: atomicLinkDir, withIntermediateDirectories: true)
        let atomicTargetStore = try EditPersistence(directory: atomicTargetDir)
        var atomicInitial = Adjustments(); atomicInitial.exposureMode = .sensor; atomicInitial.exposure = 1.3
        try atomicTargetStore.save(photos[0], state: PhotoEditState(settings: atomicInitial, filmID: ""))
        let atomicTargetFile = atomicTargetDir.appendingPathComponent("edits.json")
        let atomicLinkFile = atomicLinkDir.appendingPathComponent("edits.json")
        try FileManager.default.createSymbolicLink(at: atomicLinkFile, withDestinationURL: atomicTargetFile)
        let atomicLinkStore = try EditPersistence(directory: atomicLinkDir)
        let atomicWarm = try atomicLinkStore.state(for: photos[0])
        check(atomicWarm?.settings.exposure == 1.3,
              "Warmed symlink edits.json store reads target state")
        var atomicUpdated = Adjustments(); atomicUpdated.exposureMode = .sensor; atomicUpdated.exposure = 2.8
        try atomicLinkStore.save(photos[0], state: PhotoEditState(settings: atomicUpdated, filmID: ""))
        let atomicPostSave = try atomicLinkStore.state(for: photos[0])
        check(atomicPostSave?.settings.exposure == 2.8,
              "Store observes post-atomic-write state after edits.json symlink replacement")
        let atomicTargetAfter = try atomicTargetStore.state(for: photos[0])
        check(atomicTargetAfter?.settings.exposure == 1.3,
              "Old symlink target retains its own uncorrupted state")

        // Bounded LRU eviction for EditPersistence registry cache (capacity == 32).
        let cap = EditPersistence.registryCacheCapacity
        check(cap == 32, "EditPersistence registry cache cap is bounded (\(cap))")
        let lruDirsRoot = dir.appendingPathComponent("registry-lru", isDirectory: true)
        var lruStores: [EditPersistence] = []
        var lruDirs: [URL] = []
        for idx in 0...cap {
            let subDir = lruDirsRoot.appendingPathComponent("store-\(idx)", isDirectory: true)
            let subStore = try EditPersistence(directory: subDir)
            try subStore.save(photos[0], state: PhotoEditState(settings: externalSettings, filmID: ""))
            _ = try subStore.state(for: photos[0])
            lruDirs.append(subDir)
            lruStores.append(subStore)
        }
        let latestReadsBefore = EditPersistence.registryDiskReadCount(forDirectory: lruDirs[cap])
        _ = try lruStores[cap].state(for: photos[0])
        check(EditPersistence.registryDiskReadCount(forDirectory: lruDirs[cap]) == latestReadsBefore,
              "Most recently used directory stays cached inside EditPersistence LRU")
        let oldestReadsBefore = EditPersistence.registryDiskReadCount(forDirectory: lruDirs[0])
        _ = try lruStores[0].state(for: photos[0])
        check(EditPersistence.registryDiskReadCount(forDirectory: lruDirs[0]) == oldestReadsBefore + 1,
              "Oldest directory was evicted once EditPersistence registry cache reached capacity \(cap)")

        // isEditorBusy coalescing: settled previews trigger 0 refreshes; deferred busy refresh triggers 1.
        let busyRevBefore = previews.revision
        previews.isEditorBusy = true
        previews.isEditorBusy = false
        check(previews.revision == busyRevBefore,
              "Settled workspace does not refresh unnecessarily when isEditorBusy toggles")

        let deferredDir = dir.appendingPathComponent("busy-deferred", isDirectory: true)
        try FileManager.default.createDirectory(at: deferredDir, withIntermediateDirectories: true)
        let deferredPhoto = deferredDir.appendingPathComponent("busy.png")
        try writePNG(to: deferredPhoto, red: 0.7)
        let deferredEdits = deferredDir.appendingPathComponent("edits", isDirectory: true)
        let deferredStore = try EditPersistence(directory: deferredEdits)
        try deferredStore.save(deferredPhoto, state: PhotoEditState(settings: externalSettings, filmID: ""))
        let busyPreviews = MacEditedPhotoPreviews(editDirectory: deferredEdits, cacheDirectory: diskCacheDir, thumbnails: PhotoThumbnails())
        var busyTile = WorkspacePhotoTileState()
        busyPreviews.isEditorBusy = true
        let busyStartRev = busyPreviews.revision
        await busyTile.refresh(url: deferredPhoto, previews: busyPreviews)
        check(!busyTile.adjustedThumbnail, "Edited tile skips render while editor is busy")
        busyPreviews.isEditorBusy = false
        check(busyPreviews.revision == busyStartRev + 1,
              "Clearing isEditorBusy triggers one refresh for deferred edited tile")
        await busyTile.refresh(url: deferredPhoto, previews: busyPreviews)
        check(busyTile.adjustedThumbnail, "Deferred edited tile renders after editor becomes idle")

        PhotoThumbnails.shared.invalidateDirectory(root)
    }

    @MainActor
    private static func verifyLUTResourceDigestCacheAndInvalidation(in root: URL) async throws {
        RenderEngine.resetCounts()
        let dir = root.appendingPathComponent("lut-digest-cache", isDirectory: true)
        let editsDir = dir.appendingPathComponent("edits", isDirectory: true)
        let diskCacheDir = dir.appendingPathComponent("disk-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let photo = dir.appendingPathComponent("shot.png")
        try writePNG(to: photo, red: 0.4)
        let lut = dir.appendingPathComponent("look-a.cube")
        try Data("#LUT v1\n0.0 0.0 0.0\n1.0 1.0 1.0\n".utf8).write(to: lut)
        let film = Film(name: "LookA", url: lut, managedID: "look-a")

        let store = try EditPersistence(directory: editsDir)
        let session = AdjustmentTransferSession(store: store)
        let thumbnails = PhotoThumbnails()
        let previews = MacEditedPhotoPreviews(editDirectory: editsDir, cacheDirectory: diskCacheDir, thumbnails: thumbnails)
        previews.films = [film]

        let initialRecord = try await previews.record(for: photo)
        let state = PhotoEditState(settings: Adjustments(), filmID: film.id)
        let outcome = session.commitEdit(expected: initialRecord, state: state)
        check(outcome.status == .applied, "LUT edit committed")
        let editedRecord = outcome.saved!

        // Warm once for the initial LUT file state.
        let plan1 = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        let hashesAfterWarm = MacPhotoPreviewPlan.resourceHashCount

        // Stat fingerprint hit must trigger 0 SHA256 calls across plan, isCurrent, record, cachedImage, and image.
        let plan2 = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        check(plan2.key == plan1.key, "Repeated preview plan produces identical key")
        let planCurrent = try plan2.isCurrent(in: store, films: [film])
        check(planCurrent, "Plan remains current")
        _ = try await previews.record(for: photo)
        _ = try await previews.image(for: editedRecord)
        _ = await previews.cachedImage(for: editedRecord)
        let hashesOnHit = MacPhotoPreviewPlan.resourceHashCount - hashesAfterWarm
        check(hashesOnHit == 0, "Stat fingerprint hit performed \(hashesOnHit) LUT SHA256 hashes (expected 0)")

        // Modifying LUT mtime only must invalidate and re-hash once.
        let futureDate = Date().addingTimeInterval(12)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: lut.path)
        let hashesBeforeMtime = MacPhotoPreviewPlan.resourceHashCount
        let planAfterMtime = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        let hashesOnMtime = MacPhotoPreviewPlan.resourceHashCount - hashesBeforeMtime
        check(hashesOnMtime == 1 && planAfterMtime.key != plan1.key,
              "LUT mtime change re-hashes once (\(hashesOnMtime)) and updates plan key")
        let hashesBeforeMtimeHit = MacPhotoPreviewPlan.resourceHashCount
        _ = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        check(MacPhotoPreviewPlan.resourceHashCount - hashesBeforeMtimeHit == 0,
              "Subsequent plan after mtime update hits cache with 0 SHA256 calls")

        // Replacing LUT with same byte length must invalidate and re-hash once.
        let sameLenA = Data("LUT_CONTENT_0001\n".utf8)
        let sameLenB = Data("LUT_CONTENT_0002\n".utf8)
        try sameLenA.write(to: lut)
        let planSameLenA = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        try sameLenB.write(to: lut)
        let hashesBeforeSameLen = MacPhotoPreviewPlan.resourceHashCount
        let planSameLenB = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        check(MacPhotoPreviewPlan.resourceHashCount - hashesBeforeSameLen == 1 && planSameLenB.key != planSameLenA.key,
              "Same-size LUT content replacement invalidates cache and updates plan key")

        // Modifying LUT size must invalidate and re-hash once.
        try Data("LUT_CONTENT_LONGER_0003\n".utf8).write(to: lut)
        let hashesBeforeSize = MacPhotoPreviewPlan.resourceHashCount
        let planAfterSize = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        check(MacPhotoPreviewPlan.resourceHashCount - hashesBeforeSize == 1 && planAfterSize.key != planSameLenB.key,
              "LUT size change re-hashes once and updates plan key")

        // Deleting LUT invalidates and throws; recreating re-hashes cleanly.
        try FileManager.default.removeItem(at: lut)
        var missingThrew = false
        do { _ = try MacPhotoPreviewPlan(record: editedRecord, films: [film]) }
        catch { missingThrew = true }
        check(missingThrew, "Deleted LUT invalidates cached fingerprint and throws")
        try sameLenA.write(to: lut)
        let hashesBeforeRecreate = MacPhotoPreviewPlan.resourceHashCount
        _ = try MacPhotoPreviewPlan(record: editedRecord, films: [film])
        check(MacPhotoPreviewPlan.resourceHashCount - hashesBeforeRecreate == 1,
              "Recreated LUT re-hashes once")

        // Symlink swap to different target with identical byte count invalidates and re-hashes.
        let targetA = dir.appendingPathComponent("sym-a.cube")
        let targetB = dir.appendingPathComponent("sym-b.cube")
        let symlink = dir.appendingPathComponent("sym-link.cube")
        try Data("SYM_CONTENT_A01\n".utf8).write(to: targetA)
        try Data("SYM_CONTENT_B02\n".utf8).write(to: targetB)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: targetA)
        let symFilm = Film(name: "Sym", url: symlink, managedID: "sym-look")
        let symRecord = PhotoEditRecord(identity: editedRecord.identity, state: PhotoEditState(settings: Adjustments(), filmID: symFilm.id))
        let symPlanA = try MacPhotoPreviewPlan(record: symRecord, films: [symFilm])
        try FileManager.default.removeItem(at: symlink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: targetB)
        let hashesBeforeSymSwap = MacPhotoPreviewPlan.resourceHashCount
        let symPlanB = try MacPhotoPreviewPlan(record: symRecord, films: [symFilm])
        check(MacPhotoPreviewPlan.resourceHashCount - hashesBeforeSymSwap == 1 && symPlanB.key != symPlanA.key,
              "Symlink target swap invalidates cache and changes plan key")

        // HDR look .cube verification + fingerprint share one hash miss and 0 hits afterward.
        let hdrLooksDir = dir.appendingPathComponent("hdr-looks", isDirectory: true)
        try FileManager.default.createDirectory(at: hdrLooksDir, withIntermediateDirectories: true)
        let hdrLUTData = Data("#HDR LUT\n0 0 0\n1 1 1\n".utf8)
        let hdrHex = SHA256.hash(data: hdrLUTData).map { String(format: "%02x", $0) }.joined()
        let hdrLUT = hdrLooksDir.appendingPathComponent("\(hdrHex).cube")
        try hdrLUTData.write(to: hdrLUT)
        var hdrAdjustments = Adjustments()
        var hdrSettings = HDRSettings()
        hdrSettings.mode = .hdr
        hdrSettings.lookSettings = HDRLookSettings(sha256: hdrHex, name: "HDRTest", strength: 1.0)
        hdrAdjustments.hdr = hdrSettings
        let hdrRecord = PhotoEditRecord(identity: editedRecord.identity, state: PhotoEditState(settings: hdrAdjustments, filmID: ""))
        let hdrHashBefore = MacPhotoPreviewPlan.resourceHashCount
        let hdrPlan1 = try MacPhotoPreviewPlan(record: hdrRecord, films: [], hdrLookDirectory: hdrLooksDir)
        check(MacPhotoPreviewPlan.resourceHashCount - hdrHashBefore == 1,
              "Cold HDR preview plan hashes HDR look .cube once (not twice)")
        let hdrHashHitBefore = MacPhotoPreviewPlan.resourceHashCount
        let hdrPlan2 = try MacPhotoPreviewPlan(record: hdrRecord, films: [], hdrLookDirectory: hdrLooksDir)
        check(MacPhotoPreviewPlan.resourceHashCount == hdrHashHitBefore && hdrPlan2.key == hdrPlan1.key,
              "Warm HDR preview plan hits cache with 0 SHA256 calls")
        try Data("#HDR TAMPERED\n".utf8).write(to: hdrLUT)
        var hdrTamperRejected = false
        do { _ = try MacPhotoPreviewPlan(record: hdrRecord, films: [], hdrLookDirectory: hdrLooksDir) }
        catch { hdrTamperRejected = true }
        check(hdrTamperRejected, "Modified HDR look .cube invalidates cache and rejects mismatched hash")

        // Bounded LRU eviction test (small unit instance with cap == 2).
        let smallCache = MacResourceDigestCache(maximumEntries: 2)
        let lru1 = dir.appendingPathComponent("lru-1.cube")
        let lru2 = dir.appendingPathComponent("lru-2.cube")
        let lru3 = dir.appendingPathComponent("lru-3.cube")
        try Data("LUT-1".utf8).write(to: lru1)
        try Data("LUT-2".utf8).write(to: lru2)
        try Data("LUT-3".utf8).write(to: lru3)
        _ = try smallCache.fingerprintDigest(for: lru1)
        _ = try smallCache.fingerprintDigest(for: lru2)
        _ = try smallCache.fingerprintDigest(for: lru1) // lru1 becomes MRU, lru2 becomes LRU
        _ = try smallCache.fingerprintDigest(for: lru3) // evicts lru2
        check(smallCache.entryCount == 2 && smallCache.sha256Count == 3, "Bounded LRU stays capped at maximumEntries == 2")
        _ = try smallCache.fingerprintDigest(for: lru1)
        check(smallCache.sha256Count == 3, "Recently used entry hits without re-hashing")
        _ = try smallCache.fingerprintDigest(for: lru2)
        check(smallCache.sha256Count == 4, "Evicted LRU entry re-hashes on next access")

        // #335 stat guard: concurrent modification during read must never cache stale bytes under old/mismatched stat.
        let unstableCache = MacResourceDigestCache(maximumEntries: 4)
        let racingLUT = dir.appendingPathComponent("racing.cube")
        try Data("V1_INITIAL".utf8).write(to: racingLUT)
        var simulatedAttempts = 0
        let settled = try unstableCache.fingerprintDigest(for: racingLUT, readData: { url in
            simulatedAttempts += 1
            let stale = try Data(contentsOf: url)
            if simulatedAttempts == 1 {
                try Data("V2_FINAL_FINISHED_WRITE".utf8).write(to: url)
            }
            return stale
        })
        check(simulatedAttempts == 2, "Stat mismatch after mid-read mutation triggers clean retry (\(simulatedAttempts))")
        check(settled.digest == Data(SHA256.hash(data: Data("V2_FINAL_FINISHED_WRITE".utf8))),
              "Retry computes digest of finished write instead of caching unfinished bytes")
        let shaBeforeStableHit = unstableCache.sha256Count
        _ = try unstableCache.fingerprintDigest(for: racingLUT)
        check(unstableCache.sha256Count == shaBeforeStableHit, "Only settled post-write digest is cached")

        let alwaysMutatingCache = MacResourceDigestCache(maximumEntries: 4)
        let noisyLUT = dir.appendingPathComponent("noisy.cube")
        var noiseStep = 0
        try Data("NOISE_0".utf8).write(to: noisyLUT)
        _ = try alwaysMutatingCache.fingerprintDigest(for: noisyLUT, readData: { url in
            let data = try Data(contentsOf: url)
            noiseStep += 1
            try Data("NOISE_\(noiseStep)_\(String(repeating: "x", count: noiseStep))".utf8).write(to: url)
            return data
        })
        check(alwaysMutatingCache.entryCount == 0, "Continuously mutating file is never cached with mismatched stat")

        // Production singleton capacity bound check (cap == 128).
        let sharedCap = MacResourceDigestCache.shared.maximumEntries
        check(sharedCap == 128, "Production resource digest cache has finite cap (\(sharedCap))")
        let capDir = dir.appendingPathComponent("shared-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: capDir, withIntermediateDirectories: true)
        for idx in 0..<(sharedCap + 4) {
            let extraLUT = capDir.appendingPathComponent("extra-\(idx).cube")
            try Data("SHARED_LUT_\(idx)".utf8).write(to: extraLUT)
            let extraFilm = Film(name: "Extra\(idx)", url: extraLUT, managedID: "extra-\(idx)")
            let extraRecord = PhotoEditRecord(identity: editedRecord.identity, state: PhotoEditState(settings: Adjustments(), filmID: extraFilm.id))
            _ = try MacPhotoPreviewPlan(record: extraRecord, films: [extraFilm])
        }
        check(MacResourceDigestCache.shared.entryCount <= sharedCap,
              "Shared resource digest cache remains bounded at \(MacResourceDigestCache.shared.entryCount) <= \(sharedCap)")
    }
}
