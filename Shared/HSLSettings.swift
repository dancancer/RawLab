import Foundation

enum HSLAxis: String, CaseIterable, Identifiable {
    case hue, saturation, lightness
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hue: return L10n.text("色相")
        case .saturation: return L10n.text("饱和度")
        case .lightness: return L10n.text("明度")
        }
    }
}

struct HSLSettings: Codable, Equatable, Hashable {
    static let channelNames = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红"]
    private(set) var hue = [Double](repeating: 0, count: 8)
    private(set) var saturation = [Double](repeating: 0, count: 8)
    private(set) var lightness = [Double](repeating: 0, count: 8)
    var isIdentity: Bool { hue + saturation + lightness == [Double](repeating: 0, count: 24) }
    var isValid: Bool {
        [hue, saturation, lightness].allSatisfy { $0.count == 8 && $0.allSatisfy { $0.isFinite && (-100...100).contains($0) } }
    }
    var progress: Double { (hue + saturation + lightness).max { abs($0) < abs($1) }.map { $0 / 100 } ?? 0 }

    func value(_ axis: HSLAxis, channel: Int) -> Double {
        switch axis {
        case .hue: return hue[channel]
        case .saturation: return saturation[channel]
        case .lightness: return lightness[channel]
        }
    }

    mutating func set(_ axis: HSLAxis, channel: Int, value: Double) {
        guard (0..<8).contains(channel), value.isFinite else { return }
        let value = min(100, max(-100, value.rounded()))
        switch axis {
        case .hue: hue[channel] = value
        case .saturation: saturation[channel] = value
        case .lightness: lightness[channel] = value
        }
    }

    mutating func reset(channel: Int? = nil) {
        if let channel {
            for axis in HSLAxis.allCases { set(axis, channel: channel, value: 0) }
        } else { self = HSLSettings() }
    }

    func scaled(by strength: Double) -> HSLSettings {
        var result = self
        result.hue = hue.map { min(100, max(-100, $0 * strength)) }
        result.saturation = saturation.map { min(100, max(-100, $0 * strength)) }
        result.lightness = lightness.map { min(100, max(-100, $0 * strength)) }
        return result
    }
}
