import Foundation

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

public enum BatchOutputFormat: String, Codable, Equatable, Hashable, Sendable {
    case jpeg
    case png
    case hdrJPEG = "hdr_jpeg"
    case hdrHEIF = "hdr_heif"
    case renderedDNG = "dng"

    public var publishesToPhotos: Bool { self != .renderedDNG }
    public var requiresHDR: Bool { self == .hdrJPEG || self == .hdrHEIF }
    public var hdrRequiredMessage: String {
        self == .hdrHEIF ? L10n.text("HDR HEIF 需要启用 HDR 编辑。") : L10n.text("HDR JPEG 需要启用 HDR 编辑。")
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

    public var suffix: String {
        switch self {
        case .jpeg, .hdrJPEG: return "jpg"
        case .png: return "png"
        case .hdrHEIF: return "heic"
        case .renderedDNG: return "dng"
        }
    }
}
