@_exported import CSony2Fuji
@_exported import RawLabNativeTypes
import CoreGraphics
import Foundation
import RawLabKit

private func makeNativeSampleStorage() -> sony2fuji_inspection_sample {
    var s = sony2fuji_inspection_sample()
    s.version = UInt32(SONY2FUJI_INSPECTION_SAMPLE_VERSION)
    s.struct_size = UInt32(MemoryLayout<sony2fuji_inspection_sample>.size)
    return s
}

private extension InspectionColorSample {
    init(native: sony2fuji_inspection_sample) {
        self.init(
            r: native.r,
            g: native.g,
            b: native.b,
            hueDeg: native.hue_deg,
            saturationPct: native.saturation_pct,
            brightnessPct: native.brightness_pct,
            luminance: native.luminance
        )
    }
}

private extension InspectionOverlayMode {
    var nativeMode: sony2fuji_inspection_overlay_mode {
        switch self {
        case .none: return SONY2FUJI_INSPECTION_OVERLAY_NONE
        case .sketchLuminance: return SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE
        case .warmCoolBW: return SONY2FUJI_INSPECTION_OVERLAY_WARM_COOL_BW
        case .oversaturationHeatmap: return SONY2FUJI_INSPECTION_OVERLAY_OVERSATURATION_HEATMAP
        case .skinHueAmplification: return SONY2FUJI_INSPECTION_OVERLAY_SKIN_HUE_AMPLIFICATION
        case .neutralGray50: return SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50
        }
    }
}

public extension InspectionColorSample {
    init(r: UInt8, g: UInt8, b: UInt8) {
        var native = makeNativeSampleStorage()
        let status = sony2fuji_inspection_color_from_rgb(r, g, b, &native)
        if status == SONY2FUJI_STATUS_OK {
            self.init(native: native)
        } else {
            self.init(r: r, g: g, b: b, hueDeg: 0, saturationPct: 0, brightnessPct: 0, luminance: 0)
        }
    }
}

public enum GeometryCoordinateMapper {
    public static func outputSize(sourceSize: CGSize, geometry: GeometrySettings) -> CGSize {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 1, sourceSize.height >= 1 else {
            return .zero
        }
        let w = UInt32(max(1, Int(sourceSize.width.rounded())))
        let h = UInt32(max(1, Int(sourceSize.height.rounded())))
        var geom = geometry.nativeConfig
        var persp = geometry.nativePerspectiveConfig
        var outW: UInt32 = 0
        var outH: UInt32 = 0
        guard sony2fuji_geometry_output_size(w, h, &geom, &persp, &outW, &outH) == SONY2FUJI_STATUS_OK else {
            return .zero
        }
        return CGSize(width: Int(outW), height: Int(outH))
    }

    public static func inferSourceSize(outputSize: CGSize, geometry: GeometrySettings) -> CGSize {
        let safeW = outputSize.width.isFinite ? max(1.0, outputSize.width.rounded()) : 1.0
        let safeH = outputSize.height.isFinite ? max(1.0, outputSize.height.rounded()) : 1.0
        var geom = geometry.nativeConfig
        var persp = geometry.nativePerspectiveConfig
        var srcW: UInt32 = 0
        var srcH: UInt32 = 0
        let status = sony2fuji_geometry_infer_source_size(
            UInt32(max(1, Int(safeW))),
            UInt32(max(1, Int(safeH))),
            &geom,
            &persp,
            &srcW,
            &srcH
        )
        guard status == SONY2FUJI_STATUS_OK, srcW > 0, srcH > 0 else {
            return CGSize(width: safeW, height: safeH)
        }
        return CGSize(width: Int(srcW), height: Int(srcH))
    }

    public static func outputNormToSourceNorm(
        _ outPoint: CGPoint,
        sourceSize: CGSize,
        geometry: GeometrySettings
    ) -> CGPoint? {
        guard outPoint.x.isFinite, outPoint.y.isFinite,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 1, sourceSize.height >= 1 else {
            return nil
        }
        var geom = geometry.nativeConfig
        var persp = geometry.nativePerspectiveConfig
        var srcX = 0.0
        var srcY = 0.0
        var valid: Int32 = 0
        let status = sony2fuji_geometry_output_norm_to_source_norm(
            UInt32(max(1, Int(sourceSize.width.rounded()))),
            UInt32(max(1, Int(sourceSize.height.rounded()))),
            &geom,
            &persp,
            Double(outPoint.x),
            Double(outPoint.y),
            &srcX,
            &srcY,
            &valid
        )
        guard status == SONY2FUJI_STATUS_OK, valid != 0 else { return nil }
        return CGPoint(x: srcX, y: srcY)
    }

