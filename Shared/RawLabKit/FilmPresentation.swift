import Foundation

public enum EditorLayoutPolicy {
    public static func usesSidePanel(width: Double, height: Double, accessibility: Bool) -> Bool {
        !accessibility && width >= 600 && width > height
    }

    public static func sidePanelWidth(totalWidth: Double) -> Double {
        min(336, totalWidth * 0.48)
    }

    public static func parameterPanelHeight(measuredHeight: Double, totalHeight: Double, accessibility: Bool) -> Double {
        let fallback = measuredHeight > 0 ? measuredHeight : 240
        let maxRatio = accessibility ? 0.62 : 0.52
        return min(fallback, max(44, min(totalHeight * maxRatio, totalHeight - 140)))
    }

    public static func toolGridColumns(accessibility: Bool) -> Int {
        accessibility ? 3 : 4
    }

    public static func toolGridMinRowHeight(accessibility: Bool) -> Double {
        accessibility ? 68 : 52
    }

    public static func toolGridHeight(side: Bool, accessibility: Bool) -> Double? {
        side ? nil : (accessibility ? 148 : 116)
    }

    public static func editorToolHeight(accessibility: Bool, bodyLineHeight: Double, standardHeight: Double) -> Double {
        accessibility ? max(44, bodyLineHeight + 16) : standardHeight
    }

    public static func singleLineGroupNavigationHeight(captionLineHeight: Double) -> Double {
        max(44, ceil(captionLineHeight) + 8)
    }

    public static func scrollsToolsWithParameters(
        width: Double,
        height: Double,
        accessibility: Bool,
        bodyLineHeight: Double,
        groupButtonHeight: Double,
        toolStripHeight: Double
    ) -> Bool {
        guard accessibility && width > height else { return false }
        let actionSpace = max(44, bodyLineHeight + 16) + 16
        let parameterSpace = max(44, bodyLineHeight) + 8
        return height < groupButtonHeight + toolStripHeight + actionSpace + parameterSpace + 24
    }

    public static func mobileEditorGroups(isHDREditing: Bool) -> [EditorAdjustmentGroup] {
        let base: [EditorAdjustmentGroup] = [.looks, .light, .color, .detail, .geometry, .effects]
        return isHDREditing ? base + [.hdrRendition] : base
    }

    public static func mobileEditorTools(for group: EditorAdjustmentGroup) -> [EditorToolSelection] {
        switch group {
        case .looks: return [.film, .recipe]
        case .light: return [.adjustment(.exposure), .adjustment(.contrast), .adjustment(.highlights), .adjustment(.shadows), .adjustment(.whitePoint), .adjustment(.blackPoint), .adjustment(.toneCurve)]
        case .color: return [.adjustment(.temperature), .adjustment(.vibrance), .adjustment(.saturation), .adjustment(.hsl), .adjustment(.colorGrading)]
        case .detail: return [.adjustment(.sharpening), .adjustment(.noiseReduction)]
        default: return EditorAdjustmentRules.tools(group)
        }
    }
}

public struct FilmPresentation {
    public static let artworkNames = [
        "ACROS": "acros", "ASTIA": "astia", "CLASSIC-CHROME": "classic-chrome",
        "CLASSIC-NEG.": "classic-neg", "ETERNA": "eterna", "ETERNA-BB": "eterna-bb",
        "PRO-NEG.STD": "pro-neg-std", "PROVIA": "provia", "REALA-ACE": "reala-ace",
        "VELVIA": "velvia"
    ].merging(Dictionary(uniqueKeysWithValues: BundledLook.all.map { ($0.id.uppercased(), $0.artworkName) })) { _, new in new }
    public let name: String
    public let artworkName: String?
    public let group: FilmGroup

    public init(fileName: String) {
        group = FilmGroup.builtIn(fileName)
        if let look = BundledLook.find(fileName) {
            name = look.name
            artworkName = look.artworkName
            return
        }
        guard let start = fileName.range(of: "_to_", options: .caseInsensitive),
              let end = fileName.range(of: "_BT.709", options: .caseInsensitive)
                ?? fileName.range(of: "_65grid", options: .caseInsensitive),
              start.upperBound < end.lowerBound else {
            name = fileName
            artworkName = nil
            return
        }
        let film = String(fileName[start.upperBound..<end.lowerBound])
        name = film.replacingOccurrences(of: "-", with: " ")
        artworkName = Self.artworkNames[film.uppercased()]
    }
}
