import Foundation

enum DCPTestFixtures {
    struct Tag {
        let kind: UInt16
        let count: UInt32
        let bytes: Data
    }

    static func make(bigEndian: Bool = false, missing: Set<UInt16> = [],
                     override: [UInt16: Tag] = [:]) -> Data {
        func integer(_ value: UInt64, _ width: Int) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ((bigEndian ? width - 1 - $0 : $0) * 8)) })
        }
        func tag(_ kind: UInt16, _ values: [UInt64], width: Int) -> Tag {
            Tag(kind: kind, count: UInt32(values.count), bytes: values.reduce(into: Data()) { $0.append(integer($1, width)) })
        }
        func matrix(_ values: [Double]) -> Tag {
            let bytes = values.reduce(into: Data()) { result, value in
                result.append(integer(UInt64(UInt32(bitPattern: Int32((value * 10_000_000).rounded()))), 4))
                result.append(integer(10_000_000, 4))
            }
            return Tag(kind: 10, count: 9, bytes: bytes)
        }
        let table: [Float] = (0..<8).flatMap { _ in [0, 1, 1] }
        var tags: [UInt16: Tag] = [
            50708: Tag(kind: 2, count: 17, bytes: Data("Synthetic Camera\0".utf8)),
            50722: matrix([1, 0, 0, 0, 1, 0, 0, 0, 1]),
            50779: tag(3, [21], width: 2),
            50936: Tag(kind: 2, count: 15, bytes: Data("Synthetic Look\0".utf8)),
            50940: tag(11, [Float(0).bitPattern, Float(0).bitPattern, Float(1).bitPattern, Float(1).bitPattern].map(UInt64.init), width: 4),
            50965: matrix([0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0, 0, 0.8252100]),
            50981: tag(4, [2, 2, 2], width: 4),
            50982: tag(11, table.map { UInt64($0.bitPattern) }, width: 4),
            51110: tag(4, [1], width: 4)
        ]
        tags.merge(override) { _, new in new }
        for key in missing { tags.removeValue(forKey: key) }
        var payload = Data(), entries = Data()
        let start = 8 + 2 + tags.count * 12 + 4
        for key in tags.keys.sorted() {
            let value = tags[key]!
            entries.append(integer(UInt64(key), 2))
            entries.append(integer(UInt64(value.kind), 2))
            entries.append(integer(UInt64(value.count), 4))
            if value.bytes.count <= 4 {
                entries.append(value.bytes)
                entries.append(Data(repeating: 0, count: 4 - value.bytes.count))
            } else {
                entries.append(integer(UInt64(start + payload.count), 4))
                payload.append(value.bytes)
            }
        }
        var result = Data((bigEndian ? "MM" : "II").utf8)
        result.append(integer(0x4352, 2))
        result.append(integer(8, 4))
        result.append(integer(UInt64(tags.count), 2))
        result.append(entries)
        result.append(Data(repeating: 0, count: 4))
        result.append(payload)
        return result
    }

    static func uint32(_ value: UInt32) -> Tag {
        var value = value.littleEndian
        return Tag(kind: 4, count: 1, bytes: withUnsafeBytes(of: &value) { Data($0) })
    }

    static func rationals(_ values: [(Int32, Int32)]) -> Tag {
        var bytes = Data()
        for pair in values { for value in [pair.0, pair.1] {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        } }
        return Tag(kind: 10, count: UInt32(values.count), bytes: bytes)
    }

    static func overlappingRationals() -> Data {
        let payload = rationals(Array(repeating: (1, 1), count: 1000))
        var result = make(override: [60000: payload, 60001: payload])
        func number(_ offset: Int, _ width: Int) -> Int {
            (0..<width).reduce(0) { $0 | Int(result[offset + $1]) << ($1 * 8) }
        }
        var shared = 0, unused = 0
        for index in 0..<number(8, 2) {
            let base = 10 + index * 12
            if number(base, 2) == 60000 { shared = number(base + 8, 4) }
            if number(base, 2) == 60001 {
                unused = number(base + 8, 4)
                for byte in 0..<4 { result[base + 8 + byte] = UInt8(truncatingIfNeeded: shared >> (byte * 8)) }
            }
        }
        result.removeSubrange(unused..<result.count)
        return result
    }
}
