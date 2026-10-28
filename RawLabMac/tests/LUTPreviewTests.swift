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
    }
    private static func wait(_ completed: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !completed() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        precondition(completed(), "Preview operation timed out")
    }
}
