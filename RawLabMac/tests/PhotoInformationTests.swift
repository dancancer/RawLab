import Foundation
import ImageIO

@main struct PhotoInformationTests {
    static func main() throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: \(message)") }
        let properties: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 6000, kCGImagePropertyPixelHeight: 4000,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7M4"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 12:34:56",
                kCGImagePropertyExifExposureTime: 0.008, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 35,
                kCGImagePropertyExifLensModel: "FE 35mm F1.8"]
        ]
        let info = PhotoInformation(fileName: "photo.ARW", properties: properties)
        check(info.lines(for: .hidden).isEmpty, "Hidden overlay has no content")
        check(info.lines(for: .file) == ["photo.ARW", "2026:10:10 12:34:56", "4000 × 6000"], "File overlay uses capture date and oriented source dimensions")
        let lines = info.lines(for: .capture).joined(separator: " ")
        check(lines.contains("SONY ILCE-7M4") && lines.contains("FE 35mm F1.8"), "Capture overlay reads camera and lens")
        check(lines.contains("1/125 s") && lines.contains("f/2.8") && lines.contains("ISO 400") && lines.contains("35 mm"), "Capture values use photographic units")
        check(PhotoInfoMode.hidden.next == .file && PhotoInfoMode.file.next == .capture && PhotoInfoMode.capture.next == .hidden, "Info action cycles all three modes")
        let missing = PhotoInformation.read(URL(fileURLWithPath: "/missing/no-exif.ARW"))
        check(missing.lines(for: .capture).count == 2 && !missing.lines(for: .capture).joined().contains("6500"), "Missing metadata does not invent capture values")
    }
}
