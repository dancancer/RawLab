import Foundation
import ImageIO
import XCTest
@testable import RawLabKit

final class PhotoInformationTests: XCTestCase {
    func testPhotoInformationFormattingRoundingAndRawDimensions() {
        let properties: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 6000,
            kCGImagePropertyPixelHeight: 4000,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SONY",
                kCGImagePropertyTIFFModel: "ILCE-7M4"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:10 12:34:56",
                kCGImagePropertyExifExposureTime: 0.008,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 35,
                kCGImagePropertyExifLensModel: "FE 35mm F1.8"
            ]
        ]

        let info = PhotoInformation(fileName: "photo.ARW", properties: properties)
        XCTAssertTrue(info.lines(for: .hidden).isEmpty)
        XCTAssertEqual(info.lines(for: .file), ["photo.ARW", "2026:10:10 12:34:56", "4000 × 6000"])
        let capture = info.lines(for: .capture).joined(separator: " ")
        XCTAssertTrue(capture.contains("SONY ILCE-7M4") && capture.contains("FE 35mm F1.8"))
        XCTAssertTrue(capture.contains("1/125 s") && capture.contains("f/2.8") && capture.contains("ISO 400") && capture.contains("35 mm"))
        XCTAssertEqual(PhotoInfoMode.hidden.next, .file)
        XCTAssertEqual(PhotoInfoMode.file.next, .capture)
        XCTAssertEqual(PhotoInfoMode.capture.next, .hidden)

        let precise = PhotoInformation(fileName: "photo.ARW", properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 1.234567,
                kCGImagePropertyExifFNumber: 2.345678,
                kCGImagePropertyExifISOSpeedRatings: [400.123456],
                kCGImagePropertyExifFocalLength: 35.6789
            ]
        ])
        let preciseText = precise.lines(for: .capture).joined(separator: " ")
        XCTAssertTrue(preciseText.contains("1.23 s"))
        XCTAssertTrue(preciseText.contains("f/2.35"))
        XCTAssertTrue(preciseText.contains("ISO 400.12"))
        XCTAssertTrue(preciseText.contains("35.68 mm"))

        let missing = PhotoInformation.read(URL(fileURLWithPath: "/missing/no-exif.ARW"))
        XCTAssertEqual(missing.lines(for: .capture).count, 2)
        XCTAssertFalse(missing.lines(for: .capture).joined().contains("6500"))

        let missingInline = PhotoInformation(fileName: "missing.ARW", properties: [:])
        XCTAssertEqual(missingInline.lines(for: .capture), ["missing.ARW", "未读取到拍摄参数"])

        let rawPreview: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 1616,
            kCGImagePropertyPixelHeight: 1080,
            kCGImagePropertyOrientation: 8,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifPixelXDimension: 7008,
                kCGImagePropertyExifPixelYDimension: 4672
            ]
        ]
        XCTAssertEqual(PhotoInformation(fileName: "source.ARW", properties: rawPreview).lines(for: .file).last, "4672 × 7008")

        let dngPreview: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 720,
            kCGImagePropertyPixelHeight: 720,
            kCGImagePropertyDNGDictionary: [kCGImagePropertyDNGDefaultCropSize: [3072, 3072]]
        ]
        XCTAssertEqual(PhotoInformation(fileName: "source.DNG", properties: dngPreview).lines(for: .file).last, "3072 × 3072")
        XCTAssertEqual(PhotoInformation(fileName: "resized.jpg", properties: rawPreview).lines(for: .file).last, "1080 × 1616")
    }
}
