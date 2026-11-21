import RawLabKit
import Foundation
import UIKit

@main enum HDRProcessingTests {
    static func require(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        setbuf(stdout,nil)
        guard let path=ProcessInfo.processInfo.environment["RAWLAB_TEST_HDR"] else { fatalError("Pass RAWLAB_TEST_HDR original") }
        let source=URL(fileURLWithPath:path)
        let bytes=try Data(contentsOf:source)
        let info=try (HDRSourceInfo.probe(source) ?? HDRSourceInfo.probeRAW(source))!
        let processor=Sony2FujiProcessor(gpuMode:SONY2FUJI_GPU_OFF)
        let output=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        if info.proRAW != nil {
            var settings=HDRSettings()
            settings.geometry.quarterTurns=1; settings.geometry.straightenDegrees=7
            settings.geometry.cropWidth=0.5; settings.geometry.perspectiveHorizontal=0.12
            var edge=1280
            for _ in 0..<4 {
                let image=try processor.processHDR(url:source,settings:settings,previewLongEdge:edge)
                let next=max(image.width,image.height)
                require(next==1280,"ProRAW geometry preview shrinks on viewport feedback")
                require(image.isProxy && image.nativeWidth==Int(info.native.width) &&
                    image.nativeHeight==Int(info.native.height),"ProRAW preview lost original canvas")
                edge=next
            }
            let neutral=try processor.processHDR(url:source,settings:HDRSettings(),previewLongEdge:256)
            require(max(neutral.width,neutral.height)==256,"Identity bypass ignored ProRAW viewport size")
            var proExportSettings=HDRSettings(); proExportSettings.exposure=0.5
            let proHdrURL=output.appendingPathComponent("proraw-progress.jpg")
            var proProgress=[Double]()
            try processor.exportHDR(url:source,settings:proExportSettings,output:proHdrURL,longEdge:256,
                proRAWDecodeVersion:ProRAWSource.decodeVersion,format:.hdrJPEG,
                progress:{ proProgress.append($0) },cancelled:{ false })
            require(!proProgress.isEmpty && proProgress.allSatisfy { $0 >= 0 && $0 <= 1 },"ProRAW HDR export progress out of range")
            require(zip(proProgress,proProgress.dropFirst()).allSatisfy { $0.1 >= $0.0 },"ProRAW HDR export progress went backwards")
            require(proProgress.last==1,"ProRAW HDR export progress did not reach 1.0")
            let proHdrProbe = try HDRSourceInfo.probe(proHdrURL)
            require(proHdrProbe != nil,"ProRAW HDR export lost gain map")
            let proCancelURL=output.appendingPathComponent("proraw-cancel.jpg")
            var shouldCancel=false; var cancelledThrown=false
            do {
                try processor.exportHDR(url:source,settings:proExportSettings,output:proCancelURL,longEdge:256,
                    proRAWDecodeVersion:ProRAWSource.decodeVersion,format:.hdrJPEG,
                    progress:{ if $0 > 0 { shouldCancel=true } },cancelled:{ shouldCancel })
                fatalError("ProRAW HDR export cancellation did not throw")
            } catch is CancellationError { cancelledThrown=true }
            require(cancelledThrown && !FileManager.default.fileExists(atPath:proCancelURL.path),"Cancelled ProRAW export left output file")
            let proDngURL=output.appendingPathComponent("proraw-progress.dng")
            var dngProgress=[Double]()
            try processor.exportHDRDNG(url:source,settings:proExportSettings,output:proDngURL,longEdge:256,
                proRAWDecodeVersion:ProRAWSource.decodeVersion,progress:{ dngProgress.append($0) },cancelled:{ false })
            require(!dngProgress.isEmpty && zip(dngProgress,dngProgress.dropFirst()).allSatisfy { $0.1 >= $0.0 } && dngProgress.last==1,"ProRAW DNG progress contract failed")
            require(FileManager.default.fileExists(atPath:proDngURL.path),"ProRAW DNG export missing output")
            let proDngCancelURL=output.appendingPathComponent("proraw-dng-cancel.dng")
            var cancelDng=false; var dngCancelled=false
            do {
                try processor.exportHDRDNG(url:source,settings:proExportSettings,output:proDngCancelURL,longEdge:256,
                    proRAWDecodeVersion:ProRAWSource.decodeVersion,progress:{ if $0 > 0 { cancelDng=true } },cancelled:{ cancelDng })
                fatalError("ProRAW DNG cancellation did not throw")
            } catch is CancellationError { dngCancelled=true }
            require(dngCancelled && !FileManager.default.fileExists(atPath:proDngCancelURL.path),"Cancelled ProRAW DNG left output file")
            let unchanged=try Data(contentsOf:source)
            require(unchanged==bytes,"ProRAW original changed")
            print("PASS iOS ProRAW geometry preview converges, bounded identity/native canvas, and export progress/cancel")
            return
        }
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
            let exportHdrURL=output.appendingPathComponent("export-progress.jpg")
            var exportProgress=[Double]()
            try processor.exportHDR(url:source,settings:settings,output:exportHdrURL,longEdge:256,format:.hdrJPEG,
                progress:{ exportProgress.append($0) },cancelled:{ false })
            require(!exportProgress.isEmpty && exportProgress.allSatisfy { $0 >= 0 && $0 <= 1 } &&
                zip(exportProgress,exportProgress.dropFirst()).allSatisfy { $0.1 >= $0.0 } && exportProgress.last==1,
                "HDR export progress contract failed")
            let exportHdrProbe = try HDRSourceInfo.probe(exportHdrURL)
            require(exportHdrProbe != nil,"HDR export missing gain map")
            let cancelHdrURL=output.appendingPathComponent("export-cancel.jpg")
            var cancelHdr=false; var hdrCancelled=false
            do {
                try processor.exportHDR(url:source,settings:settings,output:cancelHdrURL,longEdge:256,format:.hdrJPEG,
                    progress:{ if $0 > 0 { cancelHdr=true } },cancelled:{ cancelHdr })
                fatalError("HDR export cancellation did not throw")
            } catch is CancellationError { hdrCancelled=true }
            require(hdrCancelled && !FileManager.default.fileExists(atPath:cancelHdrURL.path),"Cancelled HDR export left output file")
            let exportDngURL=output.appendingPathComponent("export-progress.dng")
            var dngProgress=[Double]()
            try processor.exportHDRDNG(url:source,settings:settings,output:exportDngURL,longEdge:256,
                progress:{ dngProgress.append($0) },cancelled:{ false })
            require(!dngProgress.isEmpty && zip(dngProgress,dngProgress.dropFirst()).allSatisfy { $0.1 >= $0.0 } && dngProgress.last==1,
                "HDR DNG export progress contract failed")
            require(FileManager.default.fileExists(atPath:exportDngURL.path),"HDR DNG output missing")
            let cancelDngURL=output.appendingPathComponent("export-dng-cancel.dng")
            var cancelDng=false; var dngCancelled=false
            do {
                try processor.exportHDRDNG(url:source,settings:settings,output:cancelDngURL,longEdge:256,
                    progress:{ if $0 > 0 { cancelDng=true } },cancelled:{ cancelDng })
                fatalError("HDR DNG export cancellation did not throw")
            } catch is CancellationError { dngCancelled=true }
            require(dngCancelled && !FileManager.default.fileExists(atPath:cancelDngURL.path),"Cancelled HDR DNG left output file")
        }
        let unchanged=try Data(contentsOf:source)
        require(bytes==unchanged && info.fingerprint.count==32,"original changed")
        print("PASS iOS HDR typed preview, exposure, display isolation, full-source export, dual metadata, SDR rendition, Force policy and progress/cancel")
    }
}
