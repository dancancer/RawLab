import Foundation
import CoreGraphics
#if arch(x86_64)
import Accelerate
#endif

public protocol HDRDisplayImage: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var statistics: HDRStatistics { get }
    var sdrImage: CGImage { get }
    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data
}

public protocol HDRLinearDisplayImage: HDRDisplayImage {
    func withLinearPlanes<T>(
        _ body: (_ hdr: UnsafeBufferPointer<Float>, _ hdrStrideFloats: Int,
                 _ sdr: UnsafeBufferPointer<Float>, _ sdrStrideFloats: Int) throws -> T
    ) throws -> T
}

public enum HDRPreviewMode: String, CaseIterable { case automatic, sdr }
public enum HDRDisplayFailure: Error { case invalidBuffer, nonfinite, unrepresentable }

public struct HDRDisplayParameters: Equatable {
    public var headroom: Double
    public var mode=HDRPreviewMode.automatic
    public var falseColor=false
    public init(headroom: Double, mode: HDRPreviewMode = .automatic, falseColor: Bool = false) {
        self.headroom = headroom
        self.mode = mode
        self.falseColor = falseColor
    }
    public var safeHeadroom: Double { headroom.isFinite ? min(65504,max(1,headroom)) : 1 }
}

public struct HDRStatistics {
    public let bins: [Double]
    public let aboveWhite: Int
    public let headroom: Float
    public let pixels: Int
    public init(bins: [Double], aboveWhite: Int, headroom: Float, pixels: Int) {
        self.bins = bins; self.aboveWhite = aboveWhite; self.headroom = headroom; self.pixels = pixels
    }
    public static let minimumEV = -8.0
    public static let maximumEV = 8.0
    public static func position(headroom: Double) -> Double {
        min(1,max(0,(log2(max(1,headroom))-minimumEV)/(maximumEV-minimumEV)))
    }

    public static func analyze(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int, stride: Int) throws -> HDRStatistics {
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

public enum HDRDisplayMath {
    public static func luminance(_ p: SIMD3<Float>) -> Double { 0.2126*Double(p.x)+0.7152*Double(p.y)+0.0722*Double(p.z) }

    public static func pixel(hdr: SIMD3<Float>,sdr: SIMD3<Float>,contentHeadroom: Float,
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

    public static func half(_ p: SIMD3<Float>) throws -> SIMD4<UInt16> {
        #if arch(x86_64)
        // Intel Swift 没有可用的 Float16 运算；vImage 输出相同的 IEEE binary16 位模式。
        var input = SIMD4<Float>(p.x, p.y, p.z, 1)
        var bits = SIMD4<UInt16>(repeating: 0)
        let status = withUnsafeMutableBytes(of: &input) { source in
            withUnsafeMutableBytes(of: &bits) { destination in
                var sourceBuffer = vImage_Buffer(data: source.baseAddress!, height: 1, width: 4, rowBytes: source.count)
                var destinationBuffer = vImage_Buffer(data: destination.baseAddress!, height: 1, width: 4, rowBytes: destination.count)
                return vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageDoNotTile))
            }
        }
        guard status == kvImageNoError else { throw HDRDisplayFailure.invalidBuffer }
        #else
        let values = SIMD4<Float16>(Float16(p.x), Float16(p.y), Float16(p.z), 1)
        let bits = SIMD4(values.x.bitPattern, values.y.bitPattern, values.z.bitPattern, values.w.bitPattern)
        #endif
        guard bits.x & 0x7c00 != 0x7c00, bits.y & 0x7c00 != 0x7c00, bits.z & 0x7c00 != 0x7c00 else {
            throw HDRDisplayFailure.unrepresentable
        }
        return bits
    }
}

public struct PhotoDetailTileKey: Hashable, Sendable {
    public let level: Int
    public let col: Int
    public let row: Int

    public init(level: Int, col: Int, row: Int) {
        self.level = level
        self.col = col
        self.row = row
    }
}

public struct PhotoDetailTileSpec: Equatable, Sendable {
    public let key: PhotoDetailTileKey
    public let normalizedRect: CGRect
    public let maxOutputLongEdge: Int

    public init(key: PhotoDetailTileKey, normalizedRect: CGRect, maxOutputLongEdge: Int) {
        self.key = key
        self.normalizedRect = normalizedRect
        self.maxOutputLongEdge = maxOutputLongEdge
    }
}

public enum PhotoDetailTilePlan {
    public static let defaultTileSize = 1024

    public static func level(forZoomScale zoomScale: CGFloat, baseScale: CGFloat) -> Int? {
        guard zoomScale.isFinite, baseScale.isFinite, zoomScale > 0, min(1, zoomScale) > baseScale * 1.05 else {
            return nil
        }
        let threshold = baseScale * 1.05
        let skipLevel1Threshold = baseScale * 1.35
        if zoomScale >= 0.65 {
            return 0
        }
        if zoomScale >= 0.325 && 0.5 > skipLevel1Threshold {
            return 1
        }
        if 0.25 > threshold {
            return 2
        }
        if 0.5 > skipLevel1Threshold {
            return 1
        }
        return 0
    }

