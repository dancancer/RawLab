import CoreImage
import CryptoKit
import Darwin
import Foundation
import os

struct ProRAWSource: Hashable {
    static let decodeVersion = 1
    static let previewLimit = 2048
    let decoder: String
    let width: Int
    let height: Int

    @discardableResult
    static func validatedDecodeVersion(_ saved: Int?) throws -> Int {
        let version = saved ?? decodeVersion
        guard version == decodeVersion else { throw HDRSettings.ModeError.invalidSettings }
        return version
    }

    static func probe(_ url: URL) throws -> Self? {
        // 探测返回纯值，及时释放系统解码器的临时对象，避免与全尺寸编码同时驻留。
        try autoreleasepool {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (8...(512 << 20)).contains(size) else { return nil }
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard isLinearProRAW(data),
                  let raw = CIRAWFilter(imageURL: url),
                  let tiff = raw.properties["{TIFF}"] as? [String: Any],
                  (tiff["Make"] as? String)?.caseInsensitiveCompare("Apple") == .orderedSame,
                  (tiff["Model"] as? String)?.hasPrefix("iPhone ") == true else { return nil }
            let canvas = raw.nativeSize
            guard canvas.width >= 2, canvas.height >= 2,
                  canvas.width * canvas.height <= 128_000_000 else { return nil }
            let rotated = raw.orientation.rawValue >= 5
            return Self(decoder: raw.decoderVersion.rawValue,
                        width: Int(rotated ? canvas.height : canvas.width),
                        height: Int(rotated ? canvas.width : canvas.height))
        }
    }

    // The preview IFD is JPEG. Inspect the RAW IFD without loading its tiles.
    private static func isLinearProRAW(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let order = (data[0], data[1])
        let bigEndian = order == (0x4d, 0x4d)
        guard bigEndian || order == (0x49, 0x49) else { return false }
        func number(_ offset: Int, _ length: Int) -> Int? {
            guard offset >= 0, offset <= data.count - length else { return nil }
            var value = 0
            for index in 0..<length {
                let byte = bigEndian ? index : length - 1 - index
                value = (value << 8) | Int(data[offset + byte])
            }
            return value
        }
        func entries(_ offset: Int) -> [Int: Int] {
            guard let count = number(offset, 2), count <= 1024,
                  offset + 2 + count * 12 <= data.count else { return [:] }
            var tags = [Int: Int]()
            for i in 0..<count {
                let entry = offset + 2 + 12 * i
                if let tag = number(entry, 2) { tags[tag] = entry }
            }
            return tags
        }
        func hasProfile(_ tags: [Int: Int]) -> Bool {
            tags[52525] != nil || tags[52544] != nil
        }
        func isRaw(_ tags: [Int: Int], root: [Int: Int]) -> Bool {
            guard let photo = tags[262], number(photo + 2, 2) == 3,
                  number(photo + 4, 4) == 1, number(photo + 8, 2) == 34892 else { return false }
            return tags[50712] != nil && (hasProfile(tags) || hasProfile(root))
        }
        guard number(2, 2) == 42, let first = number(4, 4) else { return false }
        let root = entries(first)
        guard root[50706] != nil else { return false }
        if isRaw(root, root: root) { return true }
        guard let sub = root[330], let type = number(sub + 2, 2), type == 4 || type == 13,
              let count = number(sub + 4, 4), (1...32).contains(count),
              let offset = number(sub + 8, 4) else { return false }
        if count == 1 { return isRaw(entries(offset), root: root) }
        return (0..<count).contains { index in
            guard let child = number(offset + 4 * index, 4) else { return false }
            return isRaw(entries(child), root: root)
        }
    }

