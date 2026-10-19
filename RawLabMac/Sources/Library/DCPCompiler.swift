// Tone interpolation follows the Adobe DNG SDK reference spline algorithm.
// Copyright 2006-2019 Adobe Systems Incorporated. All Rights Reserved.
// See lutools/third_party/Adobe-DNG-SDK-LICENSE.txt for the retained license.
import Foundation
import simd
import Accelerate

enum DCPCompilerError: Error, LocalizedError, Equatable {
    case malformed, tooLarge, invalidCalibration, missingToneCurve, automaticBlack
    case tripleIlluminant, unsupportedStages, invalidTable, invalidToneCurve, invalidExposure

    var errorDescription: String? {
        switch self {
        case .malformed: return L10n.text("DCP 文件损坏，或使用了不支持的 TIFF 结构。")
        case .tooLarge: return L10n.text("DCP 文件或外观数据超过安全大小限制。")
        case .invalidCalibration: return L10n.text("DCP 缺少唯一、有效的 D65 ColorMatrix/ForwardMatrix，无法转换。")
        case .missingToneCurve: return L10n.text("DCP 缺少 ProfileToneCurve；无法自动推断 Adobe 默认曲线。请先用制备工具明确指定曲线。")
        case .automaticBlack: return L10n.text("DCP 要求自动黑位处理，Mac 自动转换暂不支持。请先用制备工具明确选择黑位策略。")
        case .tripleIlluminant: return L10n.text("DCP 使用三光源 HueSatMap，暂不支持转换。")
        case .unsupportedStages: return L10n.text("DCP 包含暂不支持的空间增益、HDR 或 RGB 表处理，无法转换。")
        case .invalidTable: return L10n.text("DCP 的 HueSatMap/LookTable 数据、维度或编码不受支持。")
        case .invalidToneCurve: return L10n.text("DCP 曲线无效；需要 2 至 8192 个有限、范围为 0 至 1 且横坐标递增的点。")
        case .invalidExposure: return L10n.text("DCP 曝光偏移无效；需要 -16 至 +16 EV 的有限数值。")
        }
    }
}

// 与 lutprep/dcp.py 的 D65 适配及 RLOOK v1/v2 契约保持一致，不执行完整 Adobe 显影。
enum DCPCompiler {
    private static let maxSourceBytes = 128 * 1024 * 1024
    private static let maxCells = 4_000_000
    private typealias Matrix = simd_double3x3
    private static let srgb = matrix([0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041])
    private static let prophoto = matrix([0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0, 0, 0.8252100])
    private static let bradford = matrix([0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296])
    private static let d65 = SIMD3<Double>(0.95047, 1, 1.08883)
    private static let d50 = SIMD3<Double>(0.96422, 1, 0.82521)
    private static let srgbToProphoto = prophoto.inverse * bradford.inverse * diagonal((bradford * d50) / (bradford * d65)) * bradford * srgb

    static func compile(source: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        // 有界读取也覆盖检查文件大小后源文件被替换/增长的情况。
        let data = try handle.read(upToCount: maxSourceBytes + 1) ?? Data()
        return try compile(data: data, sourceName: source.lastPathComponent)
    }

