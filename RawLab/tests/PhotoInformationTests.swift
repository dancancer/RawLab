import Foundation
import ImageIO

@main
struct PhotoInformationTests {
    static func main() {
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
        let info = PhotoInformation(fileName: "original.ARW", properties: properties)
        check(info.lines(for: .hidden).isEmpty, "hidden mode has no overlay lines")
        check(info.lines(for: .file) == ["original.ARW", "2026:10:10 12:34:56", "4000 × 6000"],
              "file mode uses the original name and oriented dimensions")
        let capture = info.lines(for: .capture).joined(separator: " ")
        check(capture.contains("SONY ILCE-7M4") && capture.contains("FE 35mm F1.8"),
              "capture mode reads camera and lens")
        check(capture.contains("1/125 s") && capture.contains("f/2.8") && capture.contains("ISO 400") && capture.contains("35 mm"),
              "capture mode formats photographic values")
        check(PhotoInfoMode.hidden.next == .file && PhotoInfoMode.file.next == .capture && PhotoInfoMode.capture.next == .hidden,
              "info mode cycles hidden, file and capture")
        let missing = PhotoInformation(fileName: "missing.ARW", properties: [:])
        check(missing.lines(for: .capture) == ["missing.ARW", "未读取到拍摄参数"],
              "missing metadata does not invent capture values")
        let rawPreview: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 1616, kCGImagePropertyPixelHeight: 1080,
            kCGImagePropertyOrientation: 8,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifPixelXDimension: 7008,
                kCGImagePropertyExifPixelYDimension: 4672
            ]
        ]
        check(PhotoInformation(fileName: "source.ARW", properties: rawPreview).lines(for: .file).last == "4672 × 7008",
              "RAW dimensions use original EXIF rather than the embedded preview")
        let dngPreview: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 720, kCGImagePropertyPixelHeight: 720,
            kCGImagePropertyDNGDictionary: [kCGImagePropertyDNGDefaultCropSize: [3072, 3072]]
        ]
        check(PhotoInformation(fileName: "source.DNG", properties: dngPreview).lines(for: .file).last == "3072 × 3072",
              "DNG dimensions use the original default crop rather than the embedded preview")
        check(PhotoInformation(fileName: "resized.jpg", properties: rawPreview).lines(for: .file).last == "1080 × 1616",
              "raster dimensions retain the actual encoded size even with stale EXIF")
    }

    private static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
}