    private static func makeSpec(
        level: Int,
        col: Int,
        row: Int,
        nativeSpan: Int,
        levelScale: CGFloat,
        tileSize: Int,
        fullW: Int,
        fullH: Int
    ) -> PhotoDetailTileSpec? {
        let px0 = col * nativeSpan
        let px1 = min(fullW, px0 + nativeSpan)
        let py0 = row * nativeSpan
        let py1 = min(fullH, py0 + nativeSpan)
        guard px1 > px0, py1 > py0 else { return nil }
        let rect = CGRect(
            x: CGFloat(px0) / CGFloat(fullW),
            y: CGFloat(py0) / CGFloat(fullH),
            width: CGFloat(px1 - px0) / CGFloat(fullW),
            height: CGFloat(py1 - py0) / CGFloat(fullH)
        )
        let longSpan = max(px1 - px0, py1 - py0)
        let edge = min(tileSize, max(1, Int((Double(longSpan) * Double(levelScale)).rounded())))
        return PhotoDetailTileSpec(
            key: PhotoDetailTileKey(level: level, col: col, row: row),
            normalizedRect: rect,
            maxOutputLongEdge: edge
        )
    }

    public static func tiles(
        visibleRect: CGRect,
        fullNativeSize: CGSize,
        zoomScale: CGFloat,
        baseScale: CGFloat,
        tileSize: Int = defaultTileSize,
        overscanRing: Int = 0
    ) -> [PhotoDetailTileSpec] {
        guard let level = level(forZoomScale: zoomScale, baseScale: baseScale),
              tileSize > 0,
              fullNativeSize.width > 0, fullNativeSize.height > 0,
              visibleRect.width > 0, visibleRect.height > 0 else {
            return []
        }
        let fullW = Int(fullNativeSize.width.rounded())
        let fullH = Int(fullNativeSize.height.rounded())
        guard fullW > 0, fullH > 0 else { return [] }

        let levelScale = 1.0 / CGFloat(1 << level)
        let nativeSpan = tileSize << level
        let vx0 = max(0, min(fullW - 1, Int(floor(visibleRect.minX * CGFloat(fullW)))))
        let vy0 = max(0, min(fullH - 1, Int(floor(visibleRect.minY * CGFloat(fullH)))))
        let vx1 = max(vx0 + 1, min(fullW, Int(ceil(visibleRect.maxX * CGFloat(fullW)))))
        let vy1 = max(vy0 + 1, min(fullH, Int(ceil(visibleRect.maxY * CGFloat(fullH)))))

        let maxCol = (fullW - 1) / nativeSpan
        let maxRow = (fullH - 1) / nativeSpan
        let colMin = max(0, vx0 / nativeSpan)
        let colMax = min(maxCol, max(0, (vx1 - 1) / nativeSpan))
        let rowMin = max(0, vy0 / nativeSpan)
        let rowMax = min(maxRow, max(0, (vy1 - 1) / nativeSpan))

        let targetX = visibleRect.midX
        let targetY = visibleRect.midY
        let sortByDistance: (PhotoDetailTileSpec, PhotoDetailTileSpec) -> Bool = { a, b in
            let dxA = a.normalizedRect.midX - targetX
            let dyA = a.normalizedRect.midY - targetY
            let dxB = b.normalizedRect.midX - targetX
            let dyB = b.normalizedRect.midY - targetY
            return (dxA * dxA + dyA * dyA) < (dxB * dxB + dyB * dyB)
        }

        var visibleSpecs: [PhotoDetailTileSpec] = []
        visibleSpecs.reserveCapacity((colMax - colMin + 1) * (rowMax - rowMin + 1))
        for row in rowMin...rowMax {
            for col in colMin...colMax {
                if let spec = makeSpec(
                    level: level, col: col, row: row,
                    nativeSpan: nativeSpan, levelScale: levelScale, tileSize: tileSize,
                    fullW: fullW, fullH: fullH
                ) {
                    visibleSpecs.append(spec)
                }
            }
        }
        visibleSpecs.sort(by: sortByDistance)
        guard overscanRing > 0 else { return visibleSpecs }

        let seen = Set(visibleSpecs.map(\.key))
        let oColMin = max(0, colMin - overscanRing)
        let oColMax = min(maxCol, colMax + overscanRing)
        let oRowMin = max(0, rowMin - overscanRing)
        let oRowMax = min(maxRow, rowMax + overscanRing)
        var overscanSpecs: [PhotoDetailTileSpec] = []
        for row in oRowMin...oRowMax {
            for col in oColMin...oColMax {
                let key = PhotoDetailTileKey(level: level, col: col, row: row)
                guard !seen.contains(key),
                      let spec = makeSpec(
                          level: level, col: col, row: row,
                          nativeSpan: nativeSpan, levelScale: levelScale, tileSize: tileSize,
                          fullW: fullW, fullH: fullH
                      ) else {
                    continue
                }
                overscanSpecs.append(spec)
            }
        }
        overscanSpecs.sort(by: sortByDistance)
        return visibleSpecs + overscanSpecs
    }