    static func compile(data: Data, sourceName: String) throws -> Data {
        let reader = try Reader(data)
        let tags = reader.tags
        if !Set(tags.keys).isDisjoint(with: [52525, 52539, 52543, 52544, 52551]) {
            throw DCPCompilerError.unsupportedStages
        }
        let pairs: [[UInt16]] = [[50778, 50721, 50964], [50779, 50722, 50965], [52529, 52531, 52532]]
        let matches = try pairs.filter { try reader.scalar($0[0], kind: 3, fallback: 0) == 21 }
        guard matches.count == 1 else { throw DCPCompilerError.invalidCalibration }
        let pair = matches[0]
        let color = try reader.calibration(pair[1])
        var forward = try reader.calibration(pair[2])
        guard hasFullRank(color) else { throw DCPCompilerError.invalidCalibration }
        let white = color * d65
        let forwardWhite = forward * SIMD3<Double>(repeating: 1)
        guard (0..<3).allSatisfy({ white[$0].isFinite && white[$0] > 0 && forwardWhite[$0].isFinite && forwardWhite[$0] > 0 }) else {
            throw DCPCompilerError.invalidCalibration
        }
        forward = diagonal((prophoto * SIMD3<Double>(repeating: 1)) / forwardWhite) * forward
        let input = prophoto.inverse * forward * diagonal(1 / white) * color * srgb
        let output = srgbToProphoto.inverse
        guard finite(input), finite(output) else { throw DCPCompilerError.invalidCalibration }

        var calibration: Table?, selectedHSM: UInt16?
        if !Set(tags.keys).isDisjoint(with: [50937, 50938, 50939, 51107, 52537]) {
            guard tags[52529] == nil, tags[52537] == nil else { throw DCPCompilerError.tripleIlluminant }
            guard tags[50937] != nil, tags[50938] != nil else { throw DCPCompilerError.invalidTable }
            selectedHSM = tags[50939] != nil && pair[0] == 50779 ? 50939 : 50938
            for key: UInt16 in [50938, 50939] where tags[key] != nil {
                let table = try reader.table(dimensions: 50937, data: key, encoding: 51107)
                if key == selectedHSM { calibration = table }
            }
        }
        var look: Table?
        if !Set(tags.keys).isDisjoint(with: [50981, 50982, 51108]) {
            look = try reader.table(dimensions: 50981, data: 50982, encoding: 51108)
        }
        guard (calibration?.cells ?? 0) + (look?.cells ?? 0) <= maxCells else { throw DCPCompilerError.tooLarge }
        guard let curveTag = tags[50940] else { throw DCPCompilerError.missingToneCurve }
        guard curveTag.kind == 11, curveTag.count >= 4, curveTag.count <= 16384, curveTag.count % 2 == 0 else {
            throw DCPCompilerError.invalidToneCurve
        }
        let points = try reader.numbers(curveTag)
        let tone = try toneSamples(points)
        // 自动导入没有曲线/黑位的交互选项，不静默沿用 CLI 旧版省略 Auto black 的行为。
        guard try reader.scalar(51110, kind: 4, fallback: 0) == 1 else { throw DCPCompilerError.automaticBlack }
        let exposure = try reader.scalar(51109, kind: 10, fallback: 0)
        guard exposure.isFinite, abs(exposure) <= 16 else { throw DCPCompilerError.invalidExposure }
        let version: UInt32 = calibration != nil || look == nil ? 2 : 1
        var consumed: Set<UInt16> = [50940, 50981, 50982, 51108, 51109, 51110]
        consumed.formUnion(pair)
        if let selectedHSM { consumed.formUnion([50937, selectedHSM, 51107]) }
        let metadataTags: Set<UInt16> = [50708, 50932, 50936, 50941, 50942]
        let metadata: [String: Any] = [
            "version": "mac-native-1", "format_version": version, "mode": "native-dcp",
            "source": sourceName, "rgb_cube_baked": false,
            "input": "scene-linear-srgb-d65", "output": "display-srgb",
            "evaluation": "CPU double reference; optional GPU float32",
            "dcp": ["format": "dcp", "canonical": false,
                    "name": try reader.text(50936), "source_model": try reader.text(50708),
                    "look_dimensions": look?.dimensions as Any? ?? NSNull(),
                    "hue_sat_map_dimensions": calibration?.dimensions as Any? ?? NSNull(),
                    "hue_sat_map_encoding": calibration?.encoding ?? 0,
                    "hue_sat_map_data_tag": selectedHSM as Any? ?? NSNull(),
                    "look_encoding": look?.encoding ?? 0,
                    "tone_points": points.count / 2, "tone_source": "profile",
                    "black_render_policy": "none-profile", "profile_exposure_ev": exposure,
                    "apply_profile_exposure": true,
                    "exposure_method": "linear EV before look; not Adobe exposure-tone emulation",
                    "input_adapter": "d65-white-relative-virtual-camera",
                    "input_calibration_tags": pair,
                    "excluded_tags": Set(tags.keys).subtracting(consumed).subtracting(metadataTags).sorted(),
                    "scope": "D65-adapted profile appearance; target RAW calibration/WB unchanged; no Adobe rendering parity"]
        ]
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard json.count <= 65536 else { throw DCPCompilerError.tooLarge }
        var result = Data("RLOOKDCP".utf8)
        for value in [version, 0] + (look?.header ?? [0, 0, 0, 0]) + [4097, UInt32(json.count)] { append(value, to: &result) }
        if version == 2 { for value in calibration?.header ?? [0, 0, 0, 0] { append(value, to: &result) } }
        for value in rows(input) + rows(output) + [pow(2, exposure)] { append(value.bitPattern, to: &result) }
        for table in [calibration, look].compactMap({ $0 }) {
            for value in table.values { append(value.bitPattern, to: &result) }
        }
        for value in tone { append(value.bitPattern, to: &result) }
        result.append(json)
        guard result.count <= 64 * 1024 * 1024 else { throw DCPCompilerError.tooLarge }
        return result
    }

    private struct Table {
        let hues: Int, sats: Int, valuesCount: Int, encoding: UInt32
        let values: [Float]
        var cells: Int { hues * sats * valuesCount }
        var dimensions: [Int] { [hues, sats, valuesCount] }
        var header: [UInt32] { [encoding, UInt32(hues), UInt32(sats), UInt32(valuesCount)] }
    }

