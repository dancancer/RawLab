import Foundation

/// Desktop editing uses tenths while the shared mobile setter keeps its integer contract.
enum MacHSLPrecision {
    static func setting(_ value: Double, axis: HSLAxis, channel: Int, in settings: HSLSettings) -> HSLSettings {
        guard settings.isValid, (0..<8).contains(channel), value.isFinite else { return settings }
        let rounded = (min(100, max(-100, value)) * 10).rounded() / 10
        let value = rounded == 0 ? 0 : rounded
        var payload = Payload(hue: settings.hue, saturation: settings.saturation, lightness: settings.lightness)
        switch axis {
        case .hue: payload.hue[channel] = value
        case .saturation: payload.saturation[channel] = value
        case .lightness: payload.lightness[channel] = value
        }
        // Copy through the existing Codable representation without opening shared array setters.
        guard let data = try? JSONEncoder().encode(payload),
              let result = try? JSONDecoder().decode(HSLSettings.self, from: data) else { return settings }
        return result
    }

    private struct Payload: Encodable {
        var hue: [Double]
        var saturation: [Double]
        var lightness: [Double]
    }
}
