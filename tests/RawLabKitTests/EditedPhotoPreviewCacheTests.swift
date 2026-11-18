import Foundation
import XCTest
@testable import RawLabKit

final class EditedPhotoPreviewCacheTests: XCTestCase {
    private func key(_ identity: String = "photo-a", _ settings: String = "exposure=1", _ resources: String = "look-v1", _ edge: Int = 256) -> PhotoPreviewCacheKey {
        PhotoPreviewCacheKey(identity: Data(identity.utf8), adjustments: Data(settings.utf8), resources: Data(resources.utf8), edge: edge)
    }

    private func jpegShell(_ payload: [UInt8]) -> Data {
        Data([0xFF, 0xD8] + payload + [0xFF, 0xD9])
    }

    private func pngShell(payloadBytes: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(repeating: 0x42, count: payloadBytes))
        data.append(Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]))
        return data
    }

    private func previewFile(_ base: URL, _ key: PhotoPreviewCacheKey) -> URL {
        base.appendingPathComponent(key.digest).appendingPathExtension("preview")
    }

    func testCacheKeysEvictionIOAndTruncationSelfHealing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(key(), key())
        XCTAssertNotEqual(key(), key("photo-b"))
        XCTAssertNotEqual(key(), key("photo-a", "exposure=0"))
        XCTAssertNotEqual(key(), key("photo-a", "exposure=1", "look-v2"))
        XCTAssertNotEqual(key(), key("photo-a", "exposure=1", "look-v1", 512))
        XCTAssertNotEqual(key("ab", "c"), key("a", "bc"))
        XCTAssertNotEqual(
            PhotoPreviewCacheKey(identity: Data(), adjustments: Data(), edge: 256, rendererVersion: "v1"),
            PhotoPreviewCacheKey(identity: Data(), adjustments: Data(), edge: 256, rendererVersion: "v2")
        )

        let cache = EditedPhotoPreviewCache(directory: directory, maximumEntries: 2, maximumBytes: 16)
        XCTAssertNil(try cache.read(key()))
        try cache.write(jpegShell([1, 2, 3]), for: key())
        let reopened = EditedPhotoPreviewCache(directory: directory, maximumEntries: 2, maximumBytes: 16)
        XCTAssertEqual(try reopened.read(key()), jpegShell([1, 2, 3]))
        XCTAssertNil(try reopened.read(key("photo-a", "exposure=0")))

        try cache.write(jpegShell([4, 5]), for: key("photo-b"))
        try cache.write(jpegShell([6]), for: key("photo-c"))
        XCTAssertEqual(try cache.read(key("photo-c")), jpegShell([6]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".preview") }.count, 2)

        try cache.write(jpegShell(Array(repeating: 7, count: 12)), for: key("photo-d"))
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try urls.reduce(0) { total, url in total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 16)

        try cache.write(jpegShell(Array(repeating: 8, count: 17)), for: key("photo-e"))
        XCTAssertNil(try cache.read(key("photo-e")))

        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        XCTAssertThrowsError(try EditedPhotoPreviewCache(directory: blocked).write(Data([2]), for: key()))

        let ioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ioDirectory) }
        var scan = 0, plainWrite = 0, atomicWrite = 0, renameCount = 0
        let io = EditedPhotoPreviewCache(directory: ioDirectory, maximumEntries: 8, maximumBytes: 1 << 20)
        io.observeFileOperation = { operation in
            switch operation {
            case .scan: scan += 1
            case .plainWrite: plainWrite += 1
            case .atomicWrite: atomicWrite += 1
            case .rename: renameCount += 1
            }
        }
        for index in 0..<5 {
            try io.write(jpegShell(Array(repeating: UInt8(index), count: 4)), for: key("photo-\(index)"))
        }
        _ = try io.read(key("photo-2"))
        try io.write(jpegShell([9]), for: key("photo-1"))
        XCTAssertEqual(scan, 1)
        XCTAssertEqual(plainWrite, 6)
        XCTAssertEqual(renameCount, 6)
        XCTAssertEqual(atomicWrite, 0)

        let lruDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lruDirectory) }
        let lru = EditedPhotoPreviewCache(directory: lruDirectory, maximumEntries: 2, maximumBytes: 1 << 20)
        try lru.write(jpegShell([1]), for: key("lru-a"))
        try lru.write(jpegShell([2]), for: key("lru-b"))
        _ = try lru.read(key("lru-a"))
        try lru.write(jpegShell([3]), for: key("lru-c"))
        XCTAssertNotNil(try lru.read(key("lru-a")))
        XCTAssertNotNil(try lru.read(key("lru-c")))
        XCTAssertNil(try lru.read(key("lru-b")))

        let b1Directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: b1Directory) }
        func freshB1() -> EditedPhotoPreviewCache {
            EditedPhotoPreviewCache(directory: b1Directory, maximumEntries: 8, maximumBytes: 1 << 20)
        }
        let truncatedPngKey = key("b1-png")
        try freshB1().write(pngShell(payloadBytes: 40), for: truncatedPngKey)
        let truncatedPngFile = previewFile(b1Directory, truncatedPngKey)
        try Data(pngShell(payloadBytes: 40).dropLast(12)).write(to: truncatedPngFile)
        let afterPngTruncation = freshB1()
        XCTAssertNil(try afterPngTruncation.read(truncatedPngKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: truncatedPngFile.path))
        try afterPngTruncation.write(pngShell(payloadBytes: 40), for: truncatedPngKey)
        XCTAssertEqual(try afterPngTruncation.read(truncatedPngKey), pngShell(payloadBytes: 40))

        let truncatedJpegKey = key("b1-jpeg")
        try afterPngTruncation.write(jpegShell([1, 2, 3, 4]), for: truncatedJpegKey)
        try Data(jpegShell([1, 2, 3, 4]).dropLast(1)).write(to: previewFile(b1Directory, truncatedJpegKey))
        let afterJpegTruncation = freshB1()
        XCTAssertNil(try afterJpegTruncation.read(truncatedJpegKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewFile(b1Directory, truncatedJpegKey).path))
    }
}
