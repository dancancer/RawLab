import CoreGraphics
import Foundation
import ImageIO
import UIKit

// =========================================================================
// Immutable as-shot metadata, independent of the current render settings.
// =========================================================================
final class RecipeWhiteBalanceCache {
    private struct Key: Equatable {
        let url: URL
        let size: Int
        let modified: Date
        let fileNumber: NSNumber?
        let processing: ProcessingIdentity
        let x3fMode: X3fMode
    }

    private let lock = NSLock()
    private var key: Key?
    private var camera: Sony2FujiProcessor.RawWhiteBalance?

    func resolve(url: URL, processing: ProcessingIdentity = .current, x3fMode: X3fMode = .normal,
                 load: () throws -> Sony2FujiProcessor.RawWhiteBalance) throws -> Sony2FujiProcessor.RawWhiteBalance {
        lock.lock()
        defer { lock.unlock() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue,
              let modified = attributes?[.modificationDate] as? Date else {
            key = nil
            camera = nil
            return try load()
        }
        let next = Key(url: url.standardizedFileURL, size: size, modified: modified,
                       fileNumber: attributes?[.systemFileNumber] as? NSNumber, processing: processing, x3fMode: x3fMode)
        if key == next, let camera { return camera }
        let loaded = try load()
        key = next
        camera = loaded
        return loaded
    }
}