    public static func sourceNormToOutputNorm(
        _ srcPoint: CGPoint,
        sourceSize: CGSize,
        geometry: GeometrySettings
    ) -> CGPoint? {
        guard srcPoint.x.isFinite, srcPoint.y.isFinite,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width >= 1, sourceSize.height >= 1 else {
            return nil
        }
        var geom = geometry.nativeConfig
        var persp = geometry.nativePerspectiveConfig
        var outX = 0.0
        var outY = 0.0
        var valid: Int32 = 0
        let status = sony2fuji_geometry_source_norm_to_output_norm(
            UInt32(max(1, Int(sourceSize.width.rounded()))),
            UInt32(max(1, Int(sourceSize.height.rounded()))),
            &geom,
            &persp,
            Double(srcPoint.x),
            Double(srcPoint.y),
            &outX,
            &outY,
            &valid
        )
        guard status == SONY2FUJI_STATUS_OK, valid != 0 else { return nil }
        return CGPoint(x: outX, y: outY)
    }
}

private struct RGBA8PixelBuffer: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let isSRGB = cgImage.colorSpace?.name == CGColorSpace.sRGB
        let alpha = cgImage.alphaInfo
        let order = cgImage.bitmapInfo.intersection(.byteOrderMask)
        let isDefaultOr32Big = order == .byteOrderDefault || order == .byteOrder32Big
        if isSRGB,
           cgImage.bitsPerComponent == 8,
           cgImage.bitsPerPixel == 32,
           isDefaultOr32Big,
           alpha == .last || alpha == .noneSkipLast,
           let providerData = cgImage.dataProvider?.data {
            let data = providerData as Data
            let rowStride = cgImage.bytesPerRow
            if rowStride >= width * 4, data.count >= rowStride * (height - 1) + width * 4 {
                self.width = width
                self.height = height
                self.bytesPerRow = rowStride
                self.bytes = data
                return
            }
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rowStride = width * 4
        var buffer = Data(count: rowStride * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return false }
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowStride,
                space: space,
                bitmapInfo: info
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = rowStride
        self.bytes = buffer
    }
}

public final class InspectionSamplerCache: @unchecked Sendable {
    public static let shared = InspectionSamplerCache()

    private struct Entry {
        let image: CGImage
        let buffer: RGBA8PixelBuffer
    }

    private let lock = NSLock()
    private let maxEntries: Int
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var lru: [ObjectIdentifier] = []

    public init(maxEntries: Int = 6) {
        self.maxEntries = max(1, maxEntries)
    }

    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    public func sample(_ cgImage: CGImage, atNormalized point: CGPoint, radiusPixels: Int = 1) -> InspectionColorSample? {
        guard point.x.isFinite, point.y.isFinite,
              let buf = buffer(for: cgImage) else {
            return nil
        }
        var sample = makeNativeSampleStorage()
        let radius = UInt32(max(0, radiusPixels))
        let status = buf.bytes.withUnsafeBytes { rawPtr -> sony2fuji_status in
            guard let ptr = rawPtr.baseAddress else { return SONY2FUJI_STATUS_INVALID_ARGUMENT }
            var nativeBuf = sony2fuji_buffer(
                data: UnsafeMutableRawPointer(mutating: ptr),
                size_bytes: buf.bytes.count,
                width: UInt32(buf.width),
                height: UInt32(buf.height),
                stride_bytes: UInt32(buf.bytesPerRow),
                pixel_format: SONY2FUJI_PIXEL_RGBA8
            )
            return sony2fuji_inspection_sample_patch(&nativeBuf, Double(point.x), Double(point.y), radius, &sample)
        }
        return status == SONY2FUJI_STATUS_OK ? InspectionColorSample(native: sample) : nil
    }

    fileprivate func buffer(for cgImage: CGImage) -> RGBA8PixelBuffer? {
        let key = ObjectIdentifier(cgImage)
        lock.lock()
        if let existing = entries[key], existing.image === cgImage {
            lru.removeAll { $0 == key }
            lru.append(key)
            lock.unlock()
            return existing.buffer
        }
        lock.unlock()

        guard let decoded = RGBA8PixelBuffer(cgImage: cgImage) else { return nil }

        lock.lock()
        entries[key] = Entry(image: cgImage, buffer: decoded)
        lru.removeAll { $0 == key }
        lru.append(key)
        while lru.count > maxEntries {
            let evicted = lru.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        lock.unlock()
        return decoded
    }
}

public final class InspectionOverlayRenderer: @unchecked Sendable {
    public static let shared = InspectionOverlayRenderer()

    private struct CacheKey: Hashable {
        let imageID: ObjectIdentifier
        let mode: InspectionOverlayMode
    }

    private struct CacheEntry {
        let source: CGImage
        let rendered: CGImage
    }

    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.rawlab.inspection.overlay", qos: .userInitiated, attributes: .concurrent)
    private let maxEntries: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var lru: [CacheKey] = []

