import AppKit
import ImageIO
import Foundation

@main
struct AdjustmentTests {
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fputs("FAIL: \(name)\n",stderr); exit(1) }
        print("PASS: \(name)")
    }

    static func main() throws {
        let names=Set(Mirror(reflecting: Adjustments()).children.compactMap(\.label))
        let required: Set<String>=["contrast","highlights","shadows","toneCurve","saturation","sharpening"]
        guard required.isSubset(of: names) else {
            fputs("FAIL: Mac adjustments do not expose all six approved controls\n",stderr)
            exit(1)
        }
        var request=sony2fuji_request()
        Adjustments().apply(to: &request)
        check(request.contrast == 1 && request.saturation == 1 && request.highlights == 0 &&
            request.shadows == 0 && request.tone_curve == 0 && request.sharpening == 0,
            "Default controls preserve the previous C request")
        var settings=Adjustments()
        settings.exposure=1.25; settings.exposureMode = .preview; settings.strength=0.4
        settings.contrast=25; settings.highlights = -60; settings.shadows=40; settings.toneCurve=30
        settings.saturation = -20; settings.sharpening=75
        settings.apply(to: &request)
        check(request.contrast == 1.25 && request.saturation == 0.8 && request.highlights == 0.6 &&
            request.shadows == 0.4 && request.tone_curve == 0.3 && request.sharpening == 0.75 &&
            request.exposure_ev == 1.25, "Six controls map to the shared core without changing input EV")
        settings.reset(.tone)
        check(settings.isDefault(.tone) && settings.saturation == -20 && settings.sharpening == 75 &&
            settings.exposure == 1.25 && settings.strength == 0.4, "Tone group reset preserves other groups")
        settings.reset(.input)
        check(settings.exposureMode == .scene && settings.exposure == 0 && settings.saturation == -20,
            "Input reset restores exposure mode without resetting color")
        for group in AdjustmentGroup.allCases { settings.reset(group) }
        check(settings == Adjustments(), "All group resets restore defaults")

        for parameter in AdjustmentParameter.allCases {
            let spec=parameter.spec
            check(spec.parse(spec.text(spec.defaultValue)) == spec.defaultValue,"\(parameter) default numeric round trip")
            check(spec.parse("nan") == nil && spec.parse("inf") == nil && spec.parse("oops") == nil,
                "\(parameter) rejects invalid numeric input")
            check(spec.parse("999999") == spec.range.upperBound && spec.parse("-999999") == spec.range.lowerBound,
                "\(parameter) clamps typed values to bounds")
        }
        check(AdjustmentParameter.strength.spec.parse("42") == 0.42 &&
              AdjustmentParameter.exposure.spec.parse(" -1.25 ") == -1.25,"Percent and fractional EV input")

        let root=URL(fileURLWithPath: CommandLine.arguments[1])
        let output=URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        guard CommandLine.arguments.count > 3 else {
            throw RenderError.failed("Pass an external RAW fixture path")
        }
        let raw=URL(fileURLWithPath: CommandLine.arguments[3])
        print("RAW: \(raw.lastPathComponent)")
        let lut=root.appendingPathComponent("lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        let engine=try RenderEngine()
        let original=try engine.render(raw,settings: Adjustments(),lut: lut,edge: 400)!
        check(original.asShotWhiteBalance != nil, "Fixture exposes calibrated as-shot Kelvin and tint")
        if let camera = original.asShotWhiteBalance {
            print("As-shot: \(camera.temperature) K, tint \(camera.tint)")
            var reset = Adjustments()
            reset.resolveWhiteBalance(camera)
            reset.set(.temperature, to: 8000)
            reset.resetAll()
            check(reset.whiteBalanceMode == .asShot && reset.temperature == camera.temperature && reset.isDefault,
                  "Reset all retains per-photo camera white balance metadata")
        }
        check(!original.isFullResolution, "Bounded previews do not claim native pixel size")
        let controls: [AdjustmentParameter]=[.contrast,.highlights,.shadows,.toneCurve,.saturation,.sharpening,.vignetteAmount,.grainAmount]
        for parameter in controls {
            var changed=Adjustments()
            changed[keyPath: parameter.spec.keyPath]=parameter == .sharpening ? 100 : 60
            let rendered=try engine.render(raw,settings: changed,lut: lut,edge: 400)!
            // Core tests separately isolate sharpening from preview resizing effects.
            check(rendered.histogram != original.histogram,"\(parameter) changes a real RAW render")
            check(rendered.baselineEV == original.baselineEV,"\(parameter) preserves the RAW exposure baseline")
            if parameter == .highlights || parameter == .shadows {
                let mean: ([[Double]]) -> Double = { bins in bins.flatMap { $0.enumerated().map { Double($0.offset)*$0.element } }.reduce(0,+) }
                check(mean(rendered.histogram)>mean(original.histogram),"Positive \(parameter) brightens instead of darkening")
            }
        }
        let restored=try engine.render(raw,settings: Adjustments(),lut: lut,edge: 400)!
        check(restored.histogram == original.histogram,"Reset restores the original image")

        // Export the adjusted image from the same engine and verify encoded pixels against
        // the full-resolution display buffer, not just the existence of an output file.
        settings.contrast=12; settings.highlights = -25; settings.shadows=15
        settings.toneCurve=10; settings.saturation=8; settings.sharpening=40
        settings.setEffect(.vignetteAmount, to: -40)
        settings.setEffect(.vignetteHighlights, to: 65)
        settings.setEffect(.grainAmount, to: 45)
        settings.setEffect(.grainSize, to: 60)
        let full=try engine.render(raw,settings: settings,lut: lut,edge: nil)!
        check(full.isFullResolution, "Native renders carry actual-pixel display metadata")
        let pngURL=output.appendingPathComponent("adjusted.png")
        _ = try engine.render(raw,settings: settings,lut: lut,edge: nil,output: pngURL)
        guard let source=CGImageSourceCreateWithURL(pngURL as CFURL,nil),
              let png=CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw RenderError.failed("Adjusted PNG cannot be decoded")
        }
        check(png.width == full.image.width && png.height == full.image.height && png.bitsPerComponent == 16,
            "Adjusted export keeps original dimensions and sixteen-bit samples")
        let fullBytes=full.image.dataProvider!.data! as Data
        let pngBytes=png.dataProvider!.data! as Data
        let littleEndian=png.bitmapInfo.contains(.byteOrder16Little)
        let channels=png.bitsPerPixel/png.bitsPerComponent
        var largestError=0
        for y in stride(from: 0,to: png.height,by: 97) { for x in stride(from: 0,to: png.width,by: 101) {
            for channel in 0..<3 {
                let i=y*png.bytesPerRow+(x*channels+channel)*2
                let a=Int(pngBytes[i]), b=Int(pngBytes[i+1])
                let value=littleEndian ? a+(b<<8) : (a<<8)+b
                let encoded=Int((Double(value)*255/65535).rounded())
                largestError=max(largestError,abs(encoded-Int(fullBytes[y*full.image.bytesPerRow+x*4+channel])))
            }
        }}
        check(largestError <= 1,"Adjusted preview/export pixel parity at 100 percent")
        print("Artifacts: \(output.path)")
    }
}
