import CoreGraphics
import Foundation
import ImageIO
import RawLabKit

struct CameraJPEGSource: Codable, Equatable {
    let digest: String
    let options: CameraJPEGOptions
}

enum CameraJPEGProcessing {
    static func adjustableSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CameraProtocolError.jpegProcessing }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            throw CameraProtocolError.jpegGainMapAdjustment
        }
        if #available(macOS 15.0, iOS 18.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            throw CameraProtocolError.jpegGainMapAdjustment
        }
        return source
    }

    static func encode(source: CGImageSource, destinationURL: URL, options: CameraJPEGOptions) throws {
        try autoreleasepool {
            guard options.adjust, options.isValid,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 65535, height <= 65535
            else { throw CameraProtocolError.jpegProcessing }

            let edge = min(options.longEdge ?? max(width, height), max(width, height))
            let encoded = NSMutableData()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ] as CFDictionary), max(image.width, image.height) <= edge,
                  let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil)
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
            var outputData = encoded as Data
            if image.colorSpace == nil || image.colorSpace?.name == CGColorSpace.sRGB {
                outputData = ExportMetadata.ensureSRGBICCProfile(outputData)
            }
            try outputData.write(to: destinationURL, options: .atomic)
        }
    }
}
