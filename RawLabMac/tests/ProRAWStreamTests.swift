import Foundation
import ImageIO

@main enum ProRAWStreamTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) {
        do { if try !value() { fatalError(message) } }
        catch { fatalError("\(message): \(error)") }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RawLab-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var session: OpaquePointer?
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Cannot create session")
        defer { sony2fuji_session_destroy(session) }
        for argument in CommandLine.arguments.dropFirst() {
            try autoreleasepool {
                let url = URL(fileURLWithPath: argument)
                let info = try HDRSourceInfo.probeRAW(url)!
                let source = try HDRImage.decode(url, info: info, intent: SONY2FUJI_INTENT_FINAL)
                var settings = HDRSettings()
                settings.exposure = 0.25; settings.temperature = 7300; settings.tint = 8
                settings.contrast = 12; settings.highlights = -15; settings.shadows = 10
                settings.geometry.quarterTurns = 1; settings.geometry.flipHorizontal = true
                settings.geometry.cropX = 0.13; settings.geometry.cropWidth = 0.61
                settings.geometry.cropY = 0.07; settings.geometry.cropHeight = 0.81
                settings.geometry.straightenDegrees = -13.25
                settings.geometry.perspectiveHorizontal = 0.2; settings.geometry.perspectiveVertical = -0.15
                let reference = try source.rendered(session: session!, settings: settings, intent: SONY2FUJI_INTENT_FINAL, longEdge: 1024)
                let expected = directory.appendingPathComponent("reference.jpg")
                try reference.exportJPEG(to: expected)
                let output = directory.appendingPathComponent("stream.jpg")
                let result = try ProRAWExporter.export(url: url, info: info, settings: settings, output: output,
                    longEdge: 1024, keepHDR: true, session: session!, temporaryRoot: scratch)
                let expectedBytes = try Data(contentsOf: expected), outputBytes = try Data(contentsOf: output)
                require(outputBytes == expectedBytes, "Real ProRAW geometry+resize HDR JPEG differs from whole-frame reference")
                require(Int(result.width) == reference.width && Int(result.height) == reference.height &&
                    result.source_headroom == source.sourceHeadroom && result.edited_headroom == reference.editedHeadroom,
                    "Stream source, dimensions or headroom changed")
                require(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "Success leaked scratch files")

                do {
                    _ = try ProRAWExporter.export(url: url, info: info, settings: settings, output: output,
                        keepHDR: true, session: session!, temporaryRoot: scratch, cancelled: { true })
                    fatalError("Cancelled stream was published")
                } catch is CancellationError { }
                require(try Data(contentsOf: output) == outputBytes, "Cancellation replaced existing output")
                do {
                    _ = try ProRAWExporter.export(url: url, info: info, settings: settings, output: scratch,
                        longEdge: 512, keepHDR: true, session: session!, temporaryRoot: scratch)
                    fatalError("Directory destination was published")
                } catch let error as HDRNativeError { require(error.status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR, "Wrong rename failure status") }
                require(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "Failure leaked scratch files")
                let sdr = try ProRAWExporter.export(url: url, info: info, settings: settings, output: output,
                    longEdge: 1024, keepHDR: false, session: session!, temporaryRoot: scratch)
                require(try HDRSourceInfo.probe(output) == nil, "SDR output retained a gain map")
                let imageSource = CGImageSourceCreateWithURL(output as CFURL, nil)!
                let values = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
                let exif = values[kCGImagePropertyExifDictionary] as! NSDictionary
                require(values[kCGImagePropertyPixelWidth] as? Int == Int(sdr.width) &&
                    values[kCGImagePropertyPixelHeight] as? Int == Int(sdr.height) &&
                    values[kCGImagePropertyOrientation] as? Int == 1, "Stream SDR dimensions/orientation differ")
                require(values[kCGImagePropertyProfileName] != nil && exif[kCGImagePropertyExifISOSpeedRatings] != nil &&
                    exif[kCGImagePropertyExifExposureTime] != nil && exif[kCGImagePropertyExifMakerNote] == nil,
                    "Stream SDR lost sRGB profile/shooting EXIF or copied MakerNote")
                require(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "Retry leaked scratch files")
                print("PASS streamed ProRAW \(url.lastPathComponent): exact HDR geometry+resize, EXIF/ICC, cancel, final rename failure, SDR retry")
            }
        }
    }
}
