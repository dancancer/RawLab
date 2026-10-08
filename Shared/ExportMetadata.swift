import CoreGraphics
import Foundation
import ImageIO

enum ExportMetadata {
    enum Failure: Error {
        case unreadableSource, invalidDestination, cannotWriteMetadata, sameFile
    }

    static func properties(from url: URL, width: Int, height: Int,
                           orientation: CGImagePropertyOrientation) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
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

    static func jpegData(image: CGImage, sourceURL: URL, orientation: CGImagePropertyOrientation,
                         quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.invalidDestination
        }
        var values = try properties(from: sourceURL, width: image.width, height: image.height, orientation: orientation)
        values[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, values as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWriteMetadata }
        return data as Data
    }

    static func preserve(from original: URL, in rendered: URL) throws {
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
        let values = try properties(from: original, width: width, height: height, orientation: .up)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw Failure.invalidDestination
        }
        if type as String == "public.png" {
            // CopyImageSource only adds XMP to a PNG without eXIf; explicitly encode its EXIF properties.
            CGImageDestinationAddImageFromSource(destination, source, 0, values as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWriteMetadata }
            try (data as Data).write(to: rendered, options: .atomic)
            return
        }
        let originalSource = CGImageSourceCreateWithURL(original as CFURL, nil)!
        let originalMetadata = CGImageSourceCopyMetadataAtIndex(originalSource, 0, nil)
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
}