    var permitsFullSizeExport: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        // The 12 MP tier passed the full export on iPhone 14 Pro Max with iOS 27.
        return max(width, height) <= 4032 && width * height <= 4032 * 3024 && isValidatedExportDevice
        #elseif os(iOS)
        return false
        #else
        return true
        #endif
    }

    var permitsStreamedJPEGExport: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        // 48 MP 已通过此设备的编辑器、批量、取消恢复和 Photos 回读验证。
        return max(width, height) <= 8064 && width * height <= 8064 * 6048 && isValidatedExportDevice
        #else
        return permitsFullSizeExport
        #endif
    }

    private var isValidatedExportDevice: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return false }
        var platform = utsname()
        guard uname(&platform) == 0 else { return false }
        let model = withUnsafeBytes(of: platform.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model == "iPhone15,3"
        #else
        return false
        #endif
    }

    static func checkMemory(pixels: Int, final: Bool) throws {
        try checkMemory(requiredBytes: UInt64(pixels) * (final ? 88 : 56) + (64 << 20))
    }

    static func checkMemory(requiredBytes: UInt64) throws {
        let available: UInt64
        #if os(iOS)
        let remaining = UInt64(os_proc_available_memory())
        #if targetEnvironment(simulator)
        available = remaining > 0 ? remaining : min(ProcessInfo.processInfo.physicalMemory / 4, 2 << 30)
        #else
        available = remaining
        #endif
        #else
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let limit = ProcessInfo.processInfo.physicalMemory / 2
        available = result == KERN_SUCCESS && memory.phys_footprint < limit ? limit - memory.phys_footprint : 0
        #endif
        guard requiredBytes <= available * 65 / 100 else { throw memoryError }
    }

    static var memoryError: HDRNativeError {
        HDRNativeError(status: SONY2FUJI_STATUS_OUT_OF_MEMORY, reason: UInt32(SONY2FUJI_HDR_REASON_OUT_OF_MEMORY),
                       field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
    }

    func decode(_ url: URL, stamp: HDRSourceInfo.CameraStamp, longEdge: Int?,
                cancelled: () -> Bool) throws -> (pair: sony2fuji_hdr_image_pair_v1, hdr: Data, sdr: Data) {
        try autoreleasepool {
            func checkCancellation() throws {
                if cancelled() || Task.isCancelled { throw CancellationError() }
            }
            try checkCancellation()
            let longEdge = longEdge.map { min($0, Self.previewLimit) }
            let edge = max(width, height)
            let final = longEdge == nil
            let scale = min(1, Double(longEdge ?? edge) / Double(edge))
            let expectedPixels = Int(ceil(Double(width) * scale)) * Int(ceil(Double(height) * scale))
            try Self.checkMemory(pixels: expectedPixels, final: final)
            guard try HDRSourceInfo.CameraStamp(url) == stamp else { throw Self.changedSource }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try checkCancellation()
                hash.update(data: chunk)
            }
            guard let raw = CIRAWFilter(imageURL: url), raw.decoderVersion.rawValue == decoder else {
                throw HDRSettings.ModeError.unsupportedSource
            }
            raw.scaleFactor = Float(scale)
            let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            let context = CIContext(options: [.workingColorSpace: color, .cacheIntermediates: true])
            raw.extendedDynamicRangeAmount = 1
            guard let hdrImage = raw.outputImage else { throw HDRSettings.ModeError.unsupportedSource }
            let bounds = hdrImage.extent.integral
            guard bounds.width >= 1, bounds.height >= 1,
                  bounds.width * bounds.height <= 128_000_000,
                  final ? (bounds.width == CGFloat(width) && bounds.height == CGFloat(height)) :
                    max(bounds.width, bounds.height) <= CGFloat(longEdge!) else {
                throw HDRSettings.ModeError.unsupportedSource
            }
            let w = Int(bounds.width), h = Int(bounds.height)
            func pack(_ image: CIImage, isHDR: Bool) throws -> (Data, Float) {
                let count = w * h * 3 * MemoryLayout<Float>.stride
                guard let memory = malloc(count) else { throw Self.memoryError }
                let result = Data(bytesNoCopy: memory, count: count, deallocator: .free)
                let rgb = memory.bindMemory(to: Float.self, capacity: w * h * 3)
                let rows = min(256, h)
                var rgba = [Float](repeating: .nan, count: w * rows * 4)
                var peak: Float = 1
                for row in stride(from: 0, to: h, by: rows) {
                    try checkCancellation()
                    let height = min(rows, h - row)
                    // Core Image bounds count upward; bitmap rows start at the top of each tile.
                    let tile = CGRect(x: bounds.minX, y: bounds.maxY - CGFloat(row + height), width: CGFloat(w), height: CGFloat(height))
                    try rgba.withUnsafeMutableBufferPointer { values in
                        for i in 0..<(w * height) { values[i * 4 + 3] = .nan }
                        context.render(image, toBitmap: values.baseAddress!, rowBytes: w * 16,
                                       bounds: tile, format: .RGBAf, colorSpace: color)
                        try checkCancellation()
                        for i in 0..<(w * height) {
                            let r = values[i * 4], g = values[i * 4 + 1], b = values[i * 4 + 2]
                            guard values[i * 4 + 3].isFinite, r.isFinite, g.isFinite, b.isFinite else {
                                throw HDRNativeError(status: SONY2FUJI_STATUS_PROCESSING_ERROR,
                                    reason: UInt32(SONY2FUJI_HDR_REASON_NONFINITE), field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
                            }
                            let output = (row * w + i) * 3
                            if isHDR {
                                rgb[output] = r
                                rgb[output + 1] = g
                                rgb[output + 2] = b
                            } else {
                                rgb[output] = min(1, max(0, r))
                                rgb[output + 1] = min(1, max(0, g))
                                rgb[output + 2] = min(1, max(0, b))
                            }
                            peak = max(peak, 0.2126 * r + 0.7152 * g + 0.0722 * b)
                        }
                    }
                }
                return (result, peak)
            }
            let (hdr, headroom) = try pack(hdrImage, isHDR: true)
            context.clearCaches()
            raw.extendedDynamicRangeAmount = 0
            guard let sdrImage = raw.outputImage, sdrImage.extent.integral == bounds else {
                throw HDRSettings.ModeError.unsupportedSource
            }
            let (sdr, _) = try pack(sdrImage, isHDR: false)
            try checkCancellation()
            guard try HDRSourceInfo.CameraStamp(url) == stamp else { throw Self.changedSource }
            func buffer(_ pixels: Data, peak: Float) -> sony2fuji_hdr_buffer_v1 {
                var value = sony2fuji_hdr_buffer_v1()
                value.version = 1
                value.struct_size = UInt32(MemoryLayout.size(ofValue: value))
                value.size_bytes = UInt64(pixels.count)
                value.width = UInt32(w)
                value.height = UInt32(h)
                value.stride_bytes = UInt64(w * 12)
                value.pixel_format = UInt32(SONY2FUJI_HDR_RGB32F_LINEAR)
                value.color_encoding = UInt32(SONY2FUJI_HDR_LINEAR_SRGB)
                value.content_headroom = peak
                value.headroom_kind = UInt32(SONY2FUJI_HDR_HEADROOM_MEASURED)
                return value
            }
            var pair = sony2fuji_hdr_image_pair_v1()
            pair.version = 1
            pair.struct_size = UInt32(MemoryLayout.size(ofValue: pair))
            pair.hdr = buffer(hdr, peak: headroom)
            pair.sdr = buffer(sdr, peak: 1)
            pair.native_width = UInt32(width)
            pair.native_height = UInt32(height)
            pair.output_native_width = pair.native_width
            pair.output_native_height = pair.native_height
            pair.orientation_applied = 1
            pair.source_intent = (final ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW).rawValue
            pair.render_intent = pair.source_intent
            pair.is_proxy = final ? 0 : 1
            pair.decode_revision = UInt64(Self.decodeVersion)
            if final {
                pair.source_headroom = headroom
                pair.source_headroom_kind = UInt32(SONY2FUJI_HDR_HEADROOM_MEASURED)
            }
            let digest = hash.finalize()
            withUnsafeMutableBytes(of: &pair.source_sha256) { destination in
                digest.withUnsafeBytes { destination.copyMemory(from: $0) }
            }
            return (pair, hdr, sdr)
        }
    }

    static var changedSource: HDRNativeError {
        HDRNativeError(status: SONY2FUJI_STATUS_INVALID_ARGUMENT, reason: UInt32(SONY2FUJI_HDR_REASON_SOURCE_CHANGED),
                       field: UInt32(SONY2FUJI_HDR_FIELD_SOURCE))
    }
}
