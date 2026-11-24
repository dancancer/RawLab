import CoreGraphics
import Foundation

public final class ViewportTileCache {
    public let byteBudget: Int
    public let maxCount: Int

    public private(set) var tiles: [PhotoDetailTileKey: PhotoDetailOverlay] = [:]
    public private(set) var lru: [PhotoDetailTileKey] = []
    public private(set) var totalBytes: Int = 0
    public private(set) var frameID: UUID?

    public init(byteBudget: Int = 112 * 1024 * 1024, maxCount: Int = 36) {
        self.byteBudget = max(0, byteBudget)
        self.maxCount = max(0, maxCount)
    }

    public static func estimatedBytes(for overlay: PhotoDetailOverlay) -> Int {
        var bytes: Int
        if let cgImage = overlay.cgImage {
            bytes = cgImage.width * cgImage.height * 4
        } else {
            let w = max(0, Int(overlay.pixelSize.width.rounded()))
            let h = max(0, Int(overlay.pixelSize.height.rounded()))
            bytes = w * h * 4
        }
        if let before = overlay.beforeCGImage, before !== overlay.cgImage {
            bytes += before.width * before.height * 4
        }
        return bytes
    }

    @discardableResult
    public func resetIfFrameChanged(_ newFrameID: UUID?) -> Bool {
        guard frameID != newFrameID else { return false }
        tiles.removeAll()
        lru.removeAll()
        totalBytes = 0
        frameID = newFrameID
        return true
    }

    public func touch(_ keys: [PhotoDetailTileKey]) {
        for key in keys where tiles[key] != nil {
            if let idx = lru.firstIndex(of: key) {
                lru.remove(at: idx)
            }
            lru.append(key)
        }
    }

    @discardableResult
    public func store(
        _ overlay: PhotoDetailOverlay,
        keepKeys: Set<PhotoDetailTileKey> = []
    ) -> [PhotoDetailTileKey] {
        _ = resetIfFrameChanged(overlay.renderID)
        guard let key = overlay.tileKey else { return [] }
        if let old = tiles.removeValue(forKey: key) {
            totalBytes = max(0, totalBytes - Self.estimatedBytes(for: old))
        }
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
        }
        tiles[key] = overlay
        lru.append(key)
        totalBytes += Self.estimatedBytes(for: overlay)

        var evictedKeys: [PhotoDetailTileKey] = []
        while (totalBytes > byteBudget || tiles.count > maxCount), !lru.isEmpty {
            let victimIdx = lru.firstIndex(where: { !keepKeys.contains($0) }) ?? 0
            let victim = lru.remove(at: victimIdx)
            if let removed = tiles.removeValue(forKey: victim) {
                totalBytes = max(0, totalBytes - Self.estimatedBytes(for: removed))
                evictedKeys.append(victim)
            }
        }
        return evictedKeys
    }

    public func activeTiles(
        allSpecs: [PhotoDetailTileSpec],
        visibleSpecs: [PhotoDetailTileSpec]
    ) -> [PhotoDetailOverlay] {
        var selected: [PhotoDetailTileKey: PhotoDetailOverlay] = [:]
        for spec in allSpecs {
            if let tile = tiles[spec.key] {
                selected[spec.key] = tile
            }
        }
        let uncachedVisible = visibleSpecs.filter { selected[$0.key] == nil }
        if !uncachedVisible.isEmpty {
            let targetLevel = visibleSpecs.first?.key.level ?? 0
            for (key, tile) in tiles where key.level > targetLevel && selected[key] == nil {
                if uncachedVisible.contains(where: { $0.normalizedRect.intersects(tile.normalizedRect) }) {
                    selected[key] = tile
                }
            }
        }
        return Self.sortedTiles(Array(selected.values))
    }

    public func reclaimMemory() {
        tiles.removeAll()
        lru.removeAll()
        totalBytes = 0
        frameID = nil
    }

    public static func sortedTiles(_ tiles: [PhotoDetailOverlay]) -> [PhotoDetailOverlay] {
        tiles.sorted { a, b in
            let la = a.tileKey?.level ?? 0
            let lb = b.tileKey?.level ?? 0
            if la != lb { return la > lb }
            let ra = a.tileKey?.row ?? 0
            let rb = b.tileKey?.row ?? 0
            if ra != rb { return ra < rb }
            return (a.tileKey?.col ?? 0) < (b.tileKey?.col ?? 0)
        }
    }
}
