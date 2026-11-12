import AppKit
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
    static var renderCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _renderCalls
    }
    static func resetCounts() {
        lock.lock(); _renderCalls = 0; lock.unlock()
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
        try await verifyFolderRefreshInvalidation(in: root)

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

        // 2. Commit edit v1 (exposure = +1.0) and signal invalidation as EditorModel.commitAdjustment does.
        var settingsV1 = Adjustments(); settingsV1.exposureMode = .sensor; settingsV1.exposure = 1.0
        let outcomeV1 = session.commitEdit(expected: initialRecord, state: PhotoEditState(settings: settingsV1, filmID: ""))
        check(outcomeV1.status == .applied, "Edit v1 committed")
        thumbnails.invalidateEdited(atPath: outcomeV1.saved!.identity.path)
        previews.refresh()

        // Active unedited presentation must not masquerade as current after edit invalidation.
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

        // 4. Edit again to v2 (exposure = +2.2): v1 must be immediately evicted from NSCache.
        var settingsV2 = settingsV1; settingsV2.exposure = 2.2
        let outcomeV2 = session.commitEdit(expected: recordV1, state: PhotoEditState(settings: settingsV2, filmID: ""))
        check(outcomeV2.status == .applied, "Edit v2 committed")
        thumbnails.invalidateEdited(atPath: outcomeV2.saved!.identity.path)
        previews.refresh()

        check(thumbnails.cachedImage(for: keyV1) == nil, "Edit v2 evicts v1 edited entry from NSCache")
        check(previews.cachedThumbnail(for: photo) == nil, "Edit v2 clears v1 active presentation")
        let staleV1 = await previews.cachedImage(for: recordV1)
        check(staleV1 == nil, "Stale record v1 no longer resolves cached image")

        let recordV2 = try await previews.record(for: photo)
        let planV2 = try MacPhotoPreviewPlan(record: recordV2, films: [])
        let keyV2 = PhotoThumbnailCacheKey(identity: recordV2.identity, previewKey: planV2.key)
        let renderedV2 = try await previews.image(for: recordV2)
        check(RenderEngine.renderCalls == 2, "Edit v2 renders updated preview once")
        check(thumbnails.cachedImage(for: keyV2) === renderedV2, "Edit v2 stored in NSCache")

        // 5. Reset to unmodified: v2 must be evicted; unedited thumbnail remains valid without re-decoding.
        let cleared = try session.resetToUnmodified(photo)
        thumbnails.invalidateEdited(atPath: cleared.identity.path)
        previews.refresh()

        check(thumbnails.cachedImage(for: keyV2) == nil, "Reset evicts edited entry from NSCache")
        check(previews.cachedThumbnail(for: photo) == nil, "Reset clears edited active presentation")

        let recordAfterReset = try await previews.record(for: photo)
        check(!MacPhotoPreviewPlan.isEdited(recordAfterReset), "Record is unedited after reset")
        let restoredOriginal = await previews.originalImage(for: photo, identity: recordAfterReset.identity)
        check(restoredOriginal === uneditedImg && thumbnails.decodeCount == 1,
              "After reset, unedited thumbnail is served from unedited cache entry without re-decoding")
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
        PhotoThumbnails.shared.invalidateDirectory(root)
    }
}
