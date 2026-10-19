import AppKit
import ImageIO
import Darwin

@main struct GeometryRenderTests {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RenderError.failed(message) }
        print("PASS: \(message)")
    }
    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

    static func displayBytes(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    static func main() throws {
        setbuf(stdout, nil)
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let auto = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
        let baseline = try cpu.render(raw, settings: Adjustments(), lut: nil, edge: nil)!
        try check(baseline.nativeWidth == baseline.image.width && baseline.nativeHeight == baseline.image.height,
                  "identity native dimensions are reported by the core")
        let forced = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
        if ProcessInfo.processInfo.environment["RAWLAB_TEST_CPU_ONLY"] == "1" {
            print("SKIP: identity Metal parity (RAWLAB_TEST_CPU_ONLY=1)")
        } else {
            let identityCPU = try cpu.render(raw, settings: Adjustments(), lut: nil, edge: 128)!
            let identityGPU = try forced.render(raw, settings: Adjustments(), lut: nil, edge: 128)!
            let identityDelta = zip(bytes(identityCPU.image), bytes(identityGPU.image)).map { abs(Int($0) - Int($1)) }.max()!
            try check(forced.lastBackend == SONY2FUJI_BACKEND_METAL && identityDelta <= 2 &&
                      identityGPU.nativeWidth == baseline.image.width && identityGPU.nativeHeight == baseline.image.height,
                      "identity geometry retains Metal rendering, CPU parity and native dimension metadata")
        }
        var settings = Adjustments()
        settings.rotateGeometry(clockwise: true)
        settings.flipGeometry(horizontal: true)
        settings.setGeometry(.cropWidth, to: 0.75)
        settings.setGeometry(.cropHeight, to: 0.5)
        settings.setGeometry(.cropX, to: 0.125)
        settings.setGeometry(.cropY, to: 0.25)
        let native = try cpu.render(raw, settings: settings, lut: nil, edge: nil)!
        let left = Int(floor(Double(baseline.image.height) * 0.125))
        let top = Int(floor(Double(baseline.image.width) * 0.25))
        let width = Int(ceil(Double(baseline.image.height) * 0.875)) - left
        let height = Int(ceil(Double(baseline.image.width) * 0.75)) - top
        try check(native.image.width == width && native.image.height == height &&
                  native.nativeWidth == width && native.nativeHeight == height,
                  "rotation and normalized crop use the same native geometry as the CLI")
        let source = [UInt8](bytes(baseline.image)), actual = [UInt8](bytes(native.image))
        var mapped = true
        for y in 0..<height {
            for x in 0..<width {
                // Clockwise turn followed by horizontal flip transposes pixels.
                let from = (left + x) * baseline.image.bytesPerRow + (top + y) * 4
                let to = y * native.image.bytesPerRow + x * 4
                if source[from..<from + 4] != actual[to..<to + 4] { mapped = false; break }
            }
            if !mapped { break }
        }
        try check(mapped, "Mac rotation, flip and crop preserve the exact mapped pixels")
        settings.setGeometry(.straightenDegrees, to: 7.5)
        let edge = min(512, max(width, height))
        let preview = try cpu.render(raw, settings: settings, lut: nil, edge: edge)!
        let requestedProxy = try cpu.render(raw, settings: settings, lut: nil, edge: edge,
                                            interactive: true, viewportPreview: true)!
        try check(bytes(preview.image) != bytes(requestedProxy.image) &&
                  preview.image.width == requestedProxy.image.width && preview.image.height == requestedProxy.image.height &&
                  preview.nativeWidth == requestedProxy.nativeWidth && preview.nativeHeight == requestedProxy.nativeHeight,
                  "active geometry uses the reduced viewport while preserving output and native dimensions")
        let accelerated = try auto.render(raw, settings: settings, lut: nil, edge: edge)!
        let geometryDelta = zip(bytes(accelerated.image), bytes(preview.image)).map { abs(Int($0) - Int($1)) }.max()!
        try check(auto.lastBackend == SONY2FUJI_BACKEND_CPU && geometryDelta <= 2,
                  "GPU Auto reports CPU geometry and maintains CPU parity (max \(geometryDelta)/255)")
        do {
            _ = try forced.render(raw, settings: settings, lut: nil, edge: edge)
            throw RenderError.failed("Force GPU must reject unavailable geometry acceleration")
        } catch RenderError.failed(let message) {
            try check(message != "Force GPU must reject unavailable geometry acceleration",
                      "GPU Force rejects unsupported geometry instead of pretending GPU success")
        }
        let exact = try cpu.render(raw, settings: settings, lut: nil, edge: nil)!
        let actualPixels = try cpu.render(raw, settings: settings, lut: nil, edge: nil, viewportPreview: true)!
        try check(bytes(exact.image) == bytes(actualPixels.image), "actual-pixel view ignores the viewport opt-in")
        try check(exact.image.width == preview.nativeWidth && exact.image.height == preview.nativeHeight &&
                  exact.image.width < width && exact.image.height < height,
                  "straightened preview retains the exact inscribed native canvas dimensions")
        let destination = output.appendingPathComponent("geometry.png")
        _ = try cpu.render(raw, settings: settings, lut: nil, edge: nil, output: destination, exportLongEdge: edge)
        let imageSource = CGImageSourceCreateWithURL(destination as CFURL, nil)!
        let exported = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        try check(exported.width == preview.image.width && exported.height == preview.image.height &&
                  exported.bitsPerComponent == 16, "FINAL PNG and preview have matching geometry with sixteen-bit export")
        let displayDelta = zip(displayBytes(exported), displayBytes(preview.image)).map { abs(Int($0) - Int($1)) }.max()!
        try check(displayDelta <= 2, "FINAL PNG pixels agree with preview after display conversion (max \(displayDelta)/255)")
        let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let direct = try fresh.render(raw, settings: settings, lut: nil, edge: edge)!
        try check(bytes(preview.image) == bytes(direct.image), "geometry result does not depend on prior session edits")
        let reset = try cpu.render(raw, settings: Adjustments(), lut: nil, edge: nil)!
        try check(bytes(reset.image) == bytes(baseline.image), "rendering identity clears all prior session geometry")
        try modelChecks(raw: raw, output: output)
    }

    static func modelChecks(raw: URL, output: URL) throws {
        let model = EditorModel(lookDirectory: output.appendingPathComponent("looks"),
            editDirectory: output.appendingPathComponent("edits"), batchDirectory: output.appendingPathComponent("batch"))
        model.films = []; model.selectedFilmID = ""
        model.updatePreviewLongEdge(512)
        model.open(raw)
        try wait("initial model rendering") { !model.busy && model.result != nil }
        let original = model.neutral!.image
        var geometry = GeometrySettings()
        geometry.quarterTurns = 1; geometry.flipVertical = true
        geometry.cropWidth = 0.75; geometry.cropX = 0.125
        geometry.cropHeight = 0.5; geometry.cropY = 0.25; geometry.straightenDegrees = -4
        model.settings.geometry = geometry
        try wait("geometry reference and preview") { !model.busy && model.result?.nativeWidth == model.neutral?.image.width }
        let neutral = model.neutral!.image
        try check(neutral !== original && model.result!.nativeHeight == neutral.height,
                  "original comparison and current edit share the same native geometric canvas")
        let engine = try RenderEngine()
        let expected = try engine.render(raw, settings: model.settings.neutralGeometrySettings, lut: nil, edge: nil)!
        try check(bytes(expected.image) == bytes(neutral), "comparison neutral uses the shared core geometry")
        model.settings.exposure = 0.5
        try wait("color change on transformed canvas") { !model.busy }
        try check(model.neutral!.image === neutral, "color adjustments reuse the geometric neutral cache")
        model.fullResolution = true
        try wait("100 percent geometry view") { !model.busy && model.result?.isFullResolution == true }
        try check(model.result!.image.width == neutral.width && model.result!.image.height == neutral.height,
                  "100 percent uses geometric native dimensions")
        try check(model.prepareBatch() && model.batch?.job.settings.geometrySettings == geometry,
                  "editor freezes current geometry in its batch snapshot")
        model.settings.reset(.geometry)
        try wait("identity reset") { !model.busy && model.neutral?.image === original }
        try check(model.neutral!.image === original && model.result!.nativeWidth == original.width,
                  "reset restores the immutable original reference and native dimensions")
        try check(model.batch?.job.settings.geometrySettings == geometry, "batch snapshot is independent of later editor geometry reset")
    }

    static func wait(_ name: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if condition() { print("PASS: \(name)"); return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        throw RenderError.failed("Timed out waiting for \(name)")
    }
}
