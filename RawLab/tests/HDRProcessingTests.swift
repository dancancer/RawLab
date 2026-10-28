import Foundation
import UIKit

@main enum HDRProcessingTests {
    static func require(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        setbuf(stdout,nil)
        guard let path=ProcessInfo.processInfo.environment["RAWLAB_TEST_HDR"] else { fatalError("Pass RAWLAB_TEST_HDR original") }
        let source=URL(fileURLWithPath:path)
        let bytes=try Data(contentsOf:source)
        let info=try HDRSourceInfo.probe(source)!
        let processor=Sony2FujiProcessor(gpuMode:SONY2FUJI_GPU_OFF)
        let output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try autoreleasepool {
            print("HDR_STAGE preview")
            var settings=HDRSettings()
            let preview=try processor.processHDR(url:source,settings:settings,previewLongEdge:256)
            require(preview.isProxy && max(preview.width,preview.height)==256,"preview quality or dimensions")
            let original=preview.withPair { Data(bytes:$0.pointee.hdr.data!,count:Int($0.pointee.hdr.size_bytes)) }
            settings.exposure=1
            let edited=try processor.processHDR(url:source,settings:settings,previewLongEdge:256)
            preview.withPair { a in edited.withPair { b in
                let x=a.pointee.hdr.data!.assumingMemoryBound(to:Float.self),y=b.pointee.hdr.data!.assumingMemoryBound(to:Float.self)
                for i in 0..<(preview.width*preview.height*3) {
                    require(abs(y[i]-2*x[i])<=1e-5*max(1,abs(2*x[i])),"iOS exposure mapping")
                }
            } }
            let encoder=JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let record=try encoder.encode(settings),display=try HDRPresentation(edited)
            for h in [1.0,2.0,4.0,8.0] { _ = try display.rgba16F(HDRDisplayParameters(headroom:h)) }
            let after=preview.withPair { Data(bytes:$0.pointee.hdr.data!,count:Int($0.pointee.hdr.size_bytes)) }
            require(after==original,"display or render mutated source working image")
            let sameRecord=try encoder.encode(settings)
            require(sameRecord==record,"display changed editing record")
            let final=try processor.processHDR(url:source,settings:settings,previewLongEdge:nil,exportLongEdge:256)
            require(!final.isProxy && max(final.width,final.height)==256,"FINAL resize used a source proxy")
            let hdrURL=output.appendingPathComponent("hdr.jpg"),sdrURL=output.appendingPathComponent("sdr.jpg")
            try final.exportJPEG(to:hdrURL); try final.exportSDR(to:sdrURL,format:SONY2FUJI_OUTPUT_JPEG)
            let saved=try HDRSourceInfo.probe(hdrURL),compat=try HDRSourceInfo.probe(sdrURL)
            require(saved?.native.protocol==UInt32(SONY2FUJI_HDR_PROTOCOL_ISO_XMP) && compat==nil,"iOS output rendition or metadata")
            let sdr=try processor.loadRasterBuffer(url:source)
            let legacy=try processor.processBuffer(buffer:sdr.buffer,settings:.default,previewLongEdge:128,lutURL:nil)
            require(max(legacy.width,legacy.height)==128 && legacy.semantic == .display,"SDR-mode extraction did not enter existing SDR pipeline")
            let forced=Sony2FujiProcessor(gpuMode:SONY2FUJI_GPU_FORCE)
            do { _ = try forced.processHDR(url:source,settings:HDRSettings(),previewLongEdge:64); fatalError("Force bypassed by identity") }
            catch let error as HDRNativeError { require(error.reason==UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),"Force rejection") }
        }
        let unchanged=try Data(contentsOf:source)
        require(bytes==unchanged && info.fingerprint.count==32,"original changed")
        print("PASS iOS HDR typed preview, exposure, display isolation, full-source export, dual metadata, SDR rendition and Force policy")
    }
}
