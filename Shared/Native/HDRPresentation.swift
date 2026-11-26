import RawLabKit
import Foundation
import CoreGraphics

final class HDRPresentation: HDRDisplayImage, HDRLinearDisplayImage {
    let image: HDRImage
    let statistics: HDRStatistics
    let sdrImage: CGImage
    var width: Int { image.width }
    var height: Int { image.height }

    init(_ image: HDRImage, headroomOverride: Float? = nil) throws {
        self.image=image
        let measured=try image.withPair { pair in try HDRStatistics.analyze(pair.pointee.hdr) }
        if let headroomOverride, headroomOverride.isFinite, headroomOverride >= 1 {
            statistics = HDRStatistics(bins: measured.bins, aboveWhite: measured.aboveWhite,
                                       headroom: headroomOverride, pixels: measured.pixels)
        } else {
            statistics = measured
        }
        sdrImage=try Self.makeSDRImage(image)
    }

    static func makeSDRImage(_ image: HDRImage) throws -> CGImage {
        try image.withPair { pair in
            var sdr = pair.pointee.sdr
            guard sdr.data != nil, sdr.width > 0, sdr.height > 0,
                  sdr.pixel_format == SONY2FUJI_HDR_RGB32F_LINEAR,
                  sdr.color_encoding == SONY2FUJI_HDR_LINEAR_SRGB else {
                throw HDRDisplayFailure.invalidBuffer
            }
            var encoded = sony2fuji_buffer()
            let status = sony2fuji_hdr_encode_rgba8(&sdr, &encoded)
            guard status == SONY2FUJI_STATUS_OK else {
                sony2fuji_release_buffer(&encoded)
                throw status == SONY2FUJI_STATUS_INVALID_ARGUMENT
                    ? HDRDisplayFailure.nonfinite
                    : HDRDisplayFailure.invalidBuffer
            }
            guard let pixels = encoded.data, encoded.width > 0, encoded.height > 0,
                  encoded.pixel_format == SONY2FUJI_PIXEL_RGBA8 else {
                sony2fuji_release_buffer(&encoded)
                throw HDRDisplayFailure.invalidBuffer
            }
            let width = Int(encoded.width)
            let height = Int(encoded.height)
            let byteCount = width * height * 4
            let boxed = UnsafeMutablePointer<sony2fuji_buffer>.allocate(capacity: 1)
            boxed.initialize(to: encoded)
            let data = Data(bytesNoCopy: pixels, count: byteCount, deallocator: .custom { _, _ in
                sony2fuji_release_buffer(boxed)
                boxed.deallocate()
            })
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: data as CFData),
                  let cg = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: color,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  ) else {
                throw HDRDisplayFailure.invalidBuffer
            }
            return cg
        }
    }

    func withLinearPlanes<T>(
        _ body: (_ hdr: UnsafeBufferPointer<Float>, _ hdrStrideFloats: Int,
                 _ sdr: UnsafeBufferPointer<Float>, _ sdrStrideFloats: Int) throws -> T
    ) throws -> T {
        try image.withPair { pair in
            let hdrBuf = pair.pointee.hdr
            let sdrBuf = pair.pointee.sdr
            guard let hdrPtr = hdrBuf.data?.assumingMemoryBound(to: Float.self),
                  let sdrPtr = sdrBuf.data?.assumingMemoryBound(to: Float.self),
                  hdrBuf.stride_bytes % 4 == 0, sdrBuf.stride_bytes % 4 == 0,
                  Int(hdrBuf.width) == image.width, Int(hdrBuf.height) == image.height,
                  Int(sdrBuf.width) == image.width, Int(sdrBuf.height) == image.height else {
                throw HDRDisplayFailure.invalidBuffer
            }
            let hdrStride = Int(hdrBuf.stride_bytes) / MemoryLayout<Float>.size
            let sdrStride = Int(sdrBuf.stride_bytes) / MemoryLayout<Float>.size
            let hdrCount = Int(hdrBuf.size_bytes) / MemoryLayout<Float>.size
            let sdrCount = Int(sdrBuf.size_bytes) / MemoryLayout<Float>.size
            guard image.width > 0, image.height > 0,
                  hdrStride >= image.width * 3, sdrStride >= image.width * 3,
                  hdrCount >= (image.height - 1) * hdrStride + image.width * 3,
                  sdrCount >= (image.height - 1) * sdrStride + image.width * 3 else {
                throw HDRDisplayFailure.invalidBuffer
            }
            return try body(UnsafeBufferPointer(start: hdrPtr, count: hdrCount), hdrStride,
                            UnsafeBufferPointer(start: sdrPtr, count: sdrCount), sdrStride)
        }
    }

    func rgba16F(_ parameters: HDRDisplayParameters) throws -> Data {
        try image.withPair { pair in
            try Self.rgba16F(hdr: pair.pointee.hdr, sdr: pair.pointee.sdr,
                             contentHeadroom: statistics.headroom, parameters: parameters)
        }
    }

    /// Metal 不可用时的 CPU 显示映射，与 HDRCanvas 内核同为扩展线性 Display P3、SDR 夹取到 [0, 1]。
    static func rgba16F(hdr: sony2fuji_hdr_buffer_v1, sdr: sony2fuji_hdr_buffer_v1, contentHeadroom: Float,
                        parameters: HDRDisplayParameters) throws -> Data {
        var hdr = hdr, sdr = sdr
        var flags = SONY2FUJI_HDR_DISPLAY_P3.rawValue | SONY2FUJI_HDR_DISPLAY_CLAMP_SDR.rawValue
        if parameters.mode == .sdr { flags |= SONY2FUJI_HDR_DISPLAY_SDR.rawValue }
        if parameters.falseColor { flags |= SONY2FUJI_HDR_DISPLAY_FALSE_COLOR.rawValue }
        let rowBytes = Int(hdr.width) * 8
        var bytes = Data(count: rowBytes * Int(hdr.height))
        let status = bytes.withUnsafeMutableBytes { raw in
            sony2fuji_hdr_display_into(&hdr, &sdr, Float(parameters.safeHeadroom), contentHeadroom, flags,
                                       raw.baseAddress, UInt64(raw.count), UInt64(rowBytes))
        }
        guard status == SONY2FUJI_STATUS_OK else { throw HDRDisplayFailure(displayStatus: status) }
        return bytes
    }
}

extension HDRStatistics {
    static func analyze(_ buffer: sony2fuji_hdr_buffer_v1) throws -> HDRStatistics {
        var source = buffer
        var bins = [UInt32](repeating: 0, count: Int(SONY2FUJI_HDR_LUMINANCE_BINS))
        var above: UInt32 = 0
        var peak: Float = 1
        let status = bins.withUnsafeMutableBufferPointer {
            sony2fuji_hdr_analyze_luminance(&source, $0.baseAddress, &above, &peak)
        }
        guard status == SONY2FUJI_STATUS_OK else { throw HDRDisplayFailure(displayStatus: status) }
        return HDRStatistics(bins: bins.map(Double.init), aboveWhite: Int(above), headroom: peak,
                             pixels: Int(buffer.width) * Int(buffer.height))
    }
}

extension HDRDisplayFailure {
    init(displayStatus status: sony2fuji_status) {
        switch status {
        case SONY2FUJI_STATUS_INVALID_ARGUMENT: self = .nonfinite
        case SONY2FUJI_STATUS_PROCESSING_ERROR: self = .unrepresentable
        default: self = .invalidBuffer
        }
    }
}
