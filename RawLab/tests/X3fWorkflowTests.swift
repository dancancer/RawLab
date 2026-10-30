import Foundation
import ImageIO
import UIKit

@main
struct X3fWorkflowTests {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
        fflush(stdout)
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let path = ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"] else {
            throw NSError(domain: "X3FWorkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "RAWLAB_TEST_RAW must name an external X3F"])
        }
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF,
            lensDatabaseURL: root.appendingPathComponent("lutools/third_party/lensfun/version_1"))
        check(sony2fuji_x3f_available() == 1, "normal X3F backend is packaged")
        let normal = RawSettings.default
        var legacy = normal; legacy.x3fMode = .legacy
        let a = try processor.processRaw(url: url, settings: normal, previewLongEdge: 384, lutURL: nil)
        let b = try processor.processRaw(url: url, settings: legacy, previewLongEdge: 384, lutURL: nil)
        let c = try processor.processRaw(url: url, settings: normal, previewLongEdge: 384, lutURL: nil)
        check(a.buffer.data != b.buffer.data && a.buffer.data == c.buffer.data, "normal/legacy/normal cache round trip")
        check(a.buffer.semantic == .display && b.buffer.semantic == .legacy, "normal base buffers retain display semantics")
        check(a.rawWhiteBalance?.temperature == 6500 && a.rawWhiteBalance?.tint == 0, "normal WB uses a relative neutral baseline")
        var lensSwitch = legacy
        lensSwitch.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
        _ = try processor.processRaw(url: url, settings: lensSwitch, previewLongEdge: 384, lutURL: nil)
        lensSwitch.selectX3fMode(.normal)
        let switched = try processor.processRaw(url: url, settings: lensSwitch, previewLongEdge: 384, lutURL: nil)
        check(!lensSwitch.lensSettings.isEnabled && switched.buffer.data == a.buffer.data,
              "legacy with enabled lens correction switches to the normal preview")
        let lensFinal = try processor.processRaw(url: url, settings: lensSwitch, previewLongEdge: nil,
            lutURL: nil, exportLongEdge: 512)
        let lensJPEG = try processor.makeJPEGData(from: lensFinal.buffer, sourceURL: url, orientation: .up, quality: 0.95)
        check(CGImageSourceCreateWithData(lensJPEG as CFData, nil) != nil,
              "normal export succeeds after disabling legacy lens correction")
        let display = try processor.processBuffer(buffer: a.buffer, settings: normal, previewLongEdge: 384, lutURL: nil)
        let delta = zip(display.data, a.buffer.data).map { abs(Int($0) - Int($1)) }.max() ?? 0
        check(display.width == a.buffer.width && display.height == a.buffer.height && delta <= 1, "neutral display reprocessing does not apply a second scene tone curve")
        var custom = normal; custom.whiteBalanceMode = .custom; custom.temperature = 4800; custom.tint = 12; custom.exposure = 0.5
        let edited = try processor.processRaw(url: url, settings: custom, previewLongEdge: 384, lutURL: nil)
        check(edited.buffer.data != a.buffer.data, "relative WB and exposure change normal pixels")
        let ev = try processor.autoExposure(url: url, buffer: nil, settings: normal)
        check(ev.isFinite, "normal auto exposure returns a finite result")
        let sample = try processor.sampleHSL(url: url, buffer: nil, settings: normal, previewLongEdge: 384,
            lutURL: nil, interactive: false, revision: HSLTargetRevision(source: 1, request: 1), point: CGPoint(x: 0.5, y: 0.5))
        check(sample.availability != .failed, "normal HSL probe reaches the same renderer")
        let final = try processor.processRaw(url: url, settings: custom, previewLongEdge: nil, lutURL: nil, exportLongEdge: 512)
        let jpeg = try processor.makeJPEGData(from: final.buffer, sourceURL: url, orientation: .up, quality: 0.95)
        let destination = output.appendingPathComponent("x3f-edited.jpg")
        try jpeg.write(to: destination)
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        check(max(properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int) == 512,
              "JPEG export succeeds with valid dimensions when ImageIO cannot read X3F capture EXIF")
        try processor.exportDNG(url: url, settings: custom, lutURL: nil,
            outputURL: output.appendingPathComponent("x3f-edited.dng"), exportLongEdge: 512)
        var unsupported = normal; unsupported.lensCorrection = LensCorrectionSettings(distortion: true)
        do {
            _ = try processor.processRaw(url: url, settings: unsupported, previewLongEdge: 128, lutURL: nil)
            check(false, "unsupported normal lens correction must reject")
        } catch {
            check(error.localizedDescription.lowercased().contains("lens"), "unsupported normal controls retain an actionable X3F error")
        }
        let recovered = try processor.processRaw(url: url, settings: legacy, previewLongEdge: 384, lutURL: nil)
        check(recovered.buffer.data == b.buffer.data, "explicit legacy mode recovers after an incompatible normal request")
        check(try Data(contentsOf: url) == original, "original X3F bytes are unchanged")
        print("PASS: iOS X3F workflow \(url.lastPathComponent)")
    }
}
