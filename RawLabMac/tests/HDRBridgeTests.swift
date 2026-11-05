import Foundation
import CoreImage
import ImageIO

@main enum HDRBridgeTests {
    static func require(_ condition: @autoclosure () -> Bool,_ text: String) { if !condition() { fatalError(text) } }
    static func verifyProRAWRows(_ image: HDRImage, edge: Int) {
        let raw = CIRAWFilter(imageURL: image.sourceURL)!
        raw.scaleFactor = Float(edge) / Float(max(image.nativeWidth, image.nativeHeight))
        let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: color])
        for isHDR in [true, false] {
            raw.extendedDynamicRangeAmount = isHDR ? 1 : 0
            let reference = raw.outputImage!
            var rgba = [Float](repeating: 0, count: image.width * image.height * 4)
            rgba.withUnsafeMutableBytes {
                context.render(reference, toBitmap: $0.baseAddress!, rowBytes: image.width * 16,
                               bounds: reference.extent.integral, format: .RGBAf, colorSpace: color)
            }
            image.withPair { pair in
                let buffer = isHDR ? pair.pointee.hdr : pair.pointee.sdr
                let pixels = buffer.data!.assumingMemoryBound(to: Float.self)
                var error: Float = 0
                for pixel in 0..<(image.width * image.height) {
                    for channel in 0..<3 {
                        let value = rgba[pixel * 4 + channel]
                        let expected = isHDR ? value : min(1, max(0, value))
                        error = max(error, abs(pixels[pixel * 3 + channel] - expected))
                    }
                }
                require(error < 0.001, "ProRAW tile rows differ from whole-image rendering: \(error)")
            }
        }
    }
    static func verifyProRAWMetadata(source: URL, output: URL, width: Int, height: Int) {
        func properties(_ url: URL) -> NSDictionary {
            CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)! as NSDictionary
        }
        let original = properties(source), saved = properties(output)
        let originalTIFF = original[kCGImagePropertyTIFFDictionary] as! NSDictionary
        let savedTIFF = saved[kCGImagePropertyTIFFDictionary] as? NSDictionary
        require(savedTIFF?[kCGImagePropertyTIFFModel] as? String == originalTIFF[kCGImagePropertyTIFFModel] as? String,
                "ProRAW camera model was lost")
        let originalExif = original[kCGImagePropertyExifDictionary] as! NSDictionary
        let savedExif = saved[kCGImagePropertyExifDictionary] as? NSDictionary
        for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
                    kCGImagePropertyExifFocalLength, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel] {
            if let value = originalExif[key] as? NSObject {
                if let expected = value as? NSNumber, let actual = savedExif?[key] as? NSNumber {
                    require(abs(expected.doubleValue - actual.doubleValue) <= max(1e-10, abs(expected.doubleValue) * 1e-6),
                            "ProRAW numeric EXIF changed: \(key)")
                } else {
                    require(value.isEqual(savedExif?[key]), "ProRAW shooting EXIF was lost or changed: \(key), source=\(value), saved=\(String(describing: savedExif?[key]))")
                }
            }
        }
        require(savedExif?[kCGImagePropertyExifPixelXDimension] as? Int == width &&
                savedExif?[kCGImagePropertyExifPixelYDimension] as? Int == height, "Stale ProRAW EXIF canvas")
        require(saved[kCGImagePropertyOrientation] as? Int == 1, "ProRAW orientation was applied twice")
        require(savedExif?[kCGImagePropertyExifMakerNote] == nil && savedExif?[kCGImagePropertyExifCFAPattern] == nil,
                "ProRAW sensor metadata leaked into rendered JPEG")
    }
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
            let camera = directory.appendingPathComponent("camera.dng")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: camera)
            let cameraInfo = try HDRSourceInfo.probeCameraRAW(camera)!
            require(cameraInfo.isCameraRAW && (try? HDRSourceInfo.probe(camera)) == nil,
                    "camera RAW changed ordinary raster HDR detection")
            let cameraPreview = try cache.preview(camera, info: cameraInfo, longEdge: 32)
            require(cameraPreview.isProxy && cameraPreview.width == 32 && cameraPreview.nativeWidth == 128,
                    "camera RAW preview lost its bounds or native size")
            let cameraFinal = try HDRImage.decode(camera, info: cameraInfo, intent: SONY2FUJI_INTENT_FINAL)
            let cameraHDR = directory.appendingPathComponent("camera-hdr.jpg")
            let cameraSDR = directory.appendingPathComponent("camera-sdr.jpg")
            try cameraFinal.exportJPEG(to: cameraHDR)
            try cameraFinal.exportSDR(to: cameraSDR, format: SONY2FUJI_OUTPUT_JPEG)
            require((try? HDRSourceInfo.probe(cameraHDR)) != nil && (try? HDRSourceInfo.probe(cameraSDR)) == nil,
                    "camera RAW exports used the wrong JPEG rendition")
            cache.clear()
            do { try preview.exportJPEG(to:directory.appendingPathComponent("proxy.jpg")); fatalError("preview exported as FINAL") }
            catch let error as HDRNativeError { require(error.reason==UInt32(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE),"wrong proxy diagnostic") }
        }
        require(HDRImage.liveAllocations.count==0 && HDRImage.liveAllocations.bytes==0,"HDR owners survived their scope")
        for path in CommandLine.arguments.dropFirst(3) {
            try autoreleasepool {
                let url = URL(fileURLWithPath: path)
                guard let info = try HDRSourceInfo.probeRAW(url), info.proRAW != nil else { fatalError("ProRAW fixture was not recognized") }
                let allocationCount = HDRImage.liveAllocations.count
                var checkpoints = 0
                do {
                    _ = try HDRImage.decode(url, info: info, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: 320) {
                        checkpoints += 1
                        return checkpoints == 3
                    }
                    fatalError("ProRAW decode ignored cancellation")
                } catch is CancellationError {
                    require(HDRImage.liveAllocations.count == allocationCount, "cancelled ProRAW decode published a frame")
                }
                let preview = try HDRImage.decode(url, info: info, intent: SONY2FUJI_INTENT_PREVIEW, longEdge: 640)
                require(preview.isProxy && max(preview.width, preview.height) <= 640, "ProRAW preview exceeded its bounds")
                verifyProRAWRows(preview, edge: 640)
                let final = try HDRImage.decode(url, info: info, intent: SONY2FUJI_INTENT_FINAL)
                require(!final.isProxy && final.width == final.nativeWidth && final.height == final.nativeHeight,
                        "ProRAW FINAL lost its oriented canvas")
                require(final.editedHeadroom > 1, "ProRAW lost values above reference white")
                var session: OpaquePointer?
                require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "session creation failed")
                defer { sony2fuji_session_destroy(session) }
                var settings = HDRSettings(); settings.exposure = 0.25
                let result = try final.rendered(session: session!, settings: settings, intent: SONY2FUJI_INTENT_FINAL)
                require(result.editedHeadroom > final.editedHeadroom, "ProRAW exposure did not reach shared HDR rendering")
                let hdr = directory.appendingPathComponent("proraw-hdr.jpg")
                let sdr = directory.appendingPathComponent("proraw-sdr.jpg")
                try result.exportJPEG(to: hdr)
                try result.exportSDR(to: sdr, format: SONY2FUJI_OUTPUT_JPEG)
                verifyProRAWMetadata(source: url, output: hdr, width: final.width, height: final.height)
                verifyProRAWMetadata(source: url, output: sdr, width: final.width, height: final.height)
                let decodedInfo = try HDRSourceInfo.probe(hdr)!
                let decoded = try HDRImage.decode(hdr, info: decodedInfo, intent: SONY2FUJI_INTENT_FINAL)
                require(decoded.width == final.width && decoded.height == final.height && decoded.editedHeadroom > 1,
                        "ProRAW gain-map round trip lost dimensions or highlights")
                let sdrInfo = try HDRSourceInfo.probe(sdr)
                require(sdrInfo == nil, "ProRAW SDR JPEG unexpectedly contained a gain map")
                print("PASS ProRAW \(final.width)x\(final.height) preview, edit and JPEG round trip")
            }
        }
        print("PASS Swift HDR ownership, source cache, full quality, export provenance and release")
    }
}
