import AppKit
import ImageIO
import UniformTypeIdentifiers

struct AIImage: Identifiable {
    let id = UUID()
    let name: String
    let image: CGImage
    let jpeg: Data
    private(set) var sourceURL: URL?
    static let maxBytes = 2 * 1024 * 1024
    static let contentTypes: [UTType] = [.jpeg, .png, .tiff, .heic]

    private init(name: String, image: CGImage, jpeg: Data) {
        self.name = name; self.image = image; self.jpeg = jpeg
    }

    static func load(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let resources = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resources.isRegularFile == true, let size = resources.fileSize, size <= 128*1024*1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let rawType = CGImageSourceGetType(source), let type = UTType(rawType as String),
              contentTypes.contains(where: { type.conforms(to: $0) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30000, height <= 30000,
              Int64(width)*Int64(height) <= 120_000_000 else {
            throw AIError.message("参考图无法读取或超过限制；支持 JPEG、PNG、TIFF、HEIC，最大 120 MP / 128 MiB。")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AIError.message("无法解码参考图。")
        }
        var result = try prepare(image, name: url.lastPathComponent)
        result.sourceURL = url
        return result
    }

    static func prepare(_ image: CGImage, name: String) throws -> Self {
        guard image.width > 0, image.height > 0 else { throw AIError.message("图片为空。") }
        let scale = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width)*scale).rounded()))
        let height = max(1, Int((Double(image.height)*scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AIError.message("无法创建 sRGB 预览。")
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let converted = context.makeImage() else { throw AIError.message("无法转换参考图色彩空间。") }
        for quality in [0.9, 0.8, 0.65, 0.5] {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, converted, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination) && bytes.length <= maxBytes {
                return Self(name: name, image: converted, jpeg: bytes as Data)
            }
        }
        throw AIError.message("参考图压缩后仍超过 2 MiB，请选择较小的图片。")
    }
}
