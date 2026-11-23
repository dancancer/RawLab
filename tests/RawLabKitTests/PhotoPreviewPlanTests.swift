import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import RawLabKit

final class PhotoPreviewPlanTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoPreviewPlanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func testResolveHDRResourcesAndFailClosedValidation() throws {
        let looksDir = temporaryRoot.appendingPathComponent("HDRLooks", isDirectory: true)
        let profilesDir = temporaryRoot.appendingPathComponent("Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: looksDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)

        let lookData = Data("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n".utf8)
        let lookSHA = SHA256.hash(data: lookData).map { String(format: "%02x", $0) }.joined()
        let lookURL = looksDir.appendingPathComponent("\(lookSHA).cube")
        try lookData.write(to: lookURL)

        let profileData = Data("profile-bytes".utf8)
        let profileSHA = SHA256.hash(data: profileData).map { String(format: "%02x", $0) }.joined()
        let profileURL = profilesDir.appendingPathComponent("\(profileSHA).dcp")
        try profileData.write(to: profileURL)

        var hdr = HDRSettings()
        hdr.mode = .hdr
        hdr.lookSettings = HDRLookSettings(sha256: lookSHA, name: "HDRLook", strength: 1)
        hdr.cameraDevelopmentSettings.cameraProfile = HDRCameraProfile(sha256: profileSHA, name: "Camera")

        let specs = try PhotoPreviewPlan.resolveHDRResourceSpecs(
            hdr: hdr,
            hdrLookDirectory: looksDir,
            profileURLProvider: { profilesDir.appendingPathComponent("\($0.sha256).dcp") }
        )
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].url, lookURL)
        XCTAssertEqual(specs[0].maximumBytes, PhotoPreviewPlan.hdrLookMaximumBytes)
        XCTAssertTrue(specs[0].missingFileOnFailure)
        XCTAssertEqual(specs[1].url, profileURL)

        let digestCache = FileDigestCache(maximumEntries: 16)
        let evaluated = try PhotoPreviewPlan.evaluateResources(specs, includeFileIdentity: true, digestCache: digestCache)
        XCTAssertEqual(evaluated.requirements.count, 2)
        XCTAssertTrue(try PhotoPreviewPlan.areResourcesCurrent(evaluated.requirements, digestCache: digestCache))

        // Tampering the HDR look file must fail closed with CocoaError(.fileNoSuchFile).
        try Data("tampered".utf8).write(to: lookURL)
        XCTAssertThrowsError(try PhotoPreviewPlan.evaluateResources(specs, includeFileIdentity: false, digestCache: digestCache)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
        XCTAssertThrowsError(try PhotoPreviewPlan.areResourcesCurrent(evaluated.requirements, digestCache: digestCache)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
    }

    func testRegularResourceRewriteMarksPlanNonCurrent() throws {
        let lutURL = temporaryRoot.appendingPathComponent("film.cube")
        try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: lutURL)

        let digestCache = FileDigestCache(maximumEntries: 8)
        let evaluated = try PhotoPreviewPlan.evaluateResources(
            [PhotoPreviewResourceSpec(url: lutURL)],
            includeFileIdentity: false,
            digestCache: digestCache
        )
        XCTAssertTrue(try PhotoPreviewPlan.areResourcesCurrent(evaluated.requirements, digestCache: digestCache))

        try Data("LUT_3D_SIZE 2\n1 1 1\n".utf8).write(to: lutURL)
        XCTAssertFalse(try PhotoPreviewPlan.areResourcesCurrent(evaluated.requirements, digestCache: digestCache))
    }

    func testThumbnailCodecScalesAndDecodesPNGAndJPEG() throws {
        let image = try makeSolidImage(width: 400, height: 200)

        let pngData = try PhotoPreviewThumbnailCodec.encodeThumbnail(image, maxEdge: 100, format: .png)
        let decodedPNG = try XCTUnwrap(PhotoPreviewThumbnailCodec.decodeCGImage(pngData))
        XCTAssertEqual(decodedPNG.width, 100)
        XCTAssertEqual(decodedPNG.height, 50)

        let jpegData = try PhotoPreviewThumbnailCodec.encodeThumbnail(image, maxEdge: 80, format: .jpeg(quality: 0.86))
        let decodedJPEG = try XCTUnwrap(PhotoPreviewThumbnailCodec.decodeCGImage(jpegData))
        XCTAssertEqual(decodedJPEG.width, 80)
        XCTAssertEqual(decodedJPEG.height, 40)

        XCTAssertNil(PhotoPreviewThumbnailCodec.decodeCGImage(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    func testCoordinatorDoubleCheckedCurrencyAndCacheLifecycle() throws {
        let cacheDir = temporaryRoot.appendingPathComponent("preview-cache", isDirectory: true)
        let cache = EditedPhotoPreviewCache(directory: cacheDir)
        let key = PhotoPreviewCacheKey(identity: Data("id".utf8), adjustments: Data("adj".utf8), edge: 128)
        let sample = try makeSolidImage(width: 64, height: 32)

        var current = true
        var renders = 0
        var hits = 0
        var missWrites = 0

        let first = try EditedPhotoPreviewCoordinator.loadOrRenderThumbnail(
            cache: cache,
            makePlan: { key },
            isCurrent: { _ in current },
            key: { $0 },
            render: { _ in
                renders += 1
                return sample
            },
            encode: { try PhotoPreviewThumbnailCodec.encodeThumbnail($0, maxEdge: 64, format: .png) },
            onCacheHit: { hits += 1 },
            onCacheMissWrite: { _, _ in missWrites += 1 }
        )
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(missWrites, 1)
        XCTAssertEqual(hits, 0)
        XCTAssertNotNil(first.cgImage)

        let second = try EditedPhotoPreviewCoordinator.loadOrRenderThumbnail(
            cache: cache,
            makePlan: { key },
            isCurrent: { _ in current },
            key: { $0 },
            render: { _ in
                renders += 1
                return sample
            },
            encode: { try PhotoPreviewThumbnailCodec.encodeThumbnail($0, maxEdge: 64, format: .png) },
            onCacheHit: { hits += 1 },
            onCacheMissWrite: { _, _ in missWrites += 1 }
        )
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(hits, 1)
        XCTAssertNil(second.cgImage)
        XCTAssertEqual(second.data, first.data)

        // Becoming stale mid-render must throw AdjustmentCommitError.expired without overwriting cache.
        current = false
        let staleKey = PhotoPreviewCacheKey(identity: Data("id2".utf8), adjustments: Data("adj2".utf8), edge: 128)
        XCTAssertThrowsError(try EditedPhotoPreviewCoordinator.loadOrRenderThumbnail(
            cache: cache,
            makePlan: { staleKey },
            isCurrent: { _ in current },
            key: { $0 },
            render: { _ in sample },
            encode: { try PhotoPreviewThumbnailCodec.encodeThumbnail($0, maxEdge: 64, format: .png) }
        )) { error in
            XCTAssertEqual(error as? AdjustmentCommitError, .expired)
        }
        XCTAssertNil(try cache.read(staleKey))

        XCTAssertThrowsError(try EditedPhotoPreviewCoordinator.acceptThumbnail(
            cache: cache,
            makePlan: { staleKey },
            isCurrent: { _ in current },
            key: { $0 },
            encode: { try PhotoPreviewThumbnailCodec.encodeThumbnail(sample, maxEdge: 64, format: .png) }
        )) { error in
            XCTAssertEqual(error as? AdjustmentCommitError, .expired)
        }
    }
}
