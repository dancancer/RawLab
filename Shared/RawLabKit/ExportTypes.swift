import Foundation
import UniformTypeIdentifiers

public enum ExportSize {
    public static let presets = [2048, 3000, 4096]
    public static let range = 1...65500

    public static func isValid(_ longEdge: Int?) -> Bool {
        guard let longEdge else { return true }
        return range.contains(longEdge)
    }

    public static func normalized(_ longEdge: Int?) -> Int? {
        guard isValid(longEdge) else { return nil }
        return longEdge
    }
}

public enum BatchSettingsMode: String, Codable, Sendable {
    case uniformFrozen = "uniform_frozen", perTargetFrozen = "per_target_frozen"
}

public enum OutputSharpening: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case off, low, standard, high

    public var title: String {
        switch self {
        case .off: return L10n.text("关")
        case .low: return L10n.text("低")
        case .standard: return L10n.text("标准")
        case .high: return L10n.text("高")
        }
    }
}

public enum ExportFormat: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case jpeg, png
    case hdrJPEG = "hdr_jpeg"
    case hdrHEIF = "hdr_heif"
    case renderedDNG = "dng"

    public var id: String { rawValue }
    public var publishesToPhotos: Bool { self != .renderedDNG }
    public var requiresHDR: Bool { self == .hdrJPEG || self == .hdrHEIF }
    public var hdrRequiredMessage: String {
        self == .hdrHEIF ? L10n.text("HDR HEIF 需要启用 HDR 编辑。") : L10n.text("HDR JPEG 需要启用 HDR 编辑。")
    }
    public var suffix: String {
        if self == .hdrHEIF { return "heic" }
        return self == .jpeg || self == .hdrJPEG ? "jpg" : rawValue
    }
    public var title: String {
        switch self {
        case .hdrJPEG: return L10n.text("HDR JPEG")
        case .hdrHEIF: return "HDR HEIF"
        case .jpeg: return "JPEG"
        case .png: return L10n.text("16-bit PNG")
        case .renderedDNG: return L10n.text("DNG · 渲染型")
        }
    }
    public var contentType: UTType {
        switch self {
        case .hdrJPEG, .jpeg: return .jpeg
        case .hdrHEIF: return .heic
        case .png: return .png
        case .renderedDNG: return UTType(filenameExtension: "dng") ?? .rawImage
        }
    }
    public static func forOutput(_ url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "dng": return .renderedDNG
        case "heic", "heif": return .hdrHEIF
        default: return .jpeg
        }
    }
}

public typealias BatchOutputFormat = ExportFormat