    private struct Tag {
        let kind: UInt16, count: Int, offset: Int
    }

    private struct Reader {
        let bytes: [UInt8]
        let bigEndian: Bool
        var tags: [UInt16: Tag] = [:]

        init(_ data: Data) throws {
            guard data.count <= maxSourceBytes else { throw DCPCompilerError.tooLarge }
            bytes = Array(data)
            guard bytes.count >= 8, Array(bytes[0..<2]) == [73, 73] || Array(bytes[0..<2]) == [77, 77] else {
                throw DCPCompilerError.malformed
            }
            bigEndian = bytes[0] == 77
            let magic = integer(2, 2), start = Int(integer(4, 4))
            guard [42, 0x4352].contains(magic), start >= 8, start <= bytes.count - 2 else { throw DCPCompilerError.malformed }
            let count = Int(integer(start, 2)), end = start + 2 + count * 12
            guard count <= 4096, end <= bytes.count - 4, integer(end, 4) == 0 else { throw DCPCompilerError.malformed }
            let sizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
            var rationalCount = 0
            for index in 0..<count {
                let base = start + 2 + index * 12
                let key = UInt16(integer(base, 2)), kind = UInt16(integer(base + 2, 2))
                guard tags[key] == nil, (1...12).contains(kind) else { throw DCPCompilerError.malformed }
                let length = Int(integer(base + 4, 4)), size = length * sizes[Int(kind)]
                let offset = size <= 4 ? base + 8 : Int(integer(base + 8, 4))
                guard offset <= bytes.count, size <= bytes.count - offset else { throw DCPCompilerError.malformed }
                let tag = Tag(kind: kind, count: length, offset: offset)
                if kind == 5 || kind == 10 {
                    // TIFF 可让多个标签引用同一范围；总解析量不能随重叠标签数量放大。
                    guard length <= bytes.count / 8 - rationalCount else { throw DCPCompilerError.tooLarge }
                    rationalCount += length
                    for point in 0..<length where integer(offset + point * 8 + 4, 4) == 0 { throw DCPCompilerError.malformed }
                }
                tags[key] = tag
            }
        }

        func integer(_ offset: Int, _ width: Int) -> UInt64 {
            var result: UInt64 = 0
            for index in 0..<width {
                result |= UInt64(bytes[offset + index]) << ((bigEndian ? width - 1 - index : index) * 8)
            }
            return result
        }

        func numbers(_ tag: Tag) throws -> [Double] {
            let widths = [3: 2, 4: 4, 10: 8, 11: 4]
            guard let width = widths[Int(tag.kind)] else { throw DCPCompilerError.malformed }
            return (0..<tag.count).map { index in
                let offset = tag.offset + index * width
                if tag.kind == 11 { return Double(Float(bitPattern: UInt32(integer(offset, 4)))) }
                if tag.kind == 10 {
                    return Double(Int32(bitPattern: UInt32(integer(offset, 4)))) / Double(Int32(bitPattern: UInt32(integer(offset + 4, 4))))
                }
                return Double(integer(offset, width))
            }
        }

        func scalar(_ key: UInt16, kind: UInt16, fallback: Double) throws -> Double {
            guard let tag = tags[key] else { return fallback }
            guard tag.kind == kind, tag.count == 1 else { throw DCPCompilerError.malformed }
            return try numbers(tag)[0]
        }

        func calibration(_ key: UInt16) throws -> Matrix {
            guard let tag = tags[key], tag.kind == 10, tag.count == 9 else { throw DCPCompilerError.invalidCalibration }
            let value = matrix(try numbers(tag))
            guard finite(value) else { throw DCPCompilerError.invalidCalibration }
            return value
        }

        func text(_ key: UInt16) throws -> String {
            guard let tag = tags[key] else { return "" }
            guard tag.kind == 1 || tag.kind == 2 else { throw DCPCompilerError.malformed }
            var value = Array(bytes[tag.offset..<(tag.offset + tag.count)])
            while value.last == 0 { value.removeLast() }
            return String(decoding: value, as: UTF8.self)
        }