    public static func level0Grid(
        fullNativeSize: CGSize,
        tileSize: Int = defaultTileSize
    ) -> [PhotoDetailTileSpec] {
        guard tileSize > 0, fullNativeSize.width > 0, fullNativeSize.height > 0 else { return [] }
        let fullW = Int(fullNativeSize.width.rounded())
        let fullH = Int(fullNativeSize.height.rounded())
        guard fullW > 0, fullH > 0 else { return [] }
        let maxCol = (fullW - 1) / tileSize
        let maxRow = (fullH - 1) / tileSize
        var specs: [PhotoDetailTileSpec] = []
        specs.reserveCapacity((maxCol + 1) * (maxRow + 1))
        for row in 0...maxRow {
            for col in 0...maxCol {
                if let spec = makeSpec(
                    level: 0, col: col, row: row,
                    nativeSpan: tileSize, levelScale: 1, tileSize: tileSize,
                    fullW: fullW, fullH: fullH
                ) {
                    specs.append(spec)
                }
            }
        }
        return specs.sorted { a, b in
            let dxA = a.normalizedRect.midX - 0.5
            let dyA = a.normalizedRect.midY - 0.5
            let dxB = b.normalizedRect.midX - 0.5
            let dyB = b.normalizedRect.midY - 0.5
            return (dxA * dxA + dyA * dyA) < (dxB * dxB + dyB * dyB)
        }
    }
}

public struct PhotoDetailBacking {
    public let cgImage: CGImage
    public let beforeCGImage: CGImage?
    public let pixelSize: CGSize
    public let fullNativeSize: CGSize
    public let renderID: UUID

    public init(
        cgImage: CGImage,
        beforeCGImage: CGImage? = nil,
        pixelSize: CGSize,
        fullNativeSize: CGSize,
        renderID: UUID
    ) {
        self.cgImage = cgImage
        self.beforeCGImage = beforeCGImage
        self.pixelSize = pixelSize
        self.fullNativeSize = fullNativeSize
        self.renderID = renderID
    }
}

public struct PhotoDetailRequest: Equatable, Sendable {
    public let visibleRect: CGRect
    public let overscanRect: CGRect
    public let zoomScale: CGFloat
    public let baseScale: CGFloat
    public let maxOutputLongEdge: Int

    public init(visibleRect: CGRect, overscanRect: CGRect, zoomScale: CGFloat, baseScale: CGFloat, maxOutputLongEdge: Int) {
        self.visibleRect = visibleRect
        self.overscanRect = overscanRect
        self.zoomScale = zoomScale
        self.baseScale = baseScale
        self.maxOutputLongEdge = maxOutputLongEdge
    }
}

public struct PhotoDetailOverlay {
    public let cgImage: CGImage?
    public let beforeCGImage: CGImage?
    public let hdr: HDRDisplayImage?
    public let beforeHDR: HDRDisplayImage?
    public let normalizedRect: CGRect
    public let pixelSize: CGSize
    public let fullNativeSize: CGSize
    public let renderID: UUID?
    public let tileKey: PhotoDetailTileKey?

    public init(
        cgImage: CGImage?,
        beforeCGImage: CGImage?,
        hdr: HDRDisplayImage?,
        beforeHDR: HDRDisplayImage?,
        normalizedRect: CGRect,
        pixelSize: CGSize,
        fullNativeSize: CGSize,
        renderID: UUID?,
        tileKey: PhotoDetailTileKey? = nil
    ) {
        self.cgImage = cgImage
        self.beforeCGImage = beforeCGImage
        self.hdr = hdr
        self.beforeHDR = beforeHDR
        self.normalizedRect = normalizedRect
        self.pixelSize = pixelSize
        self.fullNativeSize = fullNativeSize
        self.renderID = renderID
        self.tileKey = tileKey
    }

    public func covers(visibleRect: CGRect, requiredZoomScale: CGFloat, maxOutputLongEdge: Int? = nil) -> Bool {
        let tolerance: CGFloat = 0.0005
        guard normalizedRect.minX <= visibleRect.minX + tolerance,
              normalizedRect.minY <= visibleRect.minY + tolerance,
              normalizedRect.maxX >= visibleRect.maxX - tolerance,
              normalizedRect.maxY >= visibleRect.maxY - tolerance,
              normalizedRect.width > 0,
              fullNativeSize.width > 0 else {
            return false
        }
        let tileDensity = pixelSize.width / (normalizedRect.width * fullNativeSize.width)
        let nativeW = normalizedRect.width * fullNativeSize.width
        let nativeH = normalizedRect.height * fullNativeSize.height
        let maxAchievable: CGFloat = maxOutputLongEdge.map {
            $0 > 0 ? min(1, CGFloat($0) / max(1, max(nativeW, nativeH))) : 1
        } ?? 1
        let neededDensity = min(1, requiredZoomScale, maxAchievable)
        return tileDensity >= neededDensity * 0.9
    }
}
