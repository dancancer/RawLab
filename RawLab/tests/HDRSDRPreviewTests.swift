import Foundation
import UIKit

@main enum HDRSDRPreviewTests {
    static func main() throws {
        setbuf(stdout,nil)
        guard let path=ProcessInfo.processInfo.environment["RAWLAB_TEST_HDR"] else { fatalError("Pass RAWLAB_TEST_HDR") }
        let source=URL(fileURLWithPath:path)
        let model=RawEditorViewModel()
        let preview=try model.buildRasterPreviewBase(url:source)
        let limit=Int(model.previewMaxDimension)
        guard max(preview.buffer.width,preview.buffer.height)<=limit else {
            print("FAIL SDR preview decoded full canvas \(preview.buffer.width)x\(preview.buffer.height), limit \(limit)")
            fatalError("SDR preview allocation was not bounded")
        }
        let info=try HDRSourceInfo.probe(source)!.native
        let swapped=info.orientation>=5
        let native=CGSize(width:Int(swapped ? info.height : info.width),height:Int(swapped ? info.width : info.height))
        guard preview.buffer.nativeSize==native else { fatalError("SDR proxy lost original geometry bounds") }
        guard preview.buffer.isProxy else { fatalError("SDR preview lost its proxy provenance") }
        let processor=model.processor
        let scaled=try processor.processBuffer(buffer:preview.buffer,settings:.default,previewLongEdge:256,lutURL:nil)
        guard scaled.nativeSize==native && scaled.isProxy else { fatalError("SDR processing lost native geometry/proxy identity") }
        do {
            _ = try processor.processBuffer(buffer:preview.buffer,settings:.default,previewLongEdge:nil,lutURL:nil)
            fatalError("FINAL processing accepted a preview proxy")
        } catch let error as HDRNativeError {
            guard error.reason==UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE) else { throw error }
        }
        var cropped=RawSettings.default; cropped.geometry=GeometrySettings()
        cropped.geometry.quarterTurns=1; cropped.geometry.cropWidth=0.5
        let crop=try processor.processBuffer(buffer:preview.buffer,settings:cropped,previewLongEdge:256,lutURL:nil)
        guard crop.nativeSize==CGSize(width:Int(native.height)/2,height:Int(native.width)) else {
            fatalError("SDR proxy inferred native crop bounds from preview pixels")
        }
        let final=try processor.loadRasterBuffer(url:source).buffer
        guard !final.isProxy && final.width==Int(native.width) && final.height==Int(native.height) else {
            fatalError("FINAL decoding reused a preview proxy")
        }
        model.sourceFile = .externallyManaged(source); model.sourceKind = .raster
        model.sourceIsHDR=true; model.hasImage=true; model.draftBuffer=preview.buffer
        model.sourceOrientation = .up
        var exported: Result<Data,Error>?
        model.exportJPEG(settings:.default) { exported=$0 }
        let deadline=Date().addingTimeInterval(90)
        while exported==nil && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        guard let exported else { fatalError("SDR export timed out") }
        let image=UIImage(data:try exported.get())!
        guard image.size==native else { fatalError("SDR export reused the bounded preview") }
        print("PASS iOS bounded SDR preview and original geometry")
    }
}
