import CoreGraphics
import Foundation

// MARK: - Transient Inspection State (Never persisted to EditState or CanonicalEditRecipe)

public enum InspectionOverlayMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case sketchLuminance
    case warmCoolBW
    case oversaturationHeatmap
    case skinHueAmplification
    case neutralGray50

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .none: return "关闭观察层"
        case .sketchLuminance: return "素描明度"
        case .warmCoolBW: return "冷暖反差黑白"
        case .oversaturationHeatmap: return "过饱和熔断热力图"
        case .skinHueAmplification: return "肤色色相放大"
        case .neutralGray50: return "50% 中性灰"
        }
    }

    public var isActive: Bool { self != .none }
    public var isNeutralGray50: Bool { self == .neutralGray50 }
}

public struct InspectionColorSample: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public let hueDeg: Double
    public let saturationPct: Double
    public let brightnessPct: Double
    public let luminance: Double

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC

        self.brightnessPct = maxC * 100.0
        self.saturationPct = maxC <= 0.0 ? 0.0 : (delta / maxC) * 100.0

        var hue = 0.0
        if delta > 1e-6 {
            let seg: Double
            if maxC == rf {
                seg = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0)
            } else if maxC == gf {
                seg = (bf - rf) / delta + 2.0
            } else {
                seg = (rf - gf) / delta + 4.0
            }
            hue = seg * 60.0
            if hue < 0.0 { hue += 360.0 }
            if hue >= 360.0 { hue -= 360.0 }
        }
        self.hueDeg = hue
        self.luminance = min(1.0, max(0.0, (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0))
    }

    public var rgbText: String {
        "\(r) \(g) \(b)"
    }

    public var hsbText: String {
        String(format: "%.0f° %.0f%% %.0f%%", hueDeg, saturationPct, brightnessPct)
    }

    public static func hsbToRGB(hueDeg: Double, saturation: Double, brightness: Double) -> (r: Double, g: Double, b: Double) {
        var h = hueDeg.truncatingRemainder(dividingBy: 360.0)
        if h < 0 { h += 360.0 }
        let s = min(1.0, max(0.0, saturation))
        let v = min(1.0, max(0.0, brightness))
        let c = v * s
        let hp = h / 60.0
        let x = c * (1.0 - abs(hp.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - c
        let sector = Int(floor(hp)) % 6
        let rgb: (Double, Double, Double)
        switch sector {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (
            min(1.0, max(0.0, rgb.0 + m)),
            min(1.0, max(0.0, rgb.1 + m)),
            min(1.0, max(0.0, rgb.2 + m))
        )
    }
}

public struct InspectionAnchor: Identifiable, Equatable, Sendable {
    public static let maxCount = 4

    public let id: UUID
    public var sourcePoint: CGPoint

    public init(id: UUID = UUID(), sourcePoint: CGPoint) {
        self.id = id
        self.sourcePoint = CGPoint(
            x: min(1.0, max(0.0, sourcePoint.x)),
            y: min(1.0, max(0.0, sourcePoint.y))
        )
    }
}

public struct InspectionSessionState: Equatable, Sendable {
    public var monitorEnabled: Bool = false
    public var pinModeEnabled: Bool = false
    public var liveOutputPoint: CGPoint? = nil
    public var anchors: [InspectionAnchor] = []
    public var selectedAnchorID: UUID? = nil
    public var overlay: InspectionOverlayMode = .none
    public var lastNonGrayOverlay: InspectionOverlayMode = .none

    public init(
        monitorEnabled: Bool = false,
        pinModeEnabled: Bool = false,
        liveOutputPoint: CGPoint? = nil,
        anchors: [InspectionAnchor] = [],
        selectedAnchorID: UUID? = nil,
        overlay: InspectionOverlayMode = .none,
        lastNonGrayOverlay: InspectionOverlayMode = .none
    ) {
        self.monitorEnabled = monitorEnabled
        self.pinModeEnabled = pinModeEnabled
        self.liveOutputPoint = liveOutputPoint
        self.anchors = Array(anchors.prefix(InspectionAnchor.maxCount))
        self.selectedAnchorID = selectedAnchorID
        self.overlay = overlay
        self.lastNonGrayOverlay = lastNonGrayOverlay
    }

    public var canPinMore: Bool { anchors.count < InspectionAnchor.maxCount }

    public mutating func selectOverlay(_ mode: InspectionOverlayMode) {
        if mode != .neutralGray50 {
            lastNonGrayOverlay = mode
        }
        overlay = mode
    }

    public mutating func toggleNeutralGray50() {
        if overlay == .neutralGray50 {
            overlay = lastNonGrayOverlay == .neutralGray50 ? .none : lastNonGrayOverlay
        } else {
            lastNonGrayOverlay = overlay
            overlay = .neutralGray50
        }
    }

    @discardableResult
    public mutating func pinAnchor(atSourcePoint point: CGPoint) -> InspectionAnchor? {
        guard canPinMore else { return nil }
        let anchor = InspectionAnchor(sourcePoint: point)
        anchors.append(anchor)
        selectedAnchorID = anchor.id
        return anchor
    }

    public mutating func removeAnchor(id: UUID) {
        anchors.removeAll { $0.id == id }
        if selectedAnchorID == id {
            selectedAnchorID = anchors.last?.id
        }
    }

    public mutating func clearAnchors() {
        anchors.removeAll()
        selectedAnchorID = nil
    }

    public mutating func resetForNewSource() {
        pinModeEnabled = false
        liveOutputPoint = nil
        anchors.removeAll()
        selectedAnchorID = nil
        overlay = .none
        lastNonGrayOverlay = .none
    }

    @discardableResult
    public mutating func handleEscape() -> Bool {
        if overlay == .neutralGray50 {
            overlay = lastNonGrayOverlay == .neutralGray50 ? .none : lastNonGrayOverlay
            return true
        }
        if overlay != .none {
            overlay = .none
            lastNonGrayOverlay = .none
            return true
        }
        if pinModeEnabled {
            pinModeEnabled = false
            return true
        }
        if monitorEnabled {
            monitorEnabled = false
            liveOutputPoint = nil
            return true
        }
        return false
    }
}

// MARK: - Exact Geometry Coordinate Mapper (mirrors lutools/src/core/photo_geometry.cpp:25-95)

public enum GeometryCoordinateMapper {
    public struct CanvasSpec: Equatable, Sendable {
        public let rotatedWidth: Int
        public let rotatedHeight: Int
        public let width: Int
        public let height: Int
        public let left: Int
        public let top: Int
        public let right: Int
        public let bottom: Int
        public let cosine: Double
        public let sine: Double

        public var outputWidth: Int { right - left }
        public var outputHeight: Int { bottom - top }
    }

    public static func sourceSize(fromAspect aspect: Double, referenceLongEdge: Double = 4096.0) -> CGSize {
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1.0
        let edge = max(16.0, referenceLongEdge)
        if safeAspect >= 1.0 {
            return CGSize(width: edge, height: max(1.0, (edge / safeAspect).rounded()))
        } else {
            return CGSize(width: max(1.0, (edge * safeAspect).rounded()), height: edge)
        }
    }

    public static func canvasFor(width: Int, height: Int, options: GeometrySettings) -> CanvasSpec {
        let safeW = max(1, width)
        let safeH = max(1, height)
        let turns = ((options.quarterTurns % 4) + 4) % 4
        let rotatedWidth = (turns % 2 != 0) ? safeH : safeW
        let rotatedHeight = (turns % 2 != 0) ? safeW : safeH
        let radians = options.straightenDegrees * Double.pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let absSine = abs(sine)
        let perspScale = 1.0 / (1.0 + 0.25 * abs(options.perspectiveHorizontal) + 0.25 * abs(options.perspectiveVertical))
        let w = Double(max(1, Int(floor(Double(rotatedWidth) * perspScale))))
        let h = Double(max(1, Int(floor(Double(rotatedHeight) * perspScale))))
        let scale = min(w / (w * cosine + h * absSine), h / (w * absSine + h * cosine))
        let canvasW = max(1, Int(floor(w * scale)))
        let canvasH = max(1, Int(floor(h * scale)))
        let left = max(0, min(canvasW - 1, Int(floor(options.cropX * Double(canvasW)))))
        let top = max(0, min(canvasH - 1, Int(floor(options.cropY * Double(canvasH)))))
        let right = min(canvasW, max(left + 1, Int(ceil(min(1.0, options.cropX + options.cropWidth) * Double(canvasW)))))
        let bottom = min(canvasH, max(top + 1, Int(ceil(min(1.0, options.cropY + options.cropHeight) * Double(canvasH)))))
        return CanvasSpec(
            rotatedWidth: rotatedWidth,
            rotatedHeight: rotatedHeight,
            width: canvasW,
            height: canvasH,
            left: left,
            top: top,
            right: right,
            bottom: bottom,
            cosine: cosine,
            sine: sine
        )
    }

    public static func outputNormToSourceNorm(
        _ outPoint: CGPoint,
        sourceSize: CGSize,
        geometry: GeometrySettings
    ) -> CGPoint? {
        guard outPoint.x.isFinite, outPoint.y.isFinite,
              outPoint.x >= -1e-4, outPoint.x <= 1.0 + 1e-4,
              outPoint.y >= -1e-4, outPoint.y <= 1.0 + 1e-4,
              sourceSize.width >= 1, sourceSize.height >= 1 else {
            return nil
        }
        let clampedOutX = min(1.0, max(0.0, Double(outPoint.x)))
        let clampedOutY = min(1.0, max(0.0, Double(outPoint.y)))
        if geometry.isIdentity {
            return CGPoint(x: clampedOutX, y: clampedOutY)
        }

        let w = max(1, Int(sourceSize.width.rounded()))
        let h = max(1, Int(sourceSize.height.rounded()))
        let canvas = canvasFor(width: w, height: h, options: geometry)
        let outW = Double(canvas.outputWidth)
        let outH = Double(canvas.outputHeight)
        let x = clampedOutX * outW - 0.5
        let y = clampedOutY * outH - 0.5

        let dy = Double(canvas.top) + y - Double(canvas.height - 1) * 0.5
        let dx = Double(canvas.left) + x - Double(canvas.width - 1) * 0.5
        let rotatedX = canvas.cosine * dx + canvas.sine * dy
        let rotatedY = -canvas.sine * dx + canvas.cosine * dy
        let denominator = 1.0
            + 0.25 * geometry.perspectiveHorizontal * (2.0 * rotatedX / Double(canvas.rotatedWidth))
            + 0.25 * geometry.perspectiveVertical * (2.0 * rotatedY / Double(canvas.rotatedHeight))
        guard abs(denominator) > 1e-6 else { return nil }

        var px = Double(canvas.rotatedWidth - 1) * 0.5 + rotatedX / denominator
        var py = Double(canvas.rotatedHeight - 1) * 0.5 + rotatedY / denominator

        if geometry.flipHorizontal { px = Double(canvas.rotatedWidth - 1) - px }
        if geometry.flipVertical { py = Double(canvas.rotatedHeight - 1) - py }

        let turns = ((geometry.quarterTurns % 4) + 4) % 4
        let sx: Double
        let sy: Double
        switch turns {
        case 1:
            sx = py
            sy = Double(h - 1) - px
        case 2:
            sx = Double(w - 1) - px
            sy = Double(h - 1) - py
        case 3:
            sx = Double(w - 1) - py
            sy = px
        default:
            sx = px
            sy = py
        }

        let uSrc = (sx + 0.5) / Double(w)
        let vSrc = (sy + 0.5) / Double(h)
        guard uSrc >= -1e-3, uSrc <= 1.0 + 1e-3, vSrc >= -1e-3, vSrc <= 1.0 + 1e-3 else {
            return nil
        }
        return CGPoint(x: min(1.0, max(0.0, uSrc)), y: min(1.0, max(0.0, vSrc)))
    }

    public static func sourceNormToOutputNorm(
        _ srcPoint: CGPoint,
        sourceSize: CGSize,
        geometry: GeometrySettings
    ) -> CGPoint? {
        guard srcPoint.x.isFinite, srcPoint.y.isFinite,
              srcPoint.x >= -1e-4, srcPoint.x <= 1.0 + 1e-4,
              srcPoint.y >= -1e-4, srcPoint.y <= 1.0 + 1e-4,
              sourceSize.width >= 1, sourceSize.height >= 1 else {
            return nil
        }
        let clampedSrcX = min(1.0, max(0.0, Double(srcPoint.x)))
        let clampedSrcY = min(1.0, max(0.0, Double(srcPoint.y)))
        if geometry.isIdentity {
            return CGPoint(x: clampedSrcX, y: clampedSrcY)
        }

        let w = max(1, Int(sourceSize.width.rounded()))
        let h = max(1, Int(sourceSize.height.rounded()))
        let canvas = canvasFor(width: w, height: h, options: geometry)

        let sx = clampedSrcX * Double(w) - 0.5
        let sy = clampedSrcY * Double(h) - 0.5

        let turns = ((geometry.quarterTurns % 4) + 4) % 4
        var px: Double
        var py: Double
        switch turns {
        case 1:
            px = Double(h - 1) - sy
            py = sx
        case 2:
            px = Double(w - 1) - sx
            py = Double(h - 1) - sy
        case 3:
            px = sy
            py = Double(w - 1) - sx
        default:
            px = sx
            py = sy
        }

        if geometry.flipHorizontal { px = Double(canvas.rotatedWidth - 1) - px }
        if geometry.flipVertical { py = Double(canvas.rotatedHeight - 1) - py }

        let ax = px - Double(canvas.rotatedWidth - 1) * 0.5
        let ay = py - Double(canvas.rotatedHeight - 1) * 0.5
        let ch = 0.5 * geometry.perspectiveHorizontal / Double(canvas.rotatedWidth)
        let cv = 0.5 * geometry.perspectiveVertical / Double(canvas.rotatedHeight)
        let denom = 1.0 - ch * ax - cv * ay
        guard denom > 1e-6 else { return nil }

        let rx = ax / denom
        let ry = ay / denom

        let dx = canvas.cosine * rx - canvas.sine * ry
        let dy = canvas.sine * rx + canvas.cosine * ry

        let cx = dx + Double(canvas.width - 1) * 0.5
        let cy = dy + Double(canvas.height - 1) * 0.5
        let x = cx - Double(canvas.left)
        let y = cy - Double(canvas.top)

        let uOut = (x + 0.5) / Double(canvas.outputWidth)
        let vOut = (y + 0.5) / Double(canvas.outputHeight)
        guard uOut >= -1e-4, uOut <= 1.0 + 1e-4, vOut >= -1e-4, vOut <= 1.0 + 1e-4 else {
            return nil
        }
        return CGPoint(x: min(1.0, max(0.0, uOut)), y: min(1.0, max(0.0, vOut)))
    }
}

// MARK: - RGBA8 Pixel Sampling & LRU Cache

public struct InspectionPixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytes: Data

    public init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let srgbName = cgImage.colorSpace?.name
        let isSRGB = srgbName == CGColorSpace.sRGB
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

    public func sample(atNormalized point: CGPoint, radiusPixels: Int = 1) -> InspectionColorSample? {
        guard width > 0, height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let nx = min(1.0, max(0.0, Double(point.x)))
        let ny = min(1.0, max(0.0, Double(point.y)))
        let cx = width == 1 ? 0 : min(width - 1, max(0, Int((nx * Double(width - 1)).rounded())))
        let cy = height == 1 ? 0 : min(height - 1, max(0, Int((ny * Double(height - 1)).rounded())))
        let r = max(0, radiusPixels)
        let x0 = max(0, cx - r)
        let x1 = min(width - 1, cx + r)
        let y0 = max(0, cy - r)
        let y1 = min(height - 1, cy + r)

        return bytes.withUnsafeBytes { rawPtr -> InspectionColorSample? in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var sumR = 0
            var sumG = 0
            var sumB = 0
            var count = 0
            for y in y0...y1 {
                let row = ptr + y * bytesPerRow
                for x in x0...x1 {
                    let offset = x * 4
                    sumR += Int(row[offset])
                    sumG += Int(row[offset + 1])
                    sumB += Int(row[offset + 2])
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            let avgR = UInt8(min(255, max(0, Int((Double(sumR) / Double(count)).rounded()))))
            let avgG = UInt8(min(255, max(0, Int((Double(sumG) / Double(count)).rounded()))))
            let avgB = UInt8(min(255, max(0, Int((Double(sumB) / Double(count)).rounded()))))
            return InspectionColorSample(r: avgR, g: avgG, b: avgB)
        }
    }
}

public final class InspectionSamplerCache: @unchecked Sendable {
    public static let shared = InspectionSamplerCache()

    private struct Entry {
        let image: CGImage
        let buffer: InspectionPixelBuffer
    }

    private let lock = NSLock()
    private let maxEntries: Int
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var lru: [ObjectIdentifier] = []

    public init(maxEntries: Int = 6) {
        self.maxEntries = max(1, maxEntries)
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    public func sample(_ cgImage: CGImage, atNormalized point: CGPoint, radiusPixels: Int = 1) -> InspectionColorSample? {
        buffer(for: cgImage)?.sample(atNormalized: point, radiusPixels: radiusPixels)
    }

    public func buffer(for cgImage: CGImage) -> InspectionPixelBuffer? {
        let key = ObjectIdentifier(cgImage)
        lock.lock()
        if let existing = entries[key], existing.image === cgImage {
            lru.removeAll { $0 == key }
            lru.append(key)
            lock.unlock()
            return existing.buffer
        }
        lock.unlock()

        guard let decoded = InspectionPixelBuffer(cgImage: cgImage) else { return nil }

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

// MARK: - 5 View-End-Stage Observation Overlays

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
    private let maxEntries: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var lru: [CacheKey] = []

    public init(maxEntries: Int = 3) {
        self.maxEntries = max(1, maxEntries)
    }

    public func clear() {
        lock.lock()
        cache.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    @inline(__always)
    public static func applyOverlayPixel(r: UInt8, g: UInt8, b: UInt8, mode: InspectionOverlayMode) -> (UInt8, UInt8, UInt8) {
        switch mode {
        case .none:
            return (r, g, b)
        case .neutralGray50:
            return (128, 128, 128)
        case .sketchLuminance:
            let rf = Double(r) / 255.0
            let gf = Double(g) / 255.0
            let bf = Double(b) / 255.0
            let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            let t = min(1.0, max(0.0, (y - 0.5) * 2.4 + 0.5))
            let v = t * t * (3.0 - 2.0 * t)
            let out = UInt8(min(255, max(0, Int((v * 255.0).rounded()))))
            return (out, out, out)
        case .warmCoolBW:
            let rf = Double(r) / 255.0
            let gf = Double(g) / 255.0
            let bf = Double(b) / 255.0
            let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            let warmth = (rf - bf) + 0.35 * (gf - bf)
            let v = min(1.0, max(0.0, y + 0.55 * warmth))
            let out = UInt8(min(255, max(0, Int((v * 255.0).rounded()))))
            return (out, out, out)
        case .oversaturationHeatmap:
            let rf = Double(r) / 255.0
            let gf = Double(g) / 255.0
            let bf = Double(b) / 255.0
            let maxC = max(rf, gf, bf)
            let minC = min(rf, gf, bf)
            let delta = maxC - minC
            let bright = maxC
            let sat = maxC <= 0.0 ? 0.0 : delta / maxC
            let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
            let base = 0.28 * y

            let outRGB: (Double, Double, Double)
            if minC >= 0.996 {
                outRGB = (1.0, 0.25, 0.25)
            } else if maxC >= 0.996 && minC < 0.96 {
                outRGB = (1.0, 0.10, 0.55)
            } else if sat > 0.85 && bright > 0.35 {
                let sev = min(1.0, max(0.0, ((sat - 0.85) / 0.15) * 0.7 + ((bright - 0.35) / 0.65) * 0.3))
                if sev < 0.5 {
                    let u = sev * 2.0
                    outRGB = (1.0, 0.90 + (0.45 - 0.90) * u, 0.0)
                } else {
                    let u = (sev - 0.5) * 2.0
                    outRGB = (1.0, 0.45 + (0.08 - 0.45) * u, 0.12 * u)
                }
            } else if sat > 0.75 && bright > 0.35 {
                let t = min(1.0, max(0.0, (sat - 0.75) / 0.10)) * 0.65
                outRGB = (
                    base + (1.0 - base) * t,
                    base + (0.72 - base) * t,
                    base + (0.12 - base) * t
                )
            } else {
                outRGB = (base, base, base)
            }
            return (
                UInt8(min(255, max(0, Int((outRGB.0 * 255.0).rounded())))),
                UInt8(min(255, max(0, Int((outRGB.1 * 255.0).rounded())))),
                UInt8(min(255, max(0, Int((outRGB.2 * 255.0).rounded()))))
            )
        case .skinHueAmplification:
            let rf = Double(r) / 255.0
            let gf = Double(g) / 255.0
            let bf = Double(b) / 255.0
            let maxC = max(rf, gf, bf)
            let minC = min(rf, gf, bf)
            let delta = maxC - minC
            let bright = maxC
            let sat = maxC <= 0.0 ? 0.0 : delta / maxC
            var hue = 0.0
            if delta > 1e-6 {
                let seg: Double
                if maxC == rf {
                    seg = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0)
                } else if maxC == gf {
                    seg = (bf - rf) / delta + 2.0
                } else {
                    seg = (rf - gf) / delta + 4.0
                }
                hue = seg * 60.0
                if hue < 0.0 { hue += 360.0 }
                if hue >= 360.0 { hue -= 360.0 }
            }
            if hue >= 0.0 && hue <= 50.0 && sat >= 0.05 && bright >= 0.08 {
                let stretchedHue: Double
                if hue <= 22.0 {
                    let u = hue / 22.0
                    stretchedHue = (330.0 + 65.0 * u).truncatingRemainder(dividingBy: 360.0)
                } else {
                    let u = (hue - 22.0) / 28.0
                    stretchedHue = 35.0 + 115.0 * u
                }
                let sPrime = min(1.0, max(0.0, max(0.55, sat * 1.8)))
                let bPrime = min(1.0, max(0.0, 0.35 + 0.65 * bright))
                let rgb = InspectionColorSample.hsbToRGB(hueDeg: stretchedHue, saturation: sPrime, brightness: bPrime)
                return (
                    UInt8(min(255, max(0, Int((rgb.r * 255.0).rounded())))),
                    UInt8(min(255, max(0, Int((rgb.g * 255.0).rounded())))),
                    UInt8(min(255, max(0, Int((rgb.b * 255.0).rounded()))))
                )
            } else {
                let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                let v = UInt8(min(255, max(0, Int((0.35 * y * 255.0).rounded()))))
                return (v, v, v)
            }
        }
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
        for y in 0..<height {
            let sRow = src + y * srcBytesPerRow
            let dRow = dst + y * dstBytesPerRow
            for x in 0..<width {
                let sOff = x * 4
                let dOff = x * 4
                let (or, og, ob) = applyOverlayPixel(r: sRow[sOff], g: sRow[sOff + 1], b: sRow[sOff + 2], mode: mode)
                dRow[dOff] = or
                dRow[dOff + 1] = og
                dRow[dOff + 2] = ob
                dRow[dOff + 3] = 255
            }
        }
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
        buffer.bytes.withUnsafeBytes { srcRaw in
            outData.withUnsafeMutableBytes { dstRaw in
                guard let srcPtr = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dstPtr = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                Self.applyOverlayRGBA8(
                    src: srcPtr,
                    dst: dstPtr,
                    width: width,
                    height: height,
                    srcBytesPerRow: buffer.bytesPerRow,
                    dstBytesPerRow: dstBytesPerRow,
                    mode: mode
                )
            }
        }

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
