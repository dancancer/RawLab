import AppKit
import Foundation

@main enum HDRSDRPreviewTests {
    static func main() throws {
        let source=URL(fileURLWithPath:CommandLine.arguments[1])
        let meter=try RenderEngine(gpuMode:SONY2FUJI_GPU_OFF)
        let exposure=try meter.autoExposure(source,settings:Adjustments())
        guard exposure.isFinite && (-4...4).contains(exposure) else { fatalError("SDR metering returned invalid exposure") }
        guard meter.cachedRasterBytes>0 && meter.cachedRasterBytes<=1280*1280*4 else {
            throw RenderError.failed("SDR auto exposure retained full-resolution raster: \(meter.cachedRasterBytes) bytes")
        }
        let engine=try RenderEngine(gpuMode:SONY2FUJI_GPU_OFF)
        let preview=try engine.render(source,settings:Adjustments(),lut:nil,edge:256)!
        guard max(preview.image.width,preview.image.height)==256 else { fatalError("SDR preview output is not bounded") }
        guard engine.cachedRasterBytes<=256*256*4 else {
            throw RenderError.failed("SDR preview retained full-resolution raster: \(engine.cachedRasterBytes) bytes")
        }
        let info=try HDRSourceInfo.probe(source)!.native
        let swapped=info.orientation>=5
        let width=Int(swapped ? info.height : info.width),height=Int(swapped ? info.width : info.height)
        guard preview.nativeWidth==width && preview.nativeHeight==height else {
            fatalError("SDR proxy lost original geometry bounds")
        }
        var settings=Adjustments(); settings.geometry=GeometrySettings()
        settings.geometry?.quarterTurns=1; settings.geometry?.cropWidth=0.5
        let cropped=try engine.render(source,settings:settings,lut:nil,edge:256)!
        guard cropped.nativeWidth==height/2 && cropped.nativeHeight==width else {
            fatalError("SDR proxy inferred native crop bounds from preview pixels")
        }
        let final=try engine.render(source,settings:Adjustments(),lut:nil,edge:nil)!
        guard final.image.width==width && final.image.height==height && final.isFullResolution else {
            fatalError("FINAL rendering reused an SDR preview proxy")
        }
        _ = try engine.autoExposure(source,settings:Adjustments())
        guard engine.cachedRasterBytes<=1280*1280*4 else {
            fatalError("SDR auto exposure reused the full-resolution raster cache")
        }
        let exported=try meter.render(source,settings:Adjustments(),lut:nil,edge:nil)!
        guard exported.image.width==width && exported.image.height==height && exported.isFullResolution else {
            fatalError("FINAL rendering reused a metering proxy")
        }
        print("PASS Mac SDR auto exposure uses a bounded preview before and after FINAL")
        print("PASS Mac bounded SDR preview, original geometry and fresh full-resolution FINAL")
    }
}