        func table(dimensions: UInt16, data: UInt16, encoding: UInt16) throws -> Table {
            guard let dims = tags[dimensions], dims.kind == 4, (2...3).contains(dims.count),
                  let tag = tags[data], tag.kind == 11 else { throw DCPCompilerError.invalidTable }
            let shape = try numbers(dims).map(Int.init)
            let hues = shape[0], sats = shape[1], values = shape.count == 3 ? shape[2] : 1
            guard hues >= 1, sats >= 2, values >= 1,
                  hues <= maxCells / sats, hues * sats <= maxCells / values else { throw DCPCompilerError.invalidTable }
            let code = try scalar(encoding, kind: 4, fallback: 0)
            guard code == 0 || code == 1, !(values == 1 && code == 1) else { throw DCPCompilerError.invalidTable }
            let count = hues * sats * values
            let omitted = tag.count == hues * (sats - 1) * values * 3
            guard tag.count == count * 3 || omitted else { throw DCPCompilerError.invalidTable }
            let source = try numbers(tag)
            guard source.enumerated().allSatisfy({ $0.element.isFinite && ($0.offset % 3 == 0 || $0.element >= 0) }) else {
                throw DCPCompilerError.invalidTable
            }
            var result = [Float](repeating: 0, count: count * 3)
            for value in 0..<values { for hue in 0..<hues { for sat in 0..<sats {
                let target = ((value * hues + hue) * sats + sat) * 3
                let inputSat = omitted ? max(0, sat - 1) : sat
                let origin = ((value * hues + hue) * (omitted ? sats - 1 : sats) + inputSat) * 3
                for channel in 0..<3 { result[target + channel] = channel == 2 && sat == 0 ? 1 : Float(source[origin + channel]) }
            } } }
            return Table(hues: hues, sats: sats, valuesCount: values, encoding: UInt32(code), values: result)
        }
    }

    private static func toneSamples(_ points: [Double]) throws -> [Double] {
        let count = points.count / 2
        let x = stride(from: 0, to: points.count, by: 2).map { points[$0] }
        let y = stride(from: 1, to: points.count, by: 2).map { points[$0] }
        guard points.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              (1..<count).allSatisfy({ x[$0] > x[$0 - 1] }) else { throw DCPCompilerError.invalidToneCurve }
        let h = (1..<count).map { x[$0] - x[$0 - 1] }
        var second = [Double](repeating: 0, count: count)
        if count > 2 {
            var diagonal = (0..<(count - 2)).map { 2 * (h[$0] + h[$0 + 1]) }
            var rhs = [Double](repeating: 0, count: count - 2)
            for j in rhs.indices {
                let rightSlope = (y[j + 2] - y[j + 1]) / h[j + 1]
                let leftSlope = (y[j + 1] - y[j]) / h[j]
                rhs[j] = 6 * (rightSlope - leftSlope)
            }
            if diagonal.count > 1 { for j in 1..<diagonal.count {
                let ratio = h[j] / diagonal[j - 1]
                diagonal[j] -= ratio * h[j]
                rhs[j] -= ratio * rhs[j - 1]
            } }
            for j in diagonal.indices.reversed() { second[j + 1] = (rhs[j] - h[j + 1] * second[j + 2]) / diagonal[j] }
        }
        var result = [Double](), index = 0
        result.reserveCapacity(4097)
        for step in 0...4096 {
            let t = Double(step) / 4096
            if t <= x[0] { result.append(y[0]); continue }
            if t >= x[count - 1] { result.append(y[count - 1]); continue }
            while index < count - 2 && t > x[index + 1] { index += 1 }
            let width = h[index], a = (x[index + 1] - t) / width, b = (t - x[index]) / width
            let value = a * y[index] + b * y[index + 1] + width * width / 6 *
                ((a * a * a - a) * second[index] + (b * b * b - b) * second[index + 1])
            guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else { throw DCPCompilerError.invalidToneCurve }
            result.append(value)
        }
        return result
    }

    private static func matrix(_ rows: [Double]) -> Matrix {
        Matrix(columns: (SIMD3(rows[0], rows[3], rows[6]), SIMD3(rows[1], rows[4], rows[7]), SIMD3(rows[2], rows[5], rows[8])))
    }

    private static func hasFullRank(_ matrix: Matrix) -> Bool {
        // 与 NumPy matrix_rank 的默认奇异值阈值一致，不能只检查行列式非零。
        var values = rows(matrix.transpose)
        var jobU: Int8 = 78, jobVT: Int8 = 78
        var m: __CLPK_integer = 3, n: __CLPK_integer = 3, lda: __CLPK_integer = 3
        var ldu: __CLPK_integer = 1, ldvt: __CLPK_integer = 1, lwork: __CLPK_integer = 32, info: __CLPK_integer = 0
        var singular = [Double](repeating: 0, count: 3), work = [Double](repeating: 0, count: 32)
        var u = 0.0, vt = 0.0
        dgesvd_(&jobU, &jobVT, &m, &n, &values, &lda, &singular, &u, &ldu, &vt, &ldvt, &work, &lwork, &info)
        return info == 0 && singular.allSatisfy(\.isFinite) && singular[2] > singular[0] * 3 * Double.ulpOfOne
    }

    private static func diagonal(_ value: SIMD3<Double>) -> Matrix { Matrix(diagonal: value) }
    private static func rows(_ value: Matrix) -> [Double] { (0..<9).map { value[$0 % 3][$0 / 3] } }
    private static func finite(_ value: Matrix) -> Bool { rows(value).allSatisfy { $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) } }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
