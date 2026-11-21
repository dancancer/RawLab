import CoreGraphics
import Foundation
import ImageIO

public enum ExportMetadata {
    public enum Failure: Error {
        case unreadableSource, invalidDestination, cannotWriteMetadata, sameFile
    }

    /// PNG 元数据补写路径观察计数（测试观察钩子）：chunk 拼接不触碰像素，
    /// 回退路径才整读解码+重压缩。单线程观察用途，导出串行执行。
    public static var pngExifSpliceCount = 0
    public static var pngPixelReencodeCount = 0

    public static func properties(from url: URL, width: Int, height: Int,
                                  orientation: CGImagePropertyOrientation,
                                  fallbackSourceProperties: [CFString: Any]? = nil) throws -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let sourceProperties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        guard let original = sourceProperties ?? fallbackSourceProperties else {
            throw Failure.unreadableSource
        }
        var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // These describe the sensor, old encoding or coordinates, not the rendered image.
        for key in [kCGImagePropertyExifMakerNote, kCGImagePropertyExifCFAPattern,
                    kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifCompressedBitsPerPixel,
                    kCGImagePropertyExifSubjectArea, kCGImagePropertyExifSubjectLocation] {
            exif.removeValue(forKey: key)
        }
        exif[kCGImagePropertyExifPixelXDimension] = width
        exif[kCGImagePropertyExifPixelYDimension] = height
        exif[kCGImagePropertyExifColorSpace] = 1

        let sourceTIFF = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var tiff: [CFString: Any] = [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                    kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription] {
            tiff[key] = sourceTIFF[key]
        }
        tiff[kCGImagePropertyTIFFOrientation] = orientation.rawValue
        tiff[kCGImagePropertyTIFFSoftware] = "RawLab"

