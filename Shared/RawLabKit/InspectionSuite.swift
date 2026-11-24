import CoreGraphics
import Foundation

// MARK: - Transient Inspection State (Never persisted to EditState or CanonicalEditRecipe)

public enum InspectionOverlayMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case sketchLuminance
    case warmCoolBW
    case oversaturationHeatmap
    case skinHueAmplification
    case neutralGray50

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .none: return "关闭观察层"
        case .sketchLuminance: return "素描明度"
        case .warmCoolBW: return "冷暖反差黑白"
        case .oversaturationHeatmap: return "过饱和熔断热力图"
        case .skinHueAmplification: return "肤色色相放大"
        case .neutralGray50: return "50% 中性灰"
        }
    }

    public var isActive: Bool { self != .none }
    public var isNeutralGray50: Bool { self == .neutralGray50 }
}

public struct InspectionColorSample: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public let hueDeg: Double
    public let saturationPct: Double
    public let brightnessPct: Double
    public let luminance: Double

    public init(
        r: UInt8,
        g: UInt8,
        b: UInt8,
        hueDeg: Double,
        saturationPct: Double,
        brightnessPct: Double,
        luminance: Double
    ) {
        self.r = r
        self.g = g
        self.b = b
        self.hueDeg = hueDeg
        self.saturationPct = saturationPct
        self.brightnessPct = brightnessPct
        self.luminance = luminance
    }

    public var rgbText: String {
        "\(r) \(g) \(b)"
    }

    public var hsbText: String {
        String(format: "%.0f° %.0f%% %.0f%%", hueDeg, saturationPct, brightnessPct)
    }
}

public struct InspectionAnchor: Identifiable, Equatable, Sendable {
    public static let maxCount = 4

    public let id: UUID
    public var sourcePoint: CGPoint

    public init(id: UUID = UUID(), sourcePoint: CGPoint) {
        self.id = id
        self.sourcePoint = CGPoint(
            x: min(1.0, max(0.0, sourcePoint.x)),
            y: min(1.0, max(0.0, sourcePoint.y))
        )
    }
}

public struct InspectionSessionState: Equatable, Sendable {
    public var monitorEnabled: Bool = false
    public var pinModeEnabled: Bool = false
    public var liveOutputPoint: CGPoint? = nil
    public var anchors: [InspectionAnchor] = []
    public var selectedAnchorID: UUID? = nil
    public var overlay: InspectionOverlayMode = .none
    public var lastNonGrayOverlay: InspectionOverlayMode = .none

    public init(
        monitorEnabled: Bool = false,
        pinModeEnabled: Bool = false,
        liveOutputPoint: CGPoint? = nil,
        anchors: [InspectionAnchor] = [],
        selectedAnchorID: UUID? = nil,
        overlay: InspectionOverlayMode = .none,
        lastNonGrayOverlay: InspectionOverlayMode = .none
    ) {
        self.monitorEnabled = monitorEnabled
        self.pinModeEnabled = pinModeEnabled
        self.liveOutputPoint = liveOutputPoint
        self.anchors = Array(anchors.prefix(InspectionAnchor.maxCount))
        self.selectedAnchorID = selectedAnchorID
        self.overlay = overlay
        self.lastNonGrayOverlay = lastNonGrayOverlay
    }

    public var canPinMore: Bool { anchors.count < InspectionAnchor.maxCount }

    public mutating func selectOverlay(_ mode: InspectionOverlayMode) {
        if mode != .neutralGray50 {
            lastNonGrayOverlay = mode
        }
        overlay = mode
    }

    public mutating func toggleNeutralGray50() {
        if overlay == .neutralGray50 {
            overlay = lastNonGrayOverlay == .neutralGray50 ? .none : lastNonGrayOverlay
        } else {
            lastNonGrayOverlay = overlay
            overlay = .neutralGray50
        }
    }

    @discardableResult
    public mutating func pinAnchor(atSourcePoint point: CGPoint) -> InspectionAnchor? {
        guard canPinMore else { return nil }
        let anchor = InspectionAnchor(sourcePoint: point)
        anchors.append(anchor)
        selectedAnchorID = anchor.id
        return anchor
    }

    public mutating func removeAnchor(id: UUID) {
        anchors.removeAll { $0.id == id }
        if selectedAnchorID == id {
            selectedAnchorID = anchors.last?.id
        }
    }

    public mutating func clearAnchors() {
        anchors.removeAll()
        selectedAnchorID = nil
    }

    public mutating func resetForNewSource() {
        pinModeEnabled = false
        liveOutputPoint = nil
        anchors.removeAll()
        selectedAnchorID = nil
        overlay = .none
        lastNonGrayOverlay = .none
    }

    @discardableResult
    public mutating func handleEscape() -> Bool {
        if overlay == .neutralGray50 {
            overlay = lastNonGrayOverlay == .neutralGray50 ? .none : lastNonGrayOverlay
            return true
        }
        if overlay != .none {
            overlay = .none
            lastNonGrayOverlay = .none
            return true
        }
        if pinModeEnabled {
            pinModeEnabled = false
            return true
        }
        if monitorEnabled {
            monitorEnabled = false
            liveOutputPoint = nil
            return true
        }
        return false
    }
}
