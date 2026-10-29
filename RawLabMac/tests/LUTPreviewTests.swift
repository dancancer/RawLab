import Foundation
import CoreGraphics
import ImageIO

@main
struct LUTPreviewTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-preview-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lut = root.appendingPathComponent("unknown.cube")
        try "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".write(to: lut, atomically: true, encoding: .utf8)
        let pixels = Data((0..<32*16).flatMap { _ in [UInt8(60), 90, 120, 255] })
        let image = CGImage(width: 32, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let source = root.appendingPathComponent("photo.png")
        let output = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil); precondition(CGImageDestinationFinalize(output))
        let draft = try LUTCompatibility.inspect(lut)!
        let candidate = draft.applying(draft.candidates!.first!, displayInput: true)!
        var worker: LUTPreviewWorker? = try LUTPreviewWorker(lut: lut, source: LUTPreviewSource(url: source))
        let owned = worker!.directory
        let baseline = try worker!.render(nil)
        let preview = try worker!.render(candidate)
        precondition(preview.width == 512 && preview.height == 256 && preview.pixels == baseline.pixels)
        let untouched = try LUTCompatibility.inspect(lut)!
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(untouched.contract.input.space.isEmpty && files.count == 2)
        let reference = try LUTPreviewFrame.loadReference(source)
        let conditions = LUTReferenceConditions(sameSource: true, sameGeometry: true, sameProcessing: true, knownSRGB: true,
            referenceSource: "Synthetic same-image fixture, not an author reference")
        let comparison = try preview.compare(to: reference, conditions: conditions)
        precondition(comparison.meanAbsoluteRGB == 0)
        do { _ = try preview.compare(to: reference, conditions: LUTReferenceConditions()); fatalError("Unconfirmed comparison accepted") }
        catch { }
        worker = nil
        precondition(!FileManager.default.fileExists(atPath: owned.path))
        let model = LUTCompatibilityPreviewModel()
        model.load(lut: lut, source: LUTPreviewSource(url: source), draft: draft)
        wait { !model.isLoading }
        precondition(model.frame(for: candidate) != nil)
        model.loadReference(source)
        wait { model.reference != nil }
        model.compare(candidate, conditions: conditions)
        wait { model.comparison != nil }
        precondition(model.comparison!.candidateBoundaryFraction == 0)
        model.load(lut: lut, source: LUTPreviewSource(url: source), draft: draft)
        precondition(model.reference == nil && model.referenceName == nil && model.comparison == nil)
        wait { !model.isLoading }
        model.loadReference(source)
        model.load(lut: lut, source: LUTPreviewSource(url: source), draft: draft)
        wait { !model.isLoading }
        precondition(model.reference == nil && model.referenceName == nil, "Old reference task published after source change")
        model.close()
        print("PASS: isolated preview, comparison gating, source-change reference invalidation and owned-file cleanup")
        for path in CommandLine.arguments.dropFirst() {
            try hdrSourcePreview(URL(fileURLWithPath: path), lut: lut, draft: draft, candidate: candidate)
        }
        if CommandLine.arguments.count == 1 { print("SKIP HDR originals: pass read-only HDR fixture paths") }
    }
    private static func hdrSourcePreview(_ source: URL, lut: URL, draft: LUTCompatibility,
                                         candidate: LUTCompatibility) throws {
        let original = try Data(contentsOf: source), originalLUT = try Data(contentsOf: lut)
        let expected = try sdrReference(source)
        let live = HDRImage.liveAllocations
        var worker: LUTPreviewWorker? = try LUTPreviewWorker(lut: lut, source: LUTPreviewSource(url: source))
        let owned = worker!.directory
        precondition(worker!.displayInput, "HDR original must use display-input LUT candidates")
        precondition(HDRImage.liveAllocations.count == live.count, "Preview retained an unused HDR float pair")
        let baseline = try worker!.render(nil), preview = try worker!.render(candidate)
        precondition(max(baseline.width, baseline.height) <= 512 && baseline.width == expected.width && baseline.height == expected.height,
                     "HDR source preview lost its bounded oriented canvas")
        precondition(preview.pixels == baseline.pixels, "Identity compatibility LUT changed the SDR baseline")
        for i in baseline.pixels.indices {
            precondition(abs(Int(baseline.pixels[i]) - Int(expected.pixels[i])) <= 1,
                         "LUT preview did not use the original's SDR rendition")
        }
        worker = nil
        precondition(!FileManager.default.fileExists(atPath: owned.path), "HDR source copy was not released")
        let model = LUTCompatibilityPreviewModel()
        model.load(lut: lut, source: LUTPreviewSource(url: source), draft: draft)
        wait { !model.isLoading }
        precondition(model.notice == nil && model.displayInput && model.baseline != nil && model.frame(for: candidate) != nil,
                     "HDR source left the compatibility wizard without a confirmable preview")
        model.close()
        let sourceAfter = try Data(contentsOf: source), lutAfter = try Data(contentsOf: lut)
        precondition(sourceAfter == original && lutAfter == originalLUT,
                     "Compatibility preview changed an original input")
        print("PASS HDR compatibility source: \(source.lastPathComponent), \(baseline.width)x\(baseline.height), SDR pixels, candidate, model and cleanup")
    }
    private static func sdrReference(_ source: URL) throws -> (width: Int, height: Int, pixels: Data) {
        guard let info = try HDRSourceInfo.probe(source) else { fatalError("Fixture is not an HDR original") }
        let pair = try HDRImage.decode(source, info: info, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: 512)
        // 独立按线性 SDR 合同量化，不调用向导或产品的 CGImage 映射函数。
        let pixels = pair.withPair { view -> Data in
            let buffer = view.pointee.sdr, values = buffer.data!.assumingMemoryBound(to: Float.self)
            var result = Data(count: pair.width * pair.height * 4)
            for y in 0..<pair.height { for x in 0..<pair.width {
                let input = y * Int(buffer.stride_bytes) / 4 + x * 3, output = (y * pair.width + x) * 4
                for c in 0..<3 {
                    let linear = min(1, max(0, Double(values[input + c])))
                    let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
                    result[output + c] = UInt8((encoded * 255).rounded())
                }
                result[output + 3] = 255
            } }
            return result
        }
        return (pair.width, pair.height, pixels)
    }
    private static func wait(_ completed: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !completed() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        precondition(completed(), "Preview operation timed out")
    }
}
