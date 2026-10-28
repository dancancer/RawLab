import Foundation
import CoreGraphics

protocol HDRDisplayImage: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var statistics: HDRStatistics { get }
    var sdrImage: CGImage { get }
    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data
}

enum HDRPreviewMode: String, CaseIterable { case automatic, sdr }
enum HDRDisplayFailure: Error { case invalidBuffer, nonfinite, unrepresentable }

struct HDRDisplayParameters: Equatable {
    var headroom: Double
    var mode=HDRPreviewMode.automatic
    var falseColor=false
    var safeHeadroom: Double { headroom.isFinite ? min(65504,max(1,headroom)) : 1 }
}

struct HDRStatistics {
    let bins: [Double]
    let aboveWhite: Int
    let headroom: Float
    let pixels: Int
    static let minimumEV = -8.0
    static let maximumEV = 8.0
    static func position(headroom: Double) -> Double {
        min(1,max(0,(log2(max(1,headroom))-minimumEV)/(maximumEV-minimumEV)))
    }

    static func analyze(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int, stride: Int) throws -> HDRStatistics {
        guard width>0, height>0, width<=128000000/height, stride>=width*3,
              height-1<=(Int.max-width*3)/stride, values.count>=(height-1)*stride+width*3 else {
            throw HDRDisplayFailure.invalidBuffer
        }
        var bins=[Double](repeating:0,count:256), above=0
        var peak: Float=1
        for row in 0..<height { for column in 0..<width {
            let index=row*stride+column*3
            let p=SIMD3(values[index],values[index+1],values[index+2])
            guard p.x.isFinite,p.y.isFinite,p.z.isFinite else { throw HDRDisplayFailure.nonfinite }
            let luminance=HDRDisplayMath.luminance(p)
            guard luminance.isFinite else { throw HDRDisplayFailure.nonfinite }
            let ev=luminance>0 ? log2(luminance) : minimumEV
            let bin=min(255,max(0,Int((min(maximumEV,max(minimumEV,ev))-minimumEV)*16)))
            bins[bin]+=1
            if luminance>1 { above+=1 }
            peak=max(peak,Float(luminance))
        } }
        guard peak.isFinite else { throw HDRDisplayFailure.nonfinite }
        return HDRStatistics(bins:bins,aboveWhite:above,headroom:peak,pixels:width*height)
    }
}

enum HDRDisplayMath {
    static func luminance(_ p: SIMD3<Float>) -> Double { 0.2126*Double(p.x)+0.7152*Double(p.y)+0.0722*Double(p.z) }

    static func pixel(hdr: SIMD3<Float>,sdr: SIMD3<Float>,contentHeadroom: Float,
                      parameters: HDRDisplayParameters) throws -> SIMD3<Float> {
        guard hdr.x.isFinite,hdr.y.isFinite,hdr.z.isFinite,sdr.x.isFinite,sdr.y.isFinite,sdr.z.isFinite,
              contentHeadroom.isFinite,contentHeadroom>=1 else { throw HDRDisplayFailure.nonfinite }
        let h=parameters.safeHeadroom, y=luminance(hdr)
        if parameters.falseColor {
            if y>h { return SIMD3(1,0,0.35) }
            if y>1 { return SIMD3(1,0.6,0) }
            if y<=0.01 { return SIMD3(0.02,0.15,0.7) }
            let gray: Float=0.35; return SIMD3(repeating:gray)
        }
        let isHDR=parameters.mode == .automatic && h>1
        var value=isHDR ? hdr : sdr
        let c=Double(contentHeadroom)
        if isHDR && y>1 && c>h {
            // 保持参考白和该点一阶导数；仅显示肩部把内容峰值映射到当前屏幕容量。
            let a=(c-h)/((h-1)*(c-1))
            let mapped=1+(y-1)/(1+a*(y-1))
            value *= Float(mapped/y)
        }
        // D65 线性 sRGB -> Display P3，保留灰轴；窗口颜色管理再匹配实际屏幕。
        let p=SIMD3<Float>(
            Float(0.8224619687143623*Double(value.x)+0.17753803128563775*Double(value.y)),
            Float(0.03319419885096156*Double(value.x)+0.9668058011490385*Double(value.y)),
            Float(0.01708263072112004*Double(value.x)+0.07239744066396347*Double(value.y)+0.9105199286149166*Double(value.z)))
        if isHDR { return p }
        return SIMD3(min(1,max(0,p.x)),min(1,max(0,p.y)),min(1,max(0,p.z)))
    }

    static func half(_ p: SIMD3<Float>) throws -> [UInt16] {
        let values=[Float16(p.x),Float16(p.y),Float16(p.z),Float16(1)]
        guard values.allSatisfy(\.isFinite) else { throw HDRDisplayFailure.unrepresentable }
        return values.map(\.bitPattern)
    }
}
