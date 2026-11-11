import Foundation
import ImageIO

struct CameraJPEGSource: Codable, Equatable {
    let digest: String
    let options: CameraJPEGOptions
}

enum CameraJPEGProcessing {
    static func encode(sourceURL: URL, destinationURL: URL, options: CameraJPEGOptions) throws {
        try autoreleasepool {
            guard options.adjust, options.isValid,
                  let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 65535, height <= 65535,
                  CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil
            else { throw CameraProtocolError.jpegProcessing }

            let edge = min(options.longEdge ?? max(width, height), max(width, height))
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ] as CFDictionary), max(image.width, image.height) <= edge,
                  let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, "public.jpeg" as CFString, 1, nil)
            else { throw CameraProtocolError.jpegProcessing }

            var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            for key in [kCGImagePropertyExifMakerNote, kCGImagePropertyExifComponentsConfiguration,
                        kCGImagePropertyExifCompressedBitsPerPixel, kCGImagePropertyExifSubjectArea,
                        kCGImagePropertyExifSubjectLocation] { exif.removeValue(forKey: key) }
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            let auxiliary = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            if exif[kCGImagePropertyExifLensModel] == nil {
                exif[kCGImagePropertyExifLensModel] = auxiliary[kCGImagePropertyExifAuxLensModel]
            }
            let sourceTIFF = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            var tiff = sourceTIFF.filter { key, _ in
                [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                 kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription].contains(key)
            }
            tiff[kCGImagePropertyTIFFOrientation] = 1
            var metadata: [CFString: Any] = [
                kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyTIFFDictionary: tiff,
                kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: Double(options.quality) / 100
            ]
            metadata[kCGImagePropertyGPSDictionary] = properties[kCGImagePropertyGPSDictionary]
            metadata[kCGImagePropertyExifAuxDictionary] = properties[kCGImagePropertyExifAuxDictionary]
            CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CameraProtocolError.jpegProcessing }
        }
    }
}
