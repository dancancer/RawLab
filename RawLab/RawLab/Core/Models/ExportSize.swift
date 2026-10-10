import Foundation

enum ExportSize {
    static let presets = [2048, 3000, 4096]
    static let range = 1...65535

    static func isValid(_ longEdge: Int?) -> Bool {
        guard let longEdge else { return true }
        return range.contains(longEdge)
    }

    static func normalized(_ longEdge: Int?) -> Int? {
        guard isValid(longEdge) else { return nil }
        return longEdge
    }

}
