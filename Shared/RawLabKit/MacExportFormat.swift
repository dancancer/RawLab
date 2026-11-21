import Foundation
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case jpeg, png
    case hdrJPEG = "hdr_jpeg"
    case hdrHEIF = "hdr_heif"
    case renderedDNG = "dng"

    public var id: String { rawValue }
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
        case .hdrJPEG: return .jpeg
        case .hdrHEIF: return .heic
        case .jpeg: return .jpeg
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
