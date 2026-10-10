import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoInfoMode: String, CaseIterable {
    case hidden, file, capture
    var title: String {
        switch self {
        case .hidden: return "隐藏照片信息"
        case .file: return "文件信息"
        case .capture: return "拍摄参数"
        }
    }
    var next: Self {
        switch self {
        case .hidden: return .file
        case .file: return .capture
        case .capture: return .hidden
        }
    }
}

struct PhotoInformation {
    let fileName: String
    private let fileDetails: [String]
    private let captureDetails: [String]

    static func read(_ url: URL) -> Self {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = CGImageSourceCreateWithURL(url as CFURL, options)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, options) as? [CFString: Any] } ?? [:]
        return Self(fileName: url.lastPathComponent, properties: properties)
    }

    init(fileName: String, properties: [CFString: Any]) {
        self.fileName = fileName
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
            return value.doubleValue
        }
        let isRaw = UTType(filenameExtension: (fileName as NSString).pathExtension)?.conforms(to: .rawImage) == true
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] ?? [:]
        let crop = dng[kCGImagePropertyDNGDefaultCropSize] as? [NSNumber] ?? []
        let rawDimensions: (Double, Double)?
        // iOS 的 RAW 顶层尺寸可能来自内嵌预览，原图尺寸优先取 DNG / EXIF。
        if isRaw, crop.count == 2, let width = number(crop[0]), let height = number(crop[1]) {
            rawDimensions = (width, height)
        } else if isRaw, let width = number(exif[kCGImagePropertyExifPixelXDimension]),
                  let height = number(exif[kCGImagePropertyExifPixelYDimension]) {
            rawDimensions = (width, height)
        } else {
            rawDimensions = nil
        }
        let width = rawDimensions?.0 ?? number(properties[kCGImagePropertyPixelWidth] ?? exif[kCGImagePropertyExifPixelXDimension])
        let height = rawDimensions?.1 ?? number(properties[kCGImagePropertyPixelHeight] ?? exif[kCGImagePropertyExifPixelYDimension])
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        var details: [String] = []
        if let date = text(exif[kCGImagePropertyExifDateTimeOriginal]) { details.append(date) }
        if let width, let height {
            details.append("\(Int(rotated ? height : width)) × \(Int(rotated ? width : height))")
        }
        fileDetails = details
        let make = text(tiff[kCGImagePropertyTIFFMake]), model = text(tiff[kCGImagePropertyTIFFModel])
        let camera = model.map { model in
            if let make, !model.localizedCaseInsensitiveContains(make) { return make + " " + model }
            return model
        } ?? make
        var capture: [String] = []
        if let camera { capture.append(camera) }
        if let lens = text(exif[kCGImagePropertyExifLensModel] ?? auxiliary[kCGImagePropertyExifAuxLensModel]) { capture.append(lens) }
        var exposure: [String] = []
        if let seconds = number(exif[kCGImagePropertyExifExposureTime]) {
            exposure.append(seconds <= 0.5 ? String(format: "1/%.0f s", 1 / seconds) : String(format: "%g s", seconds))
        }
        if let aperture = number(exif[kCGImagePropertyExifFNumber]) { exposure.append(String(format: "f/%g", aperture)) }
        let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        if let iso = number(ratings?.first ?? exif[kCGImagePropertyExifISOSpeedRatings]) { exposure.append(String(format: "ISO %g", iso)) }
        if let focalLength = number(exif[kCGImagePropertyExifFocalLength]) { exposure.append(String(format: "%g mm", focalLength)) }
        if !exposure.isEmpty { capture.append(exposure.joined(separator: " · ")) }
        captureDetails = capture.isEmpty ? ["未读取到拍摄参数"] : capture
    }

    func lines(for mode: PhotoInfoMode) -> [String] {
        switch mode {
        case .hidden: return []
        case .file: return [fileName] + fileDetails
        case .capture: return [fileName] + captureDetails
        }
    }
}
