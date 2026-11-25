import CoreGraphics
import Foundation
import XCTest
@testable import RawLabKit

final class ViewportTileCacheTests: XCTestCase {
    private func makeTile(
        frameID: UUID,
        level: Int = 0,
        col: Int,
        row: Int,
        width: Int = 10,
        height: Int = 10,
        rect: CGRect = CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
    ) -> PhotoDetailOverlay {
        PhotoDetailOverlay(
            cgImage: nil,
            beforeCGImage: nil,
            hdr: nil,
            beforeHDR: nil,
            normalizedRect: rect,
            pixelSize: CGSize(width: width, height: height),
            fullNativeSize: CGSize(width: 4000, height: 3000),
            renderID: frameID,
            tileKey: PhotoDetailTileKey(level: level, col: col, row: row)
        )
    }

    func testByteBudgetAndMaxCountLRUEviction() {
        let frameID = UUID()
        // 10x10 RGBA = 400 bytes per tile; budget 1000 fits 2 tiles, maxCount 5.
        let byteCache = ViewportTileCache(byteBudget: 1000, maxCount: 5)
        let k0 = PhotoDetailTileKey(level: 0, col: 0, row: 0)
        let k1 = PhotoDetailTileKey(level: 0, col: 1, row: 0)
        let k2 = PhotoDetailTileKey(level: 0, col: 2, row: 0)

        XCTAssertEqual(byteCache.store(makeTile(frameID: frameID, col: 0, row: 0)), [])
        XCTAssertEqual(byteCache.store(makeTile(frameID: frameID, col: 1, row: 0)), [])
        XCTAssertEqual(byteCache.totalBytes, 800)

        let evicted = byteCache.store(makeTile(frameID: frameID, col: 2, row: 0))
        XCTAssertEqual(evicted, [k0])
        XCTAssertNil(byteCache.tiles[k0])
        XCTAssertNotNil(byteCache.tiles[k1])
        XCTAssertNotNil(byteCache.tiles[k2])
        XCTAssertEqual(byteCache.totalBytes, 800)

        // maxCount eviction when byte budget has plenty of headroom
        let countCache = ViewportTileCache(byteBudget: 1_000_000, maxCount: 2)
        countCache.store(makeTile(frameID: frameID, col: 0, row: 0))
        countCache.store(makeTile(frameID: frameID, col: 1, row: 0))
        let countEvicted = countCache.store(makeTile(frameID: frameID, col: 2, row: 0))
        XCTAssertEqual(countEvicted, [k0])
        XCTAssertEqual(countCache.tiles.count, 2)
    }

    func testTouchRecencyAndKeepKeysProtection() {
        let frameID = UUID()
        let cache = ViewportTileCache(byteBudget: 800, maxCount: 2)
        let k0 = PhotoDetailTileKey(level: 0, col: 0, row: 0)
        let k1 = PhotoDetailTileKey(level: 0, col: 1, row: 0)
        let k2 = PhotoDetailTileKey(level: 0, col: 2, row: 0)

        cache.store(makeTile(frameID: frameID, col: 0, row: 0))
        cache.store(makeTile(frameID: frameID, col: 1, row: 0))
        cache.touch([k0]) // k1 is now the LRU victim

        let evictedAfterTouch = cache.store(makeTile(frameID: frameID, col: 2, row: 0))
        XCTAssertEqual(evictedAfterTouch, [k1])
        XCTAssertNotNil(cache.tiles[k0])

        // Protect k0 via keepKeys even though k0 is now older than k2
        let k3 = PhotoDetailTileKey(level: 0, col: 3, row: 0)
        let evictedProtected = cache.store(makeTile(frameID: frameID, col: 3, row: 0), keepKeys: [k0])
        XCTAssertEqual(evictedProtected, [k2])
        XCTAssertNotNil(cache.tiles[k0])
        XCTAssertNotNil(cache.tiles[k3])
    }

    func testFrameIDChangeAndReclaimMemoryClearCache() {
        let frameA = UUID()
        let frameB = UUID()
        let cache = ViewportTileCache(byteBudget: 100_000, maxCount: 10)
        let k0 = PhotoDetailTileKey(level: 0, col: 0, row: 0)

        cache.store(makeTile(frameID: frameA, col: 0, row: 0))
        XCTAssertEqual(cache.frameID, frameA)
        XCTAssertEqual(cache.totalBytes, 400)

        // Storing a tile for a new frame invalidates previous frame's tiles automatically
        let k1 = PhotoDetailTileKey(level: 0, col: 1, row: 0)
        cache.store(makeTile(frameID: frameB, col: 1, row: 0))
        XCTAssertEqual(cache.frameID, frameB)
        XCTAssertNil(cache.tiles[k0])
        XCTAssertNotNil(cache.tiles[k1])
        XCTAssertEqual(cache.totalBytes, 400)

        cache.reclaimMemory()
        XCTAssertTrue(cache.tiles.isEmpty)
        XCTAssertTrue(cache.lru.isEmpty)
        XCTAssertEqual(cache.totalBytes, 0)
        XCTAssertNil(cache.frameID)
    }

    func testActiveTilesFallbackToCoarserCachedLevel() {
        let frameID = UUID()
        let cache = ViewportTileCache(byteBudget: 100_000, maxCount: 10)
        let coarseIntersecting = makeTile(
            frameID: frameID, level: 1, col: 0, row: 0,
            rect: CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        )
        let coarseDisjoint = makeTile(
            frameID: frameID, level: 1, col: 1, row: 1,
            rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        )
        let fineCached = makeTile(
            frameID: frameID, level: 0, col: 0, row: 0,
            rect: CGRect(x: 0.0, y: 0.0, width: 0.25, height: 0.25)
        )
        cache.store(coarseIntersecting)
        cache.store(coarseDisjoint)
        cache.store(fineCached)

        let specCached = PhotoDetailTileSpec(
            key: PhotoDetailTileKey(level: 0, col: 0, row: 0),
            normalizedRect: CGRect(x: 0.0, y: 0.0, width: 0.25, height: 0.25),
            maxOutputLongEdge: 1024
        )
        let specMissing = PhotoDetailTileSpec(
            key: PhotoDetailTileKey(level: 0, col: 1, row: 0),
            normalizedRect: CGRect(x: 0.25, y: 0.0, width: 0.25, height: 0.25),
            maxOutputLongEdge: 1024
        )
        let active = cache.activeTiles(allSpecs: [specCached, specMissing], visibleSpecs: [specCached, specMissing])
        XCTAssertEqual(active.compactMap(\.tileKey), [
            coarseIntersecting.tileKey!,
            fineCached.tileKey!,
        ])
    }
}
