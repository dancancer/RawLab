import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

@main
struct MacStraightenPreviewTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct PreviewCase {
        let name: String
        let geometry: GeometrySettings
        let pan: CGSize
    }

    struct Evidence: Codable {
        let fixture: String
        let name: String
        let angle: Double
        let quarterTurns: Int
        let flipHorizontal: Bool
        let flipVertical: Bool
        let perspectiveHorizontal: Double
        let perspectiveVertical: Double
        let baseNativeWidth: Int
        let baseNativeHeight: Int
        let safeWidth: Int
        let safeHeight: Int
        let coreSafeWidth: Int
        let coreSafeHeight: Int
        let finalNativeWidth: Int
        let finalNativeHeight: Int
        let capturedCropWidth: Int
        let capturedCropHeight: Int
        let meanAbsoluteError: Double
        let maximumChannelError: Int
        let actualPNG: String
        let expectedPNG: String
    }

    private enum CaptureMode {
        case pending
        case activeOverlay
        case plain
    }

    static func main() throws {
        setbuf(stdout, nil)
        do {
            try run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let raw = URL(fileURLWithPath: arguments.first ??
            "lutools/examples/DJI_20250602164503_0444_D.DNG")
        let output = URL(fileURLWithPath: arguments.dropFirst().first ??
            "build/native-acceptance/straighten-presentation", isDirectory: true)
        guard FileManager.default.fileExists(atPath: raw.path) else {
            throw Failure(description: "Missing RAW fixture: \(raw.path)")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        var evidence: [Evidence] = []
        let fixtures = try StraightenPreviewFixtures.make(from: raw, engine: engine,
                                                         in: output.appendingPathComponent("fixtures"))
        for input in [raw] + fixtures {
            let destination = output.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            print("Fixture: \(input.lastPathComponent) (CPU)")
            for previewCase in cases() {
                evidence.append(try check(previewCase, raw: input, output: destination, engine: engine))
            }
            try activeOverlayCheck(raw: input, output: destination, engine: engine)
        }

        let report = try JSONEncoder().encode(evidence)
        try report.write(to: output.appendingPathComponent("report.json"))
        print("PASS: \(evidence.count) offscreen straighten presentation checks")
        print("Artifacts: \(output.path)")
    }

    private static func cases() -> [PreviewCase] {
        func make(_ name: String, _ angle: Double, _ quarterTurns: Int = 0,
                  _ horizontal: Bool = false, _ vertical: Bool = false,
                  _ perspectiveHorizontal: Double = 0, _ perspectiveVertical: Double = 0,
                  _ crop: (Double, Double, Double, Double), pan: CGSize = .zero) -> PreviewCase {
            var geometry = GeometrySettings()
            geometry.straightenDegrees = angle
            geometry.quarterTurns = quarterTurns
            geometry.flipHorizontal = horizontal
            geometry.flipVertical = vertical
            geometry.perspectiveHorizontal = perspectiveHorizontal
            geometry.perspectiveVertical = perspectiveVertical
            geometry.cropX = crop.0
            geometry.cropY = crop.1
            geometry.cropWidth = crop.2
            geometry.cropHeight = crop.3
            return PreviewCase(name: name, geometry: geometry, pan: pan)
        }

        return [
            make("q0-positive", 7.5, 0, false, false, 0, 0, (0.10, 0.12, 0.72, 0.68)),
            make("q0-negative", -22.5, 0, false, false, 0, 0, (0.05, 0.08, 0.86, 0.80)),
            make("q0-angle45-hflip", 45, 0, true, false, 0, 0, (0.14, 0.10, 0.64, 0.72),
                 pan: CGSize(width: 60, height: 0)),
            make("q0-angle45-hflip-negative-pan", 45, 0, true, false, 0, 0, (0.14, 0.10, 0.64, 0.72),
                 pan: CGSize(width: -60, height: -60)),
            make("q1-negative-vflip", -7.5, 1, false, true, 0, 0, (0.08, 0.16, 0.70, 0.62)),
            make("q3-positive-both-flips", 22.5, 3, true, true, 0, 0, (0.18, 0.12, 0.60, 0.68)),
            make("q1-perspective-horizontal", -45, 1, false, false, 0.30, 0,
                 (0.12, 0.10, 0.68, 0.70)),
            make("q3-perspective-vertical", 3, 3, false, false, 0, -0.25,
                 (0.08, 0.20, 0.78, 0.60)),
            make("q0-perspective-both", -22.5, 0, false, false, 0.35, -0.22,
                 (0.20, 0.15, 0.65, 0.70))
        ]
    }

    @MainActor
    private static func check(_ previewCase: PreviewCase, raw: URL, output: URL,
                              engine: RenderEngine) throws -> Evidence {
        let geometry = previewCase.geometry
        let baseGeometry = previewGeometry(for: geometry)
        var baseSettings = Adjustments()
        baseSettings.geometry = baseGeometry.isIdentity ? nil : baseGeometry
        let base = try require(engine.render(raw, settings: baseSettings, lut: nil, edge: 600,
                                             viewportPreview: true),
                               "base render \(previewCase.name)")

        var fullSettings = Adjustments()
        var fullGeometry = geometry
        fullGeometry.cropX = 0; fullGeometry.cropY = 0
        fullGeometry.cropWidth = 1; fullGeometry.cropHeight = 1
        fullSettings.geometry = fullGeometry.isIdentity ? nil : fullGeometry
        let coreSafe = try require(engine.render(raw, settings: fullSettings, lut: nil, edge: 600),
                                    "Core safe render \(previewCase.name)")

        var finalSettings = Adjustments()
        finalSettings.geometry = geometry.isIdentity ? nil : geometry
        let expected = try require(engine.render(raw, settings: finalSettings, lut: nil, edge: 600),
                                    "Core final render \(previewCase.name)")

        let baseNative = CGSize(width: CGFloat(base.nativeWidth ?? base.image.width),
                                height: CGFloat(base.nativeHeight ?? base.image.height))
        let preview = MacStraightenPreview(source: baseNative, degrees: geometry.straightenDegrees)
        let safeWidth = Int(preview.safeCanvas.width)
        let safeHeight = Int(preview.safeCanvas.height)
        guard safeWidth == coreSafe.nativeWidth, safeHeight == coreSafe.nativeHeight else {
            throw Failure(description: "\(previewCase.name): safe canvas \(safeWidth)x\(safeHeight) != Core \(coreSafe.nativeWidth ?? -1)x\(coreSafe.nativeHeight ?? -1)")
        }

        let canvasSize = CGSize(width: 600, height: 500)
        let pan = previewCase.pan
        let capture = try captureCanvas(frame: base, geometry: geometry, source: baseNative,
                                        pan: pan, size: canvasSize)
        let rendered = CGSize(width: base.image.width, height: base.image.height)
        let safeRendered = preview.safeRenderedSize(rendered)
        let crop = MacCropInteraction.rect(from: geometry)
        let selection = MacCropInteraction.selectionBounds(crop: crop,
            imageBounds: CGRect(origin: .zero, size: safeRendered))
        let fit = min((canvasSize.width - 24) / max(1, selection.width),
                      (canvasSize.height - 24) / max(1, selection.height))
        let cropSize = CGSize(width: selection.width * fit, height: selection.height * fit)
        let cropRect = CGRect(x: (canvasSize.width - cropSize.width) / 2 + pan.width,
                              y: (canvasSize.height - cropSize.height) / 2 + pan.height,
                              width: cropSize.width, height: cropSize.height)
        let scaleX = CGFloat(capture.width) / canvasSize.width
        let scaleY = CGFloat(capture.height) / canvasSize.height
        guard abs(scaleX - scaleY) < 0.001 else {
            throw Failure(description: "captured bitmap has nonuniform scale \(scaleX)x\(scaleY)")
        }
        let capturedCrop = cropRect.applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
        let visibleCrop = capturedCrop.intersection(CGRect(x: 0, y: 0, width: capture.width, height: capture.height))
        guard !visibleCrop.isEmpty else {
            throw Failure(description: "\(previewCase.name): crop is outside the captured viewport")
        }
        /* 平移后的裁切可能超出视口；只比较截图与最终图中对应的可见区域。 */
        let expectedCrop = CGRect(
            x: (visibleCrop.minX - capturedCrop.minX) / capturedCrop.width * CGFloat(expected.image.width),
            y: (visibleCrop.minY - capturedCrop.minY) / capturedCrop.height * CGFloat(expected.image.height),
            width: visibleCrop.width / capturedCrop.width * CGFloat(expected.image.width),
            height: visibleCrop.height / capturedCrop.height * CGFloat(expected.image.height))
        guard let actualRegion = capture.cropping(to: visibleCrop),
              let expectedRegion = expected.image.cropping(to: expectedCrop) else {
            throw Failure(description: "\(previewCase.name): visible crop is unavailable")
        }
        let capturedPixels = pixels(actualRegion, outputSize: CGSize(width: 128, height: 128))
        let expectedPixels = pixels(expectedRegion, outputSize: CGSize(width: 128, height: 128))
        let (mae, maximum) = error(capturedPixels, expectedPixels)
        let actualName = "\(previewCase.name)-actual.png"
        let expectedName = "\(previewCase.name)-expected.png"
        try write(capture, to: output.appendingPathComponent(actualName))
        try write(expected.image, to: output.appendingPathComponent(expectedName))
        try write(actualRegion, to: output.appendingPathComponent("\(previewCase.name)-actual-crop.png"))
        try write(expectedRegion, to: output.appendingPathComponent("\(previewCase.name)-expected-crop.png"))
        print("Capture: \(previewCase.name) crop=\(capturedCrop) visible=\(visibleCrop) expected=\(expectedCrop)")
        guard mae <= 8.0 / 255.0 else {
            throw Failure(description: "\(previewCase.name): MAE \(mae) > 8/255 (max \(maximum))")
        }

        print("PASS: \(previewCase.name) safe=\(safeWidth)x\(safeHeight) final=\(expected.nativeWidth ?? -1)x\(expected.nativeHeight ?? -1) MAE=\(mae) max=\(maximum)")
        let fixture = raw.deletingPathExtension().lastPathComponent
        return Evidence(fixture: raw.lastPathComponent, name: previewCase.name, angle: geometry.straightenDegrees,
                        quarterTurns: geometry.quarterTurns,
                        flipHorizontal: geometry.flipHorizontal,
                        flipVertical: geometry.flipVertical,
                        perspectiveHorizontal: geometry.perspectiveHorizontal,
                        perspectiveVertical: geometry.perspectiveVertical,
                        baseNativeWidth: Int(baseNative.width), baseNativeHeight: Int(baseNative.height),
                        safeWidth: safeWidth, safeHeight: safeHeight,
                        coreSafeWidth: coreSafe.nativeWidth ?? 0, coreSafeHeight: coreSafe.nativeHeight ?? 0,
                        finalNativeWidth: expected.nativeWidth ?? expected.image.width,
                        finalNativeHeight: expected.nativeHeight ?? expected.image.height,
                        capturedCropWidth: Int(cropRect.width), capturedCropHeight: Int(cropRect.height),
                        meanAbsoluteError: mae, maximumChannelError: maximum,
                        actualPNG: "\(fixture)/\(actualName)", expectedPNG: "\(fixture)/\(expectedName)")
    }

    private static func previewGeometry(for geometry: GeometrySettings) -> GeometrySettings {
        var result = geometry
        result.cropX = 0; result.cropY = 0; result.cropWidth = 1; result.cropHeight = 1
        result.straightenDegrees = 0
        return result
    }

    @MainActor
    private static func activeOverlayCheck(raw: URL, output: URL, engine: RenderEngine) throws {
        var geometry = GeometrySettings()
        geometry.cropX = 0.14; geometry.cropY = 0.10
        geometry.cropWidth = 0.64; geometry.cropHeight = 0.72
        geometry.straightenDegrees = 45
        geometry.flipHorizontal = true
        let baseGeometry = previewGeometry(for: geometry)
        var settings = Adjustments()
        settings.geometry = baseGeometry
        let base = try require(engine.render(raw, settings: settings, lut: nil, edge: 600,
                                             viewportPreview: true), "active overlay base")
        let source = CGSize(width: CGFloat(base.nativeWidth ?? base.image.width),
                            height: CGFloat(base.nativeHeight ?? base.image.height))
        let canvas = CGSize(width: 600, height: 500)
        let plain = try captureCanvas(frame: base, geometry: geometry, source: source,
                                      size: canvas, mode: .plain)
        let active = try captureCanvas(frame: base, geometry: geometry, source: source,
                                       size: canvas, mode: .activeOverlay)
        try write(plain, to: output.appendingPathComponent("active-overlay-plain.png"))
        try write(active, to: output.appendingPathComponent("active-overlay.png"))
        let preview = MacStraightenPreview(source: source, degrees: geometry.straightenDegrees)
        let safeRendered = preview.safeRenderedSize(CGSize(width: base.image.width, height: base.image.height))
        let fit = min((canvas.width - 24) / max(1, preview.rotatedSize(CGSize(width: base.image.width,
                                                                              height: base.image.height)).width),
                      (canvas.height - 24) / max(1, preview.rotatedSize(CGSize(width: base.image.width,
                                                                               height: base.image.height)).height))
        let safeBounds = MacCropInteraction.imageBounds(canvasSize: canvas, renderedSize: safeRendered,
                                                        factor: fit, pan: .zero)
        let outside = CGPoint(x: safeBounds.minX + safeBounds.width * 0.05,
                              y: safeBounds.minY + safeBounds.height * 0.50)
        let inside = CGPoint(x: safeBounds.minX + safeBounds.width * 0.50,
                             y: safeBounds.minY + safeBounds.height * 0.50)
        let plainOutside = luminance(plain, at: outside, canvas: canvas)
        let activeOutside = luminance(active, at: outside, canvas: canvas)
        let plainInside = luminance(plain, at: inside, canvas: canvas)
        let activeInside = luminance(active, at: inside, canvas: canvas)
        guard plainOutside > 0.03, plainInside > 0.03 else {
            throw Failure(description: "crop overlay reference patches are too dark: outside=\(plainOutside), inside=\(plainInside)")
        }
        let outsideRatio = activeOutside / plainOutside
        let insideRatio = activeInside / plainInside
        guard outsideRatio > 0.10, outsideRatio < 0.75, abs(insideRatio - 1) < 0.10 else {
            throw Failure(description: "active crop overlay changed the wrong regions: outside=\(activeOutside)/\(plainOutside) (\(outsideRatio)), inside=\(activeInside)/\(plainInside) (\(insideRatio))")
        }
        print("PASS: active crop overlay patch ratios outside=\(outsideRatio), inside=\(insideRatio) (plain outside=\(plainOutside), inside=\(plainInside))")
    }

    @MainActor
    private static func captureCanvas(frame: RenderedImage, geometry: GeometrySettings,
                                      source: CGSize, pan: CGSize = .zero, size: CGSize,
                                      mode: CaptureMode = .pending) throws -> CGImage {
        var currentPan = pan
        let pendingGeometry = mode == .pending ? geometry : nil
        var cropSettings: GeometrySettings? = mode == .pending ? nil : geometry
        /* 全画布选区保留相同旋转和缩放，让参考采样区域没有遮罩或网格。 */
        if mode == .plain {
            cropSettings?.cropX = 0; cropSettings?.cropY = 0
            cropSettings?.cropWidth = 1; cropSettings?.cropHeight = 1
        }
        let view = PhotoCanvas(frame: frame, viewport: PhotoViewport(), sourceWidth: Int(source.width),
            pan: Binding(get: { currentPan }, set: { currentPan = $0 }), clipping: false,
            sourceHeight: Int(source.height), cropSettings: cropSettings, pendingGeometry: pendingGeometry,
            cropGrid: mode != .plain)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(description: "bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(description: "captured CGImage unavailable")
        }
        return image
    }

    private static func luminance(_ image: CGImage, at point: CGPoint, canvas: CGSize) -> Double {
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            .applying(CGAffineTransform(scaleX: CGFloat(image.width) / canvas.width,
                                       y: CGFloat(image.height) / canvas.height))
        let patch = pixels(image, from: rect, outputSize: CGSize(width: 8, height: 8))
        let total = stride(from: 0, to: patch.count, by: 4).reduce(0.0) { sum, index in
            sum + Double(patch[index]) + Double(patch[index + 1]) + Double(patch[index + 2])
        }
        return total / Double(8 * 8 * 3 * 255)
    }

    private static func pixels(_ image: CGImage, from sourceRect: CGRect? = nil,
                               outputSize: CGSize) -> [UInt8] {
        let width = Int(outputSize.width), height = Int(outputSize.height)
        var result = [UInt8](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { storage in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: storage.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            let source = sourceRect.flatMap { image.cropping(to: $0) } ?? image
            context.draw(source, in: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
        }
        return result
    }

    private static func error(_ actual: [UInt8], _ expected: [UInt8]) -> (Double, Int) {
        var total = 0.0
        var maximum = 0
        var samples = 0
        for index in stride(from: 0, to: min(actual.count, expected.count), by: 4) {
            for channel in 0..<3 {
                let difference = abs(Int(actual[index + channel]) - Int(expected[index + channel]))
                total += Double(difference) / 255
                maximum = max(maximum, difference)
                samples += 1
            }
        }
        return (samples == 0 ? 1 : total / Double(samples), maximum)
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure(description: "Could not create PNG destination (url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "Could not write PNG (url.path)")
        }
    }

    private static func require(_ image: RenderedImage?, _ name: String) throws -> RenderedImage {
        guard let image else { throw Failure(description: "Missing (name)") }
        return image
    }
}
