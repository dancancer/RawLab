import Foundation
import CoreGraphics

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
}
