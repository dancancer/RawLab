import Foundation

// Normalized crop on the canvas after rotation, flips and centered straightening.
struct GeometrySettings: Codable, Equatable {
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1
    var quarterTurns: Int = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var straightenDegrees: Double = 0

    var isIdentity: Bool { self == GeometrySettings() }
    var isValid: Bool {
        [cropX, cropY, cropWidth, cropHeight, straightenDegrees].allSatisfy { $0.isFinite } &&
        cropX >= 0 && cropY >= 0 && cropWidth > 0 && cropHeight > 0 &&
        cropX + cropWidth <= 1 && cropY + cropHeight <= 1 &&
        (0...3).contains(quarterTurns) && (-45...45).contains(straightenDegrees)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case cropX, cropY, cropWidth, cropHeight, quarterTurns
        case flipHorizontal, flipVertical, straightenDegrees
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cropX = try values.decodeIfPresent(Double.self, forKey: .cropX) ?? 0
        cropY = try values.decodeIfPresent(Double.self, forKey: .cropY) ?? 0
        cropWidth = try values.decodeIfPresent(Double.self, forKey: .cropWidth) ?? 1
        cropHeight = try values.decodeIfPresent(Double.self, forKey: .cropHeight) ?? 1
        quarterTurns = try values.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        flipHorizontal = try values.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try values.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        straightenDegrees = try values.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
    }
}
