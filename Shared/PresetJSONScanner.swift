import Foundation

// P2-16 三端共享的严格 JSON 语法合同：拒绝尾逗号、注释、重复键、非标准数字。
// 语法层失败由调用方映射为整库错误；条目子树问题（hasDuplicateKey）只降级单条。
// 与 Android StrictJSON / Windows JsonDocument 拒绝语义保持一致。

enum PresetJSONError: Error { case invalid }

enum PresetJSONValue {
    indirect case object(members: [(key: String, value: PresetJSONNode)], ownDuplicate: Bool)
    case array([PresetJSONNode])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

struct PresetJSONNode {
    let value: PresetJSONValue
    let range: Range<Int>
    // 自身或后代对象存在重复键；文件级检查只看根对象 ownDuplicate。
    let hasDuplicateKey: Bool
}

enum PresetJSONScanner {
    static func scan(_ bytes: [UInt8]) throws -> PresetJSONNode {
        var index = 0
        let root = try parse(bytes, &index, depth: 0)
        skipSpace(bytes, &index)
        guard index == bytes.count else { throw PresetJSONError.invalid }
        return root
    }

    static func isIntegerLiteral(_ literal: String) -> Bool {
        literal.first == "-" ? literal.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) && literal.count > 1
            : literal.allSatisfy({ $0.isASCII && $0.isNumber }) && !literal.isEmpty
    }

