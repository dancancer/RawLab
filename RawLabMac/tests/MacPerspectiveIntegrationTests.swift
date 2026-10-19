import AppKit
import ImageIO
import Darwin

@main struct MacPerspectiveIntegrationTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RenderError.failed(message) }
        checks += 1
        print("PASS: \(message)")
    }

    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

    static func displayBytes(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> [UInt8] {
        let width = width ?? image.width, height = height ?? image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    static func maximumDelta(_ left: [UInt8], _ right: [UInt8]) -> Int {
        precondition(left.count == right.count)
        return zip(left, right).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    static func writePreview(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw RenderError.outputIO
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.outputIO }
    }

    static func reject(_ message: String, operation: () throws -> Void) throws {
        var rejected = false
        do { try operation() } catch RenderError.failed { rejected = true }
        try check(rejected, message)
    }

    static func settings(horizontal: Double, vertical: Double) -> Adjustments {
        var settings = Adjustments()
        settings.setGeometry(.perspectiveHorizontal, to: horizontal)
        settings.setGeometry(.perspectiveVertical, to: vertical)
        return settings
    }

    static func main() throws {
        setbuf(stdout, nil)
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let originalIdentity = try OriginalFileIdentity(raw)
        try controlChecks()
        let edge = 512
        let cpu = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let baseline = try cpu.render(raw, settings: Adjustments(), lut: nil, edge: edge)!
        let reference = displayBytes(baseline.image, width: 128, height: 128)
        try writePreview(baseline.image, to: output.appendingPathComponent("identity-preview.png"))
        let cases: [(String, Adjustments)] = [
            ("horizontal", settings(horizontal: 0.6, vertical: 0)),
            ("vertical", settings(horizontal: 0, vertical: -0.4)),
            ("combined", settings(horizontal: 0.6, vertical: -0.4))
        ]
        var combined: RenderedImage?
        for (name, settings) in cases {
            let preview = try cpu.render(raw, settings: settings, lut: nil, edge: edge)!
            let transformed = displayBytes(preview.image, width: 128, height: 128)
            try check(maximumDelta(reference, transformed) > 8 &&
                      preview.nativeWidth! < baseline.nativeWidth! && preview.nativeHeight! < baseline.nativeHeight!,
                      "\(name) controls reach the processor and change sampled pixels on the safe native canvas")
            try writePreview(preview.image, to: output.appendingPathComponent("\(name)-preview.png"))
            let proxy = try cpu.render(raw, settings: settings, lut: nil, edge: edge,
                                       interactive: true, viewportPreview: true)!
            try check(bytes(proxy.image) != bytes(preview.image) &&
                      proxy.image.width == preview.image.width && proxy.image.height == preview.image.height &&
                      proxy.nativeWidth == preview.nativeWidth && proxy.nativeHeight == preview.nativeHeight,
                      "\(name) perspective uses the reduced viewport with unchanged output and native dimensions")
            let destination = output.appendingPathComponent("\(name)-final.png")
            _ = try cpu.render(raw, settings: settings, lut: nil, edge: nil, output: destination, exportLongEdge: edge)
            let source = CGImageSourceCreateWithURL(destination as CFURL, nil)!
            let exported = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            try check(exported.width == preview.image.width && exported.height == preview.image.height &&
                      exported.bitsPerComponent == 16, "\(name) FINAL PNG matches preview dimensions and retains sixteen bits")
            let delta = maximumDelta(displayBytes(exported), displayBytes(preview.image))
            try check(delta <= 2, "\(name) FINAL PNG agrees with preview pixels after display conversion (max \(delta)/255)")
            let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            let direct = try fresh.render(raw, settings: settings, lut: nil, edge: edge)!
            try check(bytes(direct.image) == bytes(preview.image) && direct.nativeWidth == preview.nativeWidth &&
                      direct.nativeHeight == preview.nativeHeight, "\(name) fresh and reused sessions produce identical perspective")
            if name == "combined" { combined = preview }
        }
        let horizontal = try cpu.render(raw, settings: cases[0].1, lut: nil, edge: edge)!
        let opposite = try cpu.render(raw, settings: settings(horizontal: -0.6, vertical: 0), lut: nil, edge: edge)!
        try check(horizontal.image.width == opposite.image.width && horizontal.image.height == opposite.image.height &&
                  maximumDelta(displayBytes(horizontal.image), displayBytes(opposite.image)) > 8,
                  "opposite horizontal values change pixels even on identically sized canvases")
        let vertical = try cpu.render(raw, settings: cases[1].1, lut: nil, edge: edge)!
        let verticalOpposite = try cpu.render(raw, settings: settings(horizontal: 0, vertical: 0.4), lut: nil, edge: edge)!
        try check(vertical.image.width == verticalOpposite.image.width && vertical.image.height == verticalOpposite.image.height &&
                  maximumDelta(displayBytes(vertical.image), displayBytes(verticalOpposite.image)) > 8,
                  "opposite vertical values change pixels even on identically sized canvases")

        var reset = cases[2].1
        reset.setGeometry(.perspectiveHorizontal, to: 0)
        let onlyVertical = try cpu.render(raw, settings: reset, lut: nil, edge: edge)!
        try check(bytes(onlyVertical.image) == bytes(vertical.image), "resetting horizontal alone preserves vertical and clears horizontal core state")
        reset.setGeometry(.perspectiveVertical, to: 0)
        let zero = try cpu.render(raw, settings: reset, lut: nil, edge: edge)!
        try check(reset.geometry == nil && bytes(zero.image) == bytes(baseline.image),
                  "setting both controls to zero clears reused native perspective")
        reset = cases[2].1
        _ = try cpu.render(raw, settings: reset, lut: nil, edge: edge)
        reset.reset(.geometry)
        let groupReset = try cpu.render(raw, settings: reset, lut: nil, edge: edge)!
        try check(reset.geometry == nil && bytes(groupReset.image) == bytes(baseline.image),
                  "geometry group reset restores identity pixels and native state")

        var geometric = cases[2].1
        geometric.rotateGeometry(clockwise: true)
        geometric.flipGeometry(horizontal: true)
        geometric.setGeometry(.cropWidth, to: 0.8)
        geometric.setGeometry(.cropHeight, to: 0.7)
        geometric.setGeometry(.straightenDegrees, to: 5)
        let geometryAndPerspective = try cpu.render(raw, settings: geometric, lut: nil, edge: edge)!
        var geometryWithoutPerspective = geometric
        geometryWithoutPerspective.setGeometry(.perspectiveHorizontal, to: 0)
        geometryWithoutPerspective.setGeometry(.perspectiveVertical, to: 0)
        let geometryOnly = try cpu.render(raw, settings: geometryWithoutPerspective, lut: nil, edge: edge)!
        try check(geometryAndPerspective.nativeWidth! < geometryOnly.nativeWidth! &&
                  geometryAndPerspective.nativeHeight! < geometryOnly.nativeHeight!,
                  "perspective preserves rotation, flip, straightening and crop configuration")

        try invalidAndExposureChecks(raw: raw, cpu: cpu, valid: cases[2].1, expected: combined!, edge: edge)
        try persistenceChecks(raw: raw, output: output, settings: cases[2].1, expected: combined!, edge: edge)
        try backendChecks(raw: raw, settings: cases[2].1, baseline: baseline, expected: combined!, edge: edge)
        try check(try OriginalFileIdentity(raw) == originalIdentity, "all tests leave the bundled original RAW unchanged")
        print("PASS: \(checks) macOS perspective integration checks")
    }

    static func controlChecks() throws {
        for parameter in [GeometryParameter.perspectiveHorizontal, .perspectiveVertical] {
            try check(parameter.range(for: GeometrySettings()) == -1...1 && parameter.multiplier == 100 &&
                      parameter.defaultValue == 0, "\(parameter.rawValue) maps -100...100 display units to -1...1 core units")
            var state = Adjustments()
            state.setGeometry(parameter, to: ParameterPrecision.standard.snapped(12.34, in: -100...100) / parameter.multiplier)
            try check(abs(state.geometrySettings[keyPath: parameter.keyPath] - 0.123) < 1e-12,
                      "\(parameter.rawValue) precise input uses a 0.1 display grid")
            let normal = ParameterPrecision.standard.stepped(0, direction: 1, fine: false, in: -100...100)
            let fine = ParameterPrecision.standard.stepped(0, direction: 1, fine: true, in: -100...100)
            try check(normal / parameter.multiplier == 0.01 && fine / parameter.multiplier == 0.001,
                      "\(parameter.rawValue) normal and Shift wheel steps use display units")
            state.setGeometry(parameter, to: 5)
            try check(state.geometrySettings[keyPath: parameter.keyPath] == 1 && state.geometrySettings.isValid,
                      "\(parameter.rawValue) clamps valid numeric edits to the core range")
            let valid = state
            state.setGeometry(parameter, to: .nan)
            state.setGeometry(parameter, to: -.infinity)
            try check(state == valid, "\(parameter.rawValue) nonfinite input preserves the entire edit atomically")
        }
        let legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{\"geometry\":{\"perspectiveHorizontal\":0.3}}".utf8))
        try check(legacy.geometrySettings.perspectiveHorizontal == 0.3 && legacy.geometrySettings.perspectiveVertical == 0,
                  "partial saved geometry retains the perspective identity default")
    }

    static func invalidAndExposureChecks(raw: URL, cpu: RenderEngine, valid: Adjustments, expected: RenderedImage, edge: Int) throws {
        for (parameter, value) in [(GeometryParameter.perspectiveHorizontal, Double.nan), (.perspectiveVertical, .infinity),
                                   (.perspectiveHorizontal, 1.001), (.perspectiveVertical, -1.001)] {
            var invalid = valid
            var geometry = invalid.geometrySettings
            geometry[keyPath: parameter.keyPath] = value
            // Change basic geometry too: validation must precede either native setter.
            geometry.quarterTurns = 1
            invalid.geometry = geometry
            try reject("render rejects invalid \(parameter.rawValue) together with simultaneous geometry changes") {
                _ = try cpu.render(raw, settings: invalid, lut: nil, edge: edge)
            }
            try reject("auto exposure rejects invalid \(parameter.rawValue) through the same geometry validation") {
                _ = try cpu.autoExposure(raw, settings: invalid)
            }
        }
        let recovered = try cpu.render(raw, settings: valid, lut: nil, edge: edge)!
        try check(bytes(recovered.image) == bytes(expected.image), "valid perspective remains renderable after invalid configurations")
        let identityEV = try cpu.autoExposure(raw, settings: Adjustments())
        let perspectiveEV = try cpu.autoExposure(raw, settings: valid)
        // Auto exposure meters color before geometry; its EV is not evidence of a visual transform.
        try check(identityEV.isFinite && perspectiveEV.isFinite && abs(identityEV - perspectiveEV) < 1e-6,
                  "auto exposure accepts perspective settings and retains the core metering semantics")
    }

    static func persistenceChecks(raw: URL, output: URL, settings: Adjustments, expected: RenderedImage, edge: Int) throws {
        let directory = output.appendingPathComponent("edits", isDirectory: true)
        let store = try EditPersistence(directory: directory)
        let state = PhotoEditState(settings: settings, filmID: "")
        try store.save(raw, state: state)
        let reopened = try EditPersistence(directory: directory)
        guard let restored = try reopened.state(for: raw) else { throw RenderError.failed("missing restored perspective edit") }
        try check(restored == state && restored.settings.geometrySettings.perspectiveHorizontal == 0.6 &&
                  restored.settings.geometrySettings.perspectiveVertical == -0.4,
                  "EditPersistence save and a new store preserve both perspective parameters")
        let fresh = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let rendered = try fresh.render(raw, settings: restored.settings, lut: nil, edge: edge)!
        try check(bytes(rendered.image) == bytes(expected.image) && rendered.nativeWidth == expected.nativeWidth &&
                  rendered.nativeHeight == expected.nativeHeight, "restored perspective renders identically after reopening")
        var reset = restored
        reset.settings.reset(.geometry)
        try reopened.save(raw, state: reset)
        let cleared = try EditPersistence(directory: directory).state(for: raw)
        try check(cleared?.settings.geometry == nil, "saved geometry reset reopens with identity perspective")
    }

    static func backendChecks(raw: URL, settings: Adjustments, baseline: RenderedImage, expected: RenderedImage, edge: Int) throws {
        let force = try RenderEngine(gpuMode: SONY2FUJI_GPU_FORCE)
        let identity = try force.render(raw, settings: Adjustments(), lut: nil, edge: edge)!
        let identityDelta = maximumDelta([UInt8](bytes(identity.image)), [UInt8](bytes(baseline.image)))
        try check(force.lastBackend == SONY2FUJI_BACKEND_METAL && identityDelta <= 2,
                  "identity uses actual Metal and agrees with CPU (max \(identityDelta)/255)")
        let auto = try RenderEngine(gpuMode: SONY2FUJI_GPU_AUTO)
        let transformed = try auto.render(raw, settings: settings, lut: nil, edge: edge)!
        let delta = maximumDelta([UInt8](bytes(transformed.image)), [UInt8](bytes(expected.image)))
        try check(auto.lastBackend == SONY2FUJI_BACKEND_CPU && delta <= 2,
                  "active perspective under GPU Auto reports CPU geometry and agrees with CPU (max \(delta)/255)")
        try reject("GPU Force rejects unsupported perspective instead of reporting accelerated geometry") {
            _ = try force.render(raw, settings: settings, lut: nil, edge: edge)
        }
        let reset = try force.render(raw, settings: Adjustments(), lut: nil, edge: edge)!
        try check(force.lastBackend == SONY2FUJI_BACKEND_METAL && maximumDelta([UInt8](bytes(reset.image)), [UInt8](bytes(baseline.image))) <= 2,
                  "identity reset after perspective restores actual Metal rendering")
    }
}