        let auxiliary = original[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        if exif[kCGImagePropertyExifLensModel] == nil {
            exif[kCGImagePropertyExifLensModel] = auxiliary[kCGImagePropertyExifAuxLensModel]
        }
        var result: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyOrientation: orientation.rawValue
        ]
        result[kCGImagePropertyGPSDictionary] = original[kCGImagePropertyGPSDictionary]
        result[kCGImagePropertyExifAuxDictionary] = original[kCGImagePropertyExifAuxDictionary]
        return result
    }

    public static func jpegData(image: CGImage, sourceURL: URL, orientation: CGImagePropertyOrientation,
                                quality: CGFloat, fallbackSourceProperties: [CFString: Any]? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.invalidDestination
        }
        var values = try properties(from: sourceURL, width: image.width, height: image.height, orientation: orientation,
                                    fallbackSourceProperties: fallbackSourceProperties)
        values[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, values as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWriteMetadata }
        return data as Data
    }

    public static func preserve(from original: URL, in rendered: URL,
                                fallbackSourceProperties: [CFString: Any]? = nil) throws {
        guard original.resolvingSymlinksInPath() != rendered.resolvingSymlinksInPath() else {
            throw Failure.sameFile
        }
        guard let source = CGImageSourceCreateWithURL(rendered as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = dimensions[kCGImagePropertyPixelWidth] as? Int,
              let height = dimensions[kCGImagePropertyPixelHeight] as? Int else {
            throw Failure.invalidDestination
        }
        let values = try properties(from: original, width: width, height: height, orientation: .up,
                                    fallbackSourceProperties: fallbackSourceProperties)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw Failure.invalidDestination
        }
        if type as String == "public.png" {
            // 核心层 savePNG 已完成 16-bit 像素编码（逐块 deflate，无元数据）。为约 2KB 的 EXIF 走
            // AddImageFromSource 会把 150MB 级成片整读解码+重压缩一遍，而像素一个字节都不会变。
            // 改为在 1×1 载体上让 ImageIO 编出标准 eXIf chunk（typed 有理数/数组/GPS 语义不变），
            // 重写 TIFF 载荷中的像素尺寸为真实输出后整块插到首个 IDAT 之前——IDAT 字节流原样保留，
            // 零解码、零重压缩（与 iOS #403「一次编码采信」同构）。
            if let exifPayload = pngExifChunk(values: values, width: width, height: height) {
                try splicePNGChunk(exifPayload, type: "eXIf", into: rendered)
                pngExifSpliceCount += 1
                return
            }
            // ImageIO 行为变化导致载体拿不到可解析的 eXIf 时，回退原始「显式编码+重压缩」路径，
            // EXIF 契约绝不因省功丢失（CopyImageSource 对无 eXIf 的 PNG 只附加 XMP，故不能走 JPEG 分支）。
            CGImageDestinationAddImageFromSource(destination, source, 0, values as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWriteMetadata }
            try (data as Data).write(to: rendered, options: .atomic)
            pngPixelReencodeCount += 1
            return
        }
        let originalSource = CGImageSourceCreateWithURL(original as CFURL, nil)
        let originalMetadata = originalSource.flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        let metadata = CGImageMetadataCreateMutable()
        for dictionary in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary,
                           kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] {
            for (key, value) in values[dictionary] as? [CFString: Any] ?? [:] {
                let replaced = [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                                kCGImagePropertyExifColorSpace, kCGImagePropertyTIFFOrientation,
                                kCGImagePropertyTIFFSoftware].contains(key)
                // Copy the typed tag so EXIF rationals do not become integer strings.
                if !replaced, let originalMetadata,
                   let tag = CGImageMetadataCopyTagMatchingImageProperty(originalMetadata, dictionary, key),
                   let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
                    let path = "\(prefix):\(name)" as CFString
                    CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
                } else {
                    CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFTypeRef)
                }
            }
        }
        let options = [kCGImageDestinationMetadata: metadata] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            throw Failure.cannotWriteMetadata
        }
        try (data as Data).write(to: rendered, options: .atomic)
    }

    // 冻结：禁新增字节级解析（WR-05 评估结论：Mac PNG 导出仍由 RawLabMac 在 sony2fuji_process
    // 之后调用 ExportMetadata.preserve，核心 C ABI 尚未透传编码期 eXIf，故此路径仍活且语义必要；
    // 保留现有 1×1 载体 + 原位改尺寸字段 + eXIf 块拼接与回退路径，待后续 C ABI 收敛编码期 eXIf 后再整体退役）。

    /// 在 1×1 载体上把拍摄参数编成 ImageIO 标准 eXIf chunk 数据（TIFF 块），并把其中的像素尺寸
    /// 改写为真实输出尺寸（ImageIO 会按载体 1×1 覆盖 ExifImageWidth/Height 与 TIFF ImageWidth/Length）。
    /// 载体拿不到 eXIf chunk 或 TIFF 载荷解析失败时返回 nil，触发整读重压缩回退。
    private static func pngExifChunk(values: [CFString: Any], width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
              let carrierImage = context.makeImage() else { return nil }
        let carrier = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(carrier, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, carrierImage, values as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let encoded = carrier as Data
        guard let range = pngChunkPayloadRange(of: encoded, type: "eXIf") else { return nil }
        var payload = [UInt8](encoded.subdata(in: range))
        guard patchExifPixelDimensions(&payload, width: width, height: height) else { return nil }
        return Data(payload)
    }

    private static func pngChunkPayloadRange(of data: Data, type: String) -> Range<Int>? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { return nil }
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 |
                Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length <= bytes.count - offset - 12 else { return nil }
            if String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) == type {
                return (offset + 8)..<(offset + 8 + length)
            }
            offset += length + 12
        }
        return nil
    }

    /// 把完整 chunk（长度+类型+载荷+CRC）插到首个 IDAT 之前（PNG 规范要求 eXIf 位于 IHDR 之后、
    /// 首个 IDAT 之前），并丢弃已存在的 IDAT 前 eXIf——重复补写幂等、不产生第二个 eXIf。
    /// 载荷尺寸已被改写，CRC 按 type+载荷 重算；IDAT 与其后所有字节原样平移。
    private static func splicePNGChunk(_ payload: Data, type: String, into url: URL) throws {
        var file = try Data(contentsOf: url)
        var insertAt: Int?
        var offset = 8
        while offset + 12 <= file.count {
            let length = file.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                Int($0.load(as: UInt32.self).bigEndian)
            }
            guard length <= file.count - offset - 12 else { break }
            let chunkType = file.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes {
                String(bytes: $0, encoding: .ascii)
            }
            if chunkType == "IDAT" { insertAt = offset; break }
            if chunkType == type {
                file.removeSubrange(offset..<(offset + 12 + length))
                continue
            }
            if chunkType == "IEND" { break }
            offset += length + 12
        }
        guard insertAt != nil else { throw Failure.cannotWriteMetadata }
        var chunk = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
        chunk.append(contentsOf: type.utf8)
        chunk.append(payload)
        var crc = pngCRC32(type: type, payload: payload).bigEndian
        withUnsafeBytes(of: &crc) { chunk.append(contentsOf: $0) }
        file.insert(contentsOf: chunk, at: insertAt!)
        try file.write(to: url, options: .atomic)
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    private static func pngCRC32(type: String, payload: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func update(_ byte: UInt8) { crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        for byte in type.utf8 { update(byte) }
        payload.withUnsafeBytes { raw in for byte in raw { update(byte) } }
        return crc ^ 0xFFFF_FFFF
    }

    /// 把 eXIf TIFF 载荷中的像素尺寸改写为真实输出：TIFF0 的 ImageWidth/ImageLength（256/257）
    /// 尽力改写，Exif 子 IFD 的 ExifImageWidth/Height（0xA002/0xA003）必须改写成功，否则判失败回退。
    private static func patchExifPixelDimensions(_ payload: inout [UInt8], width: Int, height: Int) -> Bool {
        guard payload.count >= 8 else { return false }
        let little: Bool
        if payload[0] == 0x49, payload[1] == 0x49 { little = true }
        else if payload[0] == 0x4D, payload[1] == 0x4D { little = false }
        else { return false }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= payload.count else { return nil }
            return little ? Int(payload[at]) | Int(payload[at + 1]) << 8 : Int(payload[at]) << 8 | Int(payload[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= payload.count else { return nil }
            return little ? Int(payload[at]) | Int(payload[at + 1]) << 8 | Int(payload[at + 2]) << 16 | Int(payload[at + 3]) << 24
                : Int(payload[at]) << 24 | Int(payload[at + 1]) << 16 | Int(payload[at + 2]) << 8 | Int(payload[at + 3])
        }
        func findEntry(_ ifd: Int, _ tag: Int) -> Int? {
            guard let count = u16(ifd), count <= (payload.count - ifd - 2) / 12 else { return nil }
            for index in 0..<count {
                let entry = ifd + 2 + 12 * index
                guard entry + 12 <= payload.count, u16(entry) == tag else { continue }
                return entry
            }
            return nil
        }
        func setNumber(_ entry: Int, _ value: Int) -> Bool {
            // TIFF IFD 条目布局 tag(2)+type(2)+count(4)+value(4)：count 是 32 位字段。
            guard let type = u16(entry + 2), let count = u32(entry + 4), count == 1, entry + 12 <= payload.count else {
                return false
            }
            let stored: [UInt8]
            if type == 3, value >= 0, value <= 0xFFFF {
                // SHORT 占值字段前两字节（按 TIFF 字节序），其余补零。
                stored = little ? [UInt8(value & 0xFF), UInt8(value >> 8), 0, 0]
                    : [UInt8(value >> 8), UInt8(value & 0xFF), 0, 0]
            } else if type == 4, value >= 0, value <= 0xFFFF_FFFF {
                let big = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
                stored = little ? big.reversed() : big
            } else {
                return false
            }
            payload.replaceSubrange((entry + 8)..<(entry + 12), with: stored)
            return true
        }
        func patch(_ ifd: Int, _ dimensions: [(Int, Int)]) -> Bool {
            for (tag, value) in dimensions {
                guard let entry = findEntry(ifd, tag), setNumber(entry, value) else { return false }
            }
            return true
        }
        guard let ifd0 = u32(4), ifd0 < payload.count else { return false }
        if let entry = findEntry(ifd0, 256) { _ = setNumber(entry, width) }
        if let entry = findEntry(ifd0, 257) { _ = setNumber(entry, height) }
        guard let pointer = findEntry(ifd0, 0x8769), let exifIFD = u32(pointer + 8), exifIFD < payload.count else {
            return false
        }
        return patch(exifIFD, [(0xA002, width), (0xA003, height)])
    }
}
