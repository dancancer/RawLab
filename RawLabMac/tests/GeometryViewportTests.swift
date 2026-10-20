import AppKit
import Foundation

@main
struct GeometryViewportTests {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw RenderError.failed(message) }
        print("PASS: \(message)")
    }

    static func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

    static func cases() -> [(String, Adjustments)] {
        var crop = Adjustments()
        crop.setGeometry(.cropWidth, to: 0.8); crop.setGeometry(.cropHeight, to: 0.8)
        crop.setGeometry(.cropX, to: 0.1); crop.setGeometry(.cropY, to: 0.1)
        var straighten = crop
        straighten.setGeometry(.straightenDegrees, to: 3)
        return [("crop", crop), ("straighten_crop", straighten), ("identity", Adjustments())]
    }

    static func main() throws {
        setbuf(stdout, nil)
        let raw = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        if CommandLine.arguments.contains("--bench") {
            for (name, settings) in cases() {
                _ = try engine.render(raw, settings: settings, lut: nil, edge: 2048, viewportPreview: true)
                var samples: [Double] = []
                for _ in 0..<5 {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try engine.render(raw, settings: settings, lut: nil, edge: 2048, viewportPreview: true)
                    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                samples.sort()
                print("MAC BENCH \(name) CPU edge=2048 median_ms=\(samples[2]) range_ms=\(samples.first!)..\(samples.last!)")
            }
            return
        }
        for (name, settings) in cases().prefix(2) {
            let exact = try engine.render(raw, settings: settings, lut: nil, edge: 512)!
            let reduced = try engine.render(raw, settings: settings, lut: nil, edge: 512, viewportPreview: true)!
            try check(exact.image.width == reduced.image.width && exact.image.height == reduced.image.height &&
                      exact.nativeWidth == reduced.nativeWidth && exact.nativeHeight == reduced.nativeHeight,
                      "\(name): viewport preserves output and full geometry dimensions")
            try check(bytes(exact.image) != bytes(reduced.image), "\(name): Mac enables geometry viewport reduction")
            let interactive = try engine.render(raw, settings: settings, lut: nil, edge: 512,
                                                interactive: true, viewportPreview: true)!
            try check(bytes(interactive.image) == bytes(reduced.image), "\(name): geometry still disables the half-size proxy")
            let native = try engine.render(raw, settings: settings, lut: nil, edge: nil)!
            let actual = try engine.render(raw, settings: settings, lut: nil, edge: nil, viewportPreview: true)!
            try check(bytes(native.image) == bytes(actual.image), "\(name): actual pixels stay exact")
        }
    }
}
