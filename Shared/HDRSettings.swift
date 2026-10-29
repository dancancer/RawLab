import Foundation

struct HDRSettings: Equatable, Codable {
    enum Mode: String, Codable { case sdr, hdr }
    enum ModeError: Error, Equatable { case unsupportedSource, conflicts([String]), invalidSettings }

    let recordVersion = 1
    let processingVersion = 1
    var mode = Mode.hdr
    var exposure = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0
    var geometry = GeometrySettings()

    init() {}

    var isValid: Bool {
        [exposure, temperature, tint, contrast, highlights, shadows, saturation].allSatisfy(\.isFinite) &&
        (-4...4).contains(exposure) && (2000...50000).contains(temperature) && (-150...150).contains(tint) &&
        (-100...100).contains(contrast) && (-100...100).contains(highlights) &&
        (-100...100).contains(shadows) && (-100...100).contains(saturation) && geometry.isValid
    }
    var isIdentity: Bool {
        var neutral = HDRSettings(); neutral.mode = mode
        return self == neutral
    }

    mutating func reset() {
        let currentMode = mode
        self = HDRSettings(); mode = currentMode
    }

    static func enabling(stored: HDRSettings?, initial: HDRSettings, sourceIsHDR: Bool,
                         conflicts: [String]) throws -> HDRSettings {
        guard sourceIsHDR else { throw ModeError.unsupportedSource }
        if var existing = stored {
            guard existing.isValid else { throw ModeError.invalidSettings }
            existing.mode = .hdr
            return existing
        }
        guard conflicts.isEmpty else { throw ModeError.conflicts(conflicts) }
        var result = initial
        result.mode = .hdr; result.temperature = 6500; result.tint = 0
        guard result.isValid else { throw ModeError.invalidSettings }
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recordVersion = "record_version", processingVersion = "hdr_processing_version"
        case mode, exposure = "exposure_ev", temperature = "relative_temperature", tint = "relative_tint"
        case contrast, highlights, shadows, saturation, geometry
    }

    private struct Field: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self).allKeys
        guard fields.allSatisfy({ CodingKeys(stringValue: $0.stringValue) != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR settings field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .recordVersion) == 1,
              try values.decode(Int.self, forKey: .processingVersion) == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported HDR settings version"))
        }
        mode = try values.decode(Mode.self, forKey: .mode)
        exposure = try values.decode(Double.self, forKey: .exposure)
        temperature = try values.decode(Double.self, forKey: .temperature)
        tint = try values.decode(Double.self, forKey: .tint)
        contrast = try values.decode(Double.self, forKey: .contrast)
        highlights = try values.decode(Double.self, forKey: .highlights)
        shadows = try values.decode(Double.self, forKey: .shadows)
        saturation = try values.decode(Double.self, forKey: .saturation)
        geometry = try values.decode(GeometrySettings.self, forKey: .geometry)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid HDR settings parameters"))
        }
    }
}
