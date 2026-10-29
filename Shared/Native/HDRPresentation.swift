import Foundation
import CoreGraphics

final class HDRPresentation: HDRDisplayImage {
    let image: HDRImage
    let statistics: HDRStatistics
    let sdrImage: CGImage
    var width: Int { image.width }
    var height: Int { image.height }

    init(_ image: HDRImage) throws {
        self.image=image
        statistics=try image.withPair { pair in
            let buffer=pair.pointee.hdr
            guard let pointer=buffer.data else { throw HDRDisplayFailure.invalidBuffer }
            return try HDRStatistics.analyze(UnsafeBufferPointer(start:pointer.assumingMemoryBound(to:Float.self),
                count:Int(buffer.size_bytes)/4),width:Int(buffer.width),height:Int(buffer.height),stride:Int(buffer.stride_bytes)/4)
        }
        sdrImage=try Self.makeSDRImage(image)
    }

    static func makeSDRImage(_ image: HDRImage) throws -> CGImage {
        try image.withPair { pair in
            let buffer=pair.pointee.sdr
            guard let pointer=buffer.data else { throw HDRDisplayFailure.invalidBuffer }
            let values=pointer.assumingMemoryBound(to:Float.self)
            var data=Data(count:image.width*image.height*4)
            data.withUnsafeMutableBytes { raw in
                let out=raw.bindMemory(to:UInt8.self)
                for y in 0..<image.height { for x in 0..<image.width {
                    let input=y*Int(buffer.stride_bytes)/4+x*3, output=(y*image.width+x)*4
                    for c in 0..<3 {
                        let v=min(1,max(0,values[input+c]))
                        let encoded=v<=0.0031308 ? 12.92*v : 1.055*pow(v,1/2.4)-0.055
                        out[output+c]=UInt8(min(255,max(0,(encoded*255).rounded())))
                    }
                    out[output+3]=255
                } }
            }
            guard let color=CGColorSpace(name:CGColorSpace.sRGB),let provider=CGDataProvider(data:data as CFData),
                  let cg=CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:32,
                    bytesPerRow:image.width*4,space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                    provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {
                throw HDRDisplayFailure.invalidBuffer
            }
            return cg
        }
    }

    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data {
        try image.withPair { pair in
            guard let hdr=pair.pointee.hdr.data?.assumingMemoryBound(to:Float.self),
                  let sdr=pair.pointee.sdr.data?.assumingMemoryBound(to:Float.self) else { throw HDRDisplayFailure.invalidBuffer }
            var bytes=Data(count:image.width*image.height*8)
            try bytes.withUnsafeMutableBytes { raw in
                let out=raw.bindMemory(to:UInt16.self)
                for y in 0..<image.height { for x in 0..<image.width {
                    let a=y*Int(pair.pointee.hdr.stride_bytes)/4+x*3
                    let b=y*Int(pair.pointee.sdr.stride_bytes)/4+x*3
                    let p=try HDRDisplayMath.pixel(hdr:SIMD3(hdr[a],hdr[a+1],hdr[a+2]),
                        sdr:SIMD3(sdr[b],sdr[b+1],sdr[b+2]),contentHeadroom:statistics.headroom,parameters:parameters)
                    let half=SIMD4<Float16>(Float16(p.x),Float16(p.y),Float16(p.z),1)
                    guard half.x.isFinite,half.y.isFinite,half.z.isFinite else { throw HDRDisplayFailure.unrepresentable }
                    let index=(y*image.width+x)*4
                    out[index]=half.x.bitPattern; out[index+1]=half.y.bitPattern
                    out[index+2]=half.z.bitPattern; out[index+3]=half.w.bitPattern
                } }
            }
            return bytes
        }
    }
}
