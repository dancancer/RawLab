import Foundation

enum HDRAdjustmentTransfer {
    typealias Field = AdjustmentTransferField
    typealias Value = AdjustmentTransferValue

    private static let scalarKeys: [Field: WritableKeyPath<HDRSettings, Double>] = [
        .exposure: \.exposure, .contrast: \.contrast, .highlights: \.highlights,
        .shadows: \.shadows, .saturation: \.saturation, .hdrTemperature: \.temperature, .hdrTint: \.tint
    ]
    private static let geometryKeys: [Field: WritableKeyPath<GeometrySettings, Double>] = [
        .cropX: \.cropX, .cropY: \.cropY, .cropWidth: \.cropWidth, .cropHeight: \.cropHeight,
        .straighten: \.straightenDegrees, .perspectiveHorizontal: \.perspectiveHorizontal,
        .perspectiveVertical: \.perspectiveVertical
    ]

    static func batchPayload(settings: HDRSettings,identifier: String,processingVersion: Int,
                             targetIsHDR: Bool) throws -> AdjustmentTransferPayload {
        var fields=Field.hdrSupported
        // 中性的相对 WB 对其他处理家族没有操作；非中性值仍交给 prepare 全量拒绝。
        if !targetIsHDR && settings.temperature==6500 && settings.tint==0 {
            fields.subtract([.hdrTemperature,.hdrTint])
        }
        return try capture(settings:settings,identifier:identifier,processingVersion:processingVersion,scope:.custom(fields))
    }

    static func capture(settings: HDRSettings, identifier: String, processingVersion: Int,
                        scope: AdjustmentTransferScope) throws -> AdjustmentTransferPayload {
        guard settings.mode == .hdr, settings.isValid else { throw AdjustmentTransferError.invalidPayload("hdr.settings") }
        let original = values(settings), neutral = values(HDRSettings())
        let selected: Set<Field>
        switch scope {
        case .all: selected = Field.hdrSupported
        case .modified: selected = Set(Field.hdrCommon.filter { original[$0.rawValue] != neutral[$0.rawValue] })
        case .custom(let fields):
            guard fields.isSubset(of: Field.hdrSupported) else {
                throw AdjustmentTransferError.incompatible(fields.subtracting(Field.hdrSupported).map(\.rawValue).sorted().joined(separator: ","))
            }
            selected = fields
        }
        return try AdjustmentTransferPayload(source: .init(identifier: identifier, isRaw: false,
            processingVersion: processingVersion, recipe: nil, hdrProcessingVersion: settings.processingVersion),
            values: original.filter { selected.contains(Field(rawValue: $0.key)!) })
    }

    static func prepare(payload: AdjustmentTransferPayload, target: HDRSettings) throws -> HDRSettings {
        try payload.validate()
        guard target.mode == .hdr, target.isValid else { throw AdjustmentTransferError.invalidPayload("hdr.target") }
        guard payload.fields.isSubset(of: Field.hdrSupported) else {
            throw AdjustmentTransferError.incompatible(payload.fields.subtracting(Field.hdrSupported).map(\.rawValue).sorted().joined(separator: ","))
        }
        var result = target
        let previous = values(target)
        for (field, key) in scalarKeys {
            // 规范化百分比往返会有 Double 舍入；相同逻辑值保持原快照，避免空历史事务。
            if payload[field] == previous[field.rawValue] { continue }
            guard let number = payload[field]?.number else { continue }
            switch field {
            case .contrast, .saturation: result[keyPath: key] = (number - 1) * 100
            case .highlights: result[keyPath: key] = -number * 100
            case .shadows: result[keyPath: key] = number * 100
            default: result[keyPath: key] = number
            }
        }
        for (field, key) in geometryKeys {
            if let number = payload[field]?.number { result.geometry[keyPath: key] = number }
        }
        if let value = payload[.quarterTurns]?.number { result.geometry.quarterTurns = Int(value) }
        if let value = payload[.flipHorizontal]?.boolean { result.geometry.flipHorizontal = value }
        if let value = payload[.flipVertical]?.boolean { result.geometry.flipVertical = value }
        guard result.isValid else { throw AdjustmentTransferError.incompatible("hdr.parameters") }
        return result
    }

    // 公共逻辑值可应用到既有模式；相对 WB 没有可转换成 RAW 绝对 WB 的隐式规则。
    static func legacyPayload(_ payload: AdjustmentTransferPayload) throws -> AdjustmentTransferPayload {
        try payload.validate()
        if !payload.source.isHDR { return payload }
        guard !payload.fields.contains(where: \.isHDRRelative) else {
            throw AdjustmentTransferError.incompatible("hdr.relative_white_balance")
        }
        return try AdjustmentTransferPayload(source: .init(identifier: payload.source.identifier, isRaw: false,
            processingVersion: payload.source.processingVersion, recipe: nil), values: payload.values)
    }

    private static func values(_ settings: HDRSettings) -> [String: Value] {
        var result: [String: Value] = [:]
        for (field, key) in scalarKeys {
            let value = settings[keyPath: key]
            let number: Double
            switch field {
            case .contrast, .saturation: number = 1 + value / 100
            case .highlights: number = -value / 100
            case .shadows: number = value / 100
            default: number = value
            }
            result[field.rawValue] = .number(number)
        }
        for (field, key) in geometryKeys { result[field.rawValue] = .number(settings.geometry[keyPath: key]) }
        result[Field.quarterTurns.rawValue] = .number(Double(settings.geometry.quarterTurns))
        result[Field.flipHorizontal.rawValue] = .boolean(settings.geometry.flipHorizontal)
        result[Field.flipVertical.rawValue] = .boolean(settings.geometry.flipVertical)
        return result
    }
}