    public init(maxEntries: Int = 24) {
        self.maxEntries = max(1, maxEntries)
    }

    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public func clear() {
        lock.lock()
        cache.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    public func cached(_ image: CGImage, mode: InspectionOverlayMode) -> CGImage? {
        if mode == .none { return image }
        let key = CacheKey(imageID: ObjectIdentifier(image), mode: mode)
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key], existing.source === image {
            lru.removeAll { $0 == key }
            lru.append(key)
            return existing.rendered
        }
        return nil
    }

    public func renderAsync(_ image: CGImage, mode: InspectionOverlayMode, completion: @escaping @Sendable (CGImage?) -> Void) {
        if let hit = cached(image, mode: mode) {
            completion(hit)
            return
        }
        renderQueue.async { [weak self] in
            let rendered = self?.render(image, mode: mode)
            completion(rendered)
        }
    }

    public static func applyOverlayPixel(r: UInt8, g: UInt8, b: UInt8, mode: InspectionOverlayMode) -> (UInt8, UInt8, UInt8) {
        var outR: UInt8 = r
        var outG: UInt8 = g
        var outB: UInt8 = b
        _ = sony2fuji_inspection_overlay_pixel(r, g, b, mode.nativeMode, &outR, &outG, &outB)
        return (outR, outG, outB)
    }

    public static func applyOverlayRGBA8(
        src: UnsafePointer<UInt8>,
        dst: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        srcBytesPerRow: Int,
        dstBytesPerRow: Int,
        mode: InspectionOverlayMode
    ) {
        guard width > 0, height > 0, srcBytesPerRow >= width * 4, dstBytesPerRow >= width * 4 else { return }
        var srcBuf = sony2fuji_buffer(
            data: UnsafeMutableRawPointer(mutating: src),
            size_bytes: srcBytesPerRow * (height - 1) + width * 4,
            width: UInt32(width),
            height: UInt32(height),
            stride_bytes: UInt32(srcBytesPerRow),
            pixel_format: SONY2FUJI_PIXEL_RGBA8
        )
        var dstBuf = sony2fuji_buffer(
            data: UnsafeMutableRawPointer(dst),
            size_bytes: dstBytesPerRow * (height - 1) + width * 4,
            width: UInt32(width),
            height: UInt32(height),
            stride_bytes: UInt32(dstBytesPerRow),
            pixel_format: SONY2FUJI_PIXEL_RGBA8
        )
        _ = sony2fuji_inspection_render_overlay(&srcBuf, mode.nativeMode, &dstBuf)
    }

    public func render(_ image: CGImage, mode: InspectionOverlayMode) -> CGImage? {
        if mode == .none { return image }
        let key = CacheKey(imageID: ObjectIdentifier(image), mode: mode)
        lock.lock()
        if let existing = cache[key], existing.source === image {
            lru.removeAll { $0 == key }
            lru.append(key)
            lock.unlock()
            return existing.rendered
        }
        lock.unlock()

        guard let buffer = InspectionSamplerCache.shared.buffer(for: image),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let width = buffer.width
        let height = buffer.height
        let dstBytesPerRow = width * 4
        var outData = Data(count: dstBytesPerRow * height)
        let status = buffer.bytes.withUnsafeBytes { srcRaw -> sony2fuji_status in
            outData.withUnsafeMutableBytes { dstRaw -> sony2fuji_status in
                guard let srcPtr = srcRaw.baseAddress,
                      let dstPtr = dstRaw.baseAddress else { return SONY2FUJI_STATUS_INVALID_ARGUMENT }
                var srcBuf = sony2fuji_buffer(
                    data: UnsafeMutableRawPointer(mutating: srcPtr),
                    size_bytes: buffer.bytes.count,
                    width: UInt32(width),
                    height: UInt32(height),
                    stride_bytes: UInt32(buffer.bytesPerRow),
                    pixel_format: SONY2FUJI_PIXEL_RGBA8
                )
                var dstBuf = sony2fuji_buffer(
                    data: dstPtr,
                    size_bytes: dstBytesPerRow * height,
                    width: UInt32(width),
                    height: UInt32(height),
                    stride_bytes: UInt32(dstBytesPerRow),
                    pixel_format: SONY2FUJI_PIXEL_RGBA8
                )
                return sony2fuji_inspection_render_overlay(&srcBuf, mode.nativeMode, &dstBuf)
            }
        }
        guard status == SONY2FUJI_STATUS_OK else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: outData as CFData),
              let rendered = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: dstBytesPerRow,
                  space: space,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }

        lock.lock()
        cache[key] = CacheEntry(source: image, rendered: rendered)
        lru.removeAll { $0 == key }
        lru.append(key)
        while lru.count > maxEntries {
            let evicted = lru.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()
        return rendered
    }
}
