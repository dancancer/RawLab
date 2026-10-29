import Foundation

@main enum HDRBridgeTests {
    static func require(_ condition: @autoclosure () -> Bool,_ text: String) { if !condition() { fatalError(text) } }
    static func main() throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1])
        let info=try HDRSourceInfo.probe(input)!
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        try autoreleasepool {
            let cache=HDRSourceCache(limit:16*1024)
            let preview=try cache.preview(input,info:info,longEdge:32)
            let same=try cache.preview(input,info:info,longEdge:32)
            require(preview===same && preview.isProxy && cache.bytes<=cache.limit,"preview cache duplicated/mislabelled source")
            _ = try cache.preview(input,info:info,longEdge:24)
            require(cache.bytes<=cache.limit,"preview LRU exceeded its byte limit")
            cache.clear()
            require(cache.bytes==0,"cache clear retained entries")
            let baseline=HDRImage.liveAllocations.count
            for index in 0..<20 {
                let next=directory.appendingPathComponent("switch-\(index).jpg")
                try FileManager.default.copyItem(at:input,to:next)
                try autoreleasepool {
                    let frame=try HDRSourceCache.shared.preview(next,info:info,longEdge:32)
                    _ = try HDRPresentation(frame).rgba16F(HDRDisplayParameters(headroom:2))
                    require(HDRSourceCache.shared.bytes<=128*1024*1024,"shared source cache exceeded its process budget")
                }
                require(HDRImage.liveAllocations.count==baseline+1,"previous source or display temporary survived a switch")
            }
            HDRSourceCache.shared.clear()
            require(HDRImage.liveAllocations.count==baseline,"clearing the process cache retained a source")
            let source=try HDRImage.decode(input,info:info,intent:SONY2FUJI_INTENT_FINAL)
            require(!source.isProxy && source.width==64 && source.height==32,"FINAL bridge reduced source")
            var session: OpaquePointer?
            require(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"session creation failed")
            defer { sony2fuji_session_destroy(session) }
            var settings=HDRSettings(); settings.exposure=1
            let result=try source.rendered(session:session!,settings:settings,intent:SONY2FUJI_INTENT_FINAL)
            var crop=HDRSettings(); crop.geometry.quarterTurns=1
            crop.geometry.cropWidth=0.5; crop.geometry.cropHeight=0.5
            let croppedPreview=try preview.rendered(session:session!,settings:crop,intent:SONY2FUJI_INTENT_PREVIEW)
            let croppedFinal=try source.rendered(session:session!,settings:crop,intent:SONY2FUJI_INTENT_FINAL)
            require(croppedPreview.outputNativeWidth==croppedFinal.width && croppedPreview.outputNativeHeight==croppedFinal.height,
                "preview crop lost the exact full-resolution output bounds")
            let presentation=try HDRPresentation(result)
            require(presentation.statistics.pixels==64*32,"presentation statistics dimensions")
            require(presentation.sdrImage.width==64 && presentation.sdrImage.height==32,"SDR fallback dimensions")
            for headroom in [1.0,2.0,4.0,8.0] {
                let packed=try presentation.rgba16F(HDRDisplayParameters(headroom:headroom))
                require(packed.count==64*32*8,"RGBA16F packing dimensions")
                packed.withUnsafeBytes { bytes in
                    let values=bytes.bindMemory(to:UInt16.self)
                    require(values.allSatisfy { $0 & 0x7c00 != 0x7c00 },"nonfinite display pack")
                }
            }
            source.withPair { a in result.withPair { b in
                let before=a.pointee.hdr.data!.assumingMemoryBound(to:Float.self)
                let after=b.pointee.hdr.data!.assumingMemoryBound(to:Float.self)
                for i in 0..<(source.width*source.height*3) {
                    require(abs(after[i]-2*before[i])<=1e-6*max(1,abs(2*before[i])),"bridge changed exposure semantics")
                }
            } }
            try result.exportJPEG(to:directory.appendingPathComponent("hdr.jpg"))
            try result.exportSDR(to:directory.appendingPathComponent("sdr.dng"),format:SONY2FUJI_OUTPUT_DNG)
            do { try preview.exportJPEG(to:directory.appendingPathComponent("proxy.jpg")); fatalError("preview exported as FINAL") }
            catch let error as HDRNativeError { require(error.reason==UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE),"wrong proxy diagnostic") }
        }
        require(HDRImage.liveAllocations.count==0 && HDRImage.liveAllocations.bytes==0,"HDR owners survived their scope")
        print("PASS Swift HDR ownership, source cache, full quality, export provenance and release")
    }
}
