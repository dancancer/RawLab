import Foundation
import RawLabKit

/// Shared/fixtures/hdr-display-goldens-v1.json 中的一组 Metal 对照金标。
/// lutools/tests/hdr_display_mapping_tests.cpp 按位核对同一文件，金标只在该文件维护。
struct HDRDisplayGoldenSet {
    struct Case {
        let parameters: HDRDisplayParameters
        let halves: [UInt16]
    }

    let hdr: [Float]
    let sdr: [Float]
    let contentHeadroom: Float
    let cases: [Case]

    var pixelCount: Int { hdr.count / 3 }

    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    private struct FileData: Decodable {
        let version: Int
        let sets: [String: SetData]
    }

    private struct SetData: Decodable {
        let hdr: [Double]
        let sdr: [Double]
        let content_headroom_bits: String
        let cases: [CaseData]
    }

    private struct CaseData: Decodable {
        let headroom: Double
        let sdr: Bool
        let false_color: Bool
        let halves: [String]
    }

    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/hdr-display-goldens-v1.json")

    static func load(_ name: String) throws -> HDRDisplayGoldenSet {
        let file = try JSONDecoder().decode(FileData.self, from: Data(contentsOf: url))
        guard file.version == 1, let set = file.sets[name] else {
            throw LoadError(description: "\(url.path) has no version 1 golden set \(name)")
        }
        func bits(_ text: String) throws -> UInt32 {
            guard text.hasPrefix("0x"), let value = UInt32(text.dropFirst(2), radix: 16) else {
                throw LoadError(description: "\(name): invalid bit pattern \(text)")
            }
            return value
        }
        let cases = try set.cases.map { (item: CaseData) throws -> Case in
            let halves = try item.halves.map { text -> UInt16 in
                let value = try bits(text)
                guard value <= UInt32(UInt16.max) else { throw LoadError(description: "\(name): \(text) is not a half") }
                return UInt16(value)
            }
            guard halves.count == set.hdr.count else {
                throw LoadError(description: "\(name): case at headroom \(item.headroom) has \(halves.count) halves for \(set.hdr.count) channels")
            }
            return Case(
                parameters: HDRDisplayParameters(headroom: item.headroom, mode: item.sdr ? .sdr : .automatic,
                                                 falseColor: item.false_color),
                halves: halves)
        }
        guard !set.hdr.isEmpty, set.hdr.count % 3 == 0, set.sdr.count == set.hdr.count, !cases.isEmpty else {
            throw LoadError(description: "\(name): golden set needs matching RGB planes and at least one case")
        }
        return HDRDisplayGoldenSet(hdr: set.hdr.map(Float.init), sdr: set.sdr.map(Float.init),
                                   contentHeadroom: Float(bitPattern: try bits(set.content_headroom_bits)),
                                   cases: cases)
    }
}