    private static func skipSpace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 32 { index += 1 }
    }

    private static func parse(_ bytes: [UInt8], _ index: inout Int, depth: Int) throws -> PresetJSONNode {
        guard depth <= 64 else { throw PresetJSONError.invalid }
        skipSpace(bytes, &index)
        guard index < bytes.count else { throw PresetJSONError.invalid }
        let start = index
        switch bytes[index] {
        case 0x7B:
            index += 1
            var members: [(key: String, value: PresetJSONNode)] = []
            var seen = Set<String>(), ownDuplicate = false, nested = false
            skipSpace(bytes, &index)
            if index < bytes.count, bytes[index] == 0x7D { index += 1; return PresetJSONNode(value: .object(members: members, ownDuplicate: false), range: start..<index, hasDuplicateKey: false) }
            while true {
                skipSpace(bytes, &index)
                guard index < bytes.count, bytes[index] == 0x22 else { throw PresetJSONError.invalid }
                let key = try parseString(bytes, &index)
                skipSpace(bytes, &index)
                guard index < bytes.count, bytes[index] == 0x3A else { throw PresetJSONError.invalid }
                index += 1
                let value = try parse(bytes, &index, depth: depth + 1)
                nested = nested || value.hasDuplicateKey
                if seen.contains(key) { ownDuplicate = true } else { seen.insert(key) }
                members.append((key, value))
                skipSpace(bytes, &index)
                if index < bytes.count, bytes[index] == 0x7D { index += 1; break }
                guard index < bytes.count, bytes[index] == 0x2C else { throw PresetJSONError.invalid }
                index += 1
            }
            return PresetJSONNode(value: .object(members: members, ownDuplicate: ownDuplicate), range: start..<index, hasDuplicateKey: ownDuplicate || nested)
        case 0x5B:
            index += 1
            var items: [PresetJSONNode] = []
            var nested = false
            skipSpace(bytes, &index)
            guard index < bytes.count else { throw PresetJSONError.invalid }
            if bytes[index] == 0x5D { index += 1; return PresetJSONNode(value: .array(items), range: start..<index, hasDuplicateKey: false) }
            while true {
                let item = try parse(bytes, &index, depth: depth + 1)
                nested = nested || item.hasDuplicateKey
                items.append(item)
                skipSpace(bytes, &index)
                if index < bytes.count, bytes[index] == 0x5D { index += 1; break }
                guard index < bytes.count, bytes[index] == 0x2C else { throw PresetJSONError.invalid }
                index += 1
            }
            return PresetJSONNode(value: .array(items), range: start..<index, hasDuplicateKey: nested)
        case 0x22:
            let value = try parseString(bytes, &index)
            return PresetJSONNode(value: .string(value), range: start..<index, hasDuplicateKey: false)
        case 0x74: return try parseLiteral("true", bytes, &index, .boolean(true), start)
        case 0x66: return try parseLiteral("false", bytes, &index, .boolean(false), start)
        case 0x6E: return try parseLiteral("null", bytes, &index, .null, start)
        default:
            let digits = Set("-0123456789.eE+".utf8)
            while index < bytes.count, digits.contains(bytes[index]) { index += 1 }
            let literal = String(decoding: bytes[start..<index], as: UTF8.self)
            guard isValidNumber(literal) else { throw PresetJSONError.invalid }
            return PresetJSONNode(value: .number(literal), range: start..<index, hasDuplicateKey: false)
        }
    }

    private static func parseLiteral(_ literal: String, _ bytes: [UInt8], _ index: inout Int, _ value: PresetJSONValue, _ start: Int) throws -> PresetJSONNode {
        let token = Array(literal.utf8)
        guard start + token.count <= bytes.count, Array(bytes[start..<start + token.count]) == token else { throw PresetJSONError.invalid }
        index = start + token.count
        return PresetJSONNode(value: value, range: start..<index, hasDuplicateKey: false)
    }

    // 标准 JSON 数字：-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?；拒绝前导零、+.5、1.、1e。
    private static func isValidNumber(_ literal: String) -> Bool {
        var rest = literal[...]
        if rest.first == "-" { rest = rest.dropFirst() }
        guard let first = rest.first, first.isASCII, first.isNumber else { return false }
        if first == "0" {
            rest = rest.dropFirst()
            if let next = rest.first, next.isASCII, next.isNumber { return false }
        } else {
            var seen = 0
            while let c = rest.first, c.isASCII, c.isNumber { rest = rest.dropFirst(); seen += 1 }
            guard seen > 0 else { return false }
        }
        if rest.first == "." {
            rest = rest.dropFirst()
            var seen = 0
            while let c = rest.first, c.isASCII, c.isNumber { rest = rest.dropFirst(); seen += 1 }
            guard seen > 0 else { return false }
        }
        if rest.first == "e" || rest.first == "E" {
            rest = rest.dropFirst()
            if rest.first == "+" || rest.first == "-" { rest = rest.dropFirst() }
            var seen = 0
            while let c = rest.first, c.isASCII, c.isNumber { rest = rest.dropFirst(); seen += 1 }
            guard seen > 0 else { return false }
        }
        return rest.isEmpty
    }

    private static func parseString(_ bytes: [UInt8], _ index: inout Int) throws -> String {
        index += 1 // 开引号
        var out = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 { index += 1; return out }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { break }
                switch bytes[index] {
                case 0x22: out.append("\""); index += 1
                case 0x5C: out.append("\\"); index += 1
                case 0x2F: out.append("/"); index += 1
                case 0x62: out.append("\u{8}"); index += 1
                case 0x66: out.append("\u{C}"); index += 1
                case 0x6E: out.append("\n"); index += 1
                case 0x72: out.append("\r"); index += 1
                case 0x74: out.append("\t"); index += 1
                case 0x75:
                    var code: UInt32 = 0
                    for _ in 0..<4 {
                        guard index + 1 < bytes.count else { throw PresetJSONError.invalid }
                        index += 1
                        let digit = bytes[index]
                        let value: UInt32
                        switch digit {
                        case 0x30...0x39: value = UInt32(digit - 0x30)
                        case 0x61...0x66: value = UInt32(digit - 0x61 + 10)
                        case 0x41...0x46: value = UInt32(digit - 0x41 + 10)
                        default: throw PresetJSONError.invalid
                        }
                        code = code &* 16 &+ value
                    }
                    index += 1
                    if (0xD800...0xDBFF).contains(code) {
                        // 高代理项必须紧跟 \uDC00–\uDFFF 低代理项组成一个标量。
                        guard index + 5 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else { throw PresetJSONError.invalid }
                        var low: UInt32 = 0
                        for offset in 2..<6 {
                            let digit = bytes[index + offset]
                            let value: UInt32
                            switch digit {
                            case 0x30...0x39: value = UInt32(digit - 0x30)
                            case 0x61...0x66: value = UInt32(digit - 0x61 + 10)
                            case 0x41...0x46: value = UInt32(digit - 0x41 + 10)
                            default: throw PresetJSONError.invalid
                            }
                            low = low &* 16 &+ value
                        }
                        guard (0xDC00...0xDFFF).contains(low),
                              let scalar = Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) else { throw PresetJSONError.invalid }
                        out.unicodeScalars.append(scalar)
                        index += 6
                    } else if (0xDC00...0xDFFF).contains(code) {
                        throw PresetJSONError.invalid // 落单的低代理项
                    } else {
                        guard let scalar = Unicode.Scalar(code) else { throw PresetJSONError.invalid }
                        out.unicodeScalars.append(scalar)
                    }
                default: throw PresetJSONError.invalid
                }
            } else {
                let runStart = index
                while index < bytes.count, bytes[index] != 0x22, bytes[index] != 0x5C {
                    guard bytes[index] >= 0x20 else { throw PresetJSONError.invalid }
                    index += 1
                }
                out += String(decoding: bytes[runStart..<index], as: UTF8.self)
            }
        }
        throw PresetJSONError.invalid // 未闭合字符串
    }
}
