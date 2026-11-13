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
    private static let renditionKeys: [Field: WritableKeyPath<HDRRenditionSettings, Double>] = [
        .hdrPeakLimit: \.peakLimitEV, .hdrSDRExposure: \.sdrExposureEV,
        .hdrSDRContrast: \.sdrContrast, .hdrSDRSaturation: \.sdrSaturation
    ]
    private static let effectKeys: [Field: WritableKeyPath<HDRPhotoEffectsSettings, Double>] = [
        .vignetteAmount: \.vignetteAmount, .vignetteMidpoint: \.vignetteMidpoint, .vignetteRoundness: \.vignetteRoundness,
        .vignetteFeather: \.vignetteFeather, .vignetteHighlights: \.vignetteHighlights,
        .grainAmount: \.grainAmount, .grainSize: \.grainSize, .grainRoughness: \.grainRoughness
    ]
    private static let detailKeys: [Field: WritableKeyPath<HDRDetailSettings, Double>] = [
        .sharpening: \.sharpening, .clarity: \.clarity, .dehaze: \.dehaze, .postRGBDenoise: \.denoise
    ]

    static func batchPayload(settings: HDRSettings,identifier: String,processingVersion: Int,
                             targetIsHDR: Bool) throws -> AdjustmentTransferPayload {
        var fields = Field.hdrSupported(version: settings.processingVersion)
        // 中性的相对 WB 对其他处理家族没有操作；非中性值仍交给 prepare 全量拒绝。
        if !targetIsHDR && settings.temperature==6500 && settings.tint==0 {
            fields.subtract([.hdrTemperature,.hdrTint])
        }
        if !targetIsHDR && settings.toneSettings.isDefault { fields.subtract(Field.hdrTone) }
        if !targetIsHDR && settings.colorSettings.isDefault { fields.subtract(Field.hdrColor) }
        if !targetIsHDR && settings.renditionSettings.isDefault { fields.subtract(Field.hdrRendition) }
        if !targetIsHDR && settings.effectsSettings.isDefault { fields.subtract(Field.hdrEffects) }
        if !targetIsHDR && settings.detailSettings.isDefault { fields.subtract(Field.hdrDetail) }
        if !targetIsHDR && settings.lookSettings.isDefault { fields.remove(.hdrLook) }
        return try capture(settings:settings,identifier:identifier,processingVersion:processingVersion,scope:.custom(fields))
    }

    static func capture(settings: HDRSettings, identifier: String, processingVersion: Int,
                        scope: AdjustmentTransferScope, cameraRAW: Bool = false) throws -> AdjustmentTransferPayload {
        guard settings.mode == .hdr, settings.isValid else { throw AdjustmentTransferError.invalidPayload("hdr.settings") }
        let allowed = Field.hdrTransferFields(cameraRAW: cameraRAW)
        var original = values(settings), neutral = values(HDRSettings())
        if cameraRAW {
            original[Field.hdrCameraDevelopment.rawValue] = cameraValue(settings.cameraDevelopmentSettings)
            neutral[Field.hdrCameraDevelopment.rawValue] = cameraValue(HDRCameraDevelopmentSettings())
        }
        let selected: Set<Field>
        switch scope {
        case .all:
            let base = Field.hdrSupported(version: settings.processingVersion)
            selected = original[Field.hdrCameraDevelopment.rawValue] != neutral[Field.hdrCameraDevelopment.rawValue]
                ? base.union([.hdrCameraDevelopment]) : base
        case .modified:
            selected = Set(allowed.subtracting(Field.hdrGeometry).filter {
                original[$0.rawValue] != neutral[$0.rawValue]
            })
        case .custom(let fields):
            guard fields.isSubset(of: allowed) else {
                throw AdjustmentTransferError.incompatible(fields.subtracting(allowed).map(\.rawValue).sorted().joined(separator: ","))
            }
            selected = fields
        }
        let requiredVersion: Int
        if selected.contains(.hdrLook) { requiredVersion = 7 }
        else if !selected.isDisjoint(with: Field.hdrDetail) { requiredVersion = 6 }
        else if !selected.isDisjoint(with: Field.hdrEffects) { requiredVersion = 5 }
        else if !selected.isDisjoint(with: Field.hdrRendition) { requiredVersion = 4 }
        else if !selected.isDisjoint(with: Field.hdrColor) { requiredVersion = 3 }
        else { requiredVersion = selected.isDisjoint(with: Field.hdrTone) ? 1 : 2 }
        let hdrVersion = max(requiredVersion, settings.processingVersion)
        return try AdjustmentTransferPayload(source: .init(identifier: identifier, isRaw: false,
            processingVersion: processingVersion, recipe: nil, hdrProcessingVersion: hdrVersion),
            values: original.filter { selected.contains(Field(rawValue: $0.key)!) })
    }

    static func prepare(payload: AdjustmentTransferPayload, target: HDRSettings, cameraRAW: Bool = false) throws -> HDRSettings {
        try payload.validate()
        guard target.mode == .hdr, target.isValid else { throw AdjustmentTransferError.invalidPayload("hdr.target") }
        let allowed = Field.hdrTransferFields(cameraRAW: cameraRAW)
        guard payload.fields.isSubset(of: allowed) else {
            throw AdjustmentTransferError.incompatible(payload.fields.subtracting(allowed).map(\.rawValue).sorted().joined(separator: ","))
        }
        guard payload.source.isHDR || payload.fields.isDisjoint(with: Field.hdrTone) else {
            throw AdjustmentTransferError.incompatible("hdr.tone")
        }
        guard payload.source.isHDR || payload.fields.isDisjoint(with: Field.hdrColor) else {
            throw AdjustmentTransferError.incompatible("hdr.color")
        }
        guard payload.source.isHDR || payload.fields.isDisjoint(with: Field.hdrEffects) else {
            throw AdjustmentTransferError.incompatible("hdr.effects")
        }
        guard payload.source.isHDR || payload.fields.isDisjoint(with: Field.hdrDetail) else {
            throw AdjustmentTransferError.incompatible("hdr.detail")
        }
        var result = target
        let previous = values(target)
        for (field, key) in scalarKeys {
            guard var number = payload[field]?.number else { continue }
            // 带配方的普通来源复制的是配方逻辑值；与普通目标一致，按来源强度换算为实际贡献。
            if let scale = payload.source.recipe?.strength, scale != 1 {
                number = field == .contrast || field == .saturation ? 1 + (number - 1) * scale : number * scale
            }
            // 规范化百分比往返会有 Double 舍入；相同逻辑值保持原快照，避免空历史事务。
            if .number(number) == previous[field.rawValue] { continue }
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
        var tone = result.toneSettings
        if let value = payload[.blackPoint]?.number { tone.blackPoint = value }
        if let value = payload[.whitePoint]?.number { tone.whitePoint = value }
        if let value = payload[.sCurve]?.number, payload[.sCurve] != previous[Field.sCurve.rawValue] {
            tone.curveStrength = value * 100
        }
        if let value = payload[.curve]?.curve { tone.curve = value }
        result.toneSettings = tone
        var color = result.colorSettings
        if let value = payload[.vibrance]?.number { color.vibrance = value }
        for field in payload.fields {
            if let location = field.hslLocation, let axis = HSLAxis(rawValue: location.axis),
               let value = payload[field]?.number {
                color.hsl.setExact(axis, channel: location.channel, value: value)
            }
            if let zone = field.gradingZone, let wheel = payload[field]?.object,
               let hue = wheel["hue"]?.number, let saturation = wheel["saturation"]?.number {
                color.grading[zone] = ColorGradingWheel(hue: hue, saturation: saturation)
            }
        }
        result.colorSettings = color
        var rendition = result.renditionSettings
        for (field, key) in renditionKeys {
            if let value = payload[field]?.number { rendition[keyPath: key] = value }
        }
        result.renditionSettings = rendition
        var effects = result.effectsSettings
        for (field, key) in effectKeys {
            if let value = payload[field]?.number { effects[keyPath: key] = value }
        }
        result.effectsSettings = effects
        var detail = result.detailSettings
        for (field, key) in detailKeys {
            if let value = payload[field]?.number, payload[field] != previous[field.rawValue] {
                detail[keyPath: key] = field == .clarity || field == .dehaze ? value / 100 : value
            }
        }
        result.detailSettings = detail
        if let look = payload[.hdrLook]?.hdrLookSettings { result.lookSettings = look }
        if let portable = payload[.hdrCameraDevelopment]?.hdrCameraDevelopment {
            var camera = result.cameraDevelopmentSettings
            camera.whiteBalance = portable.whiteBalance; camera.temperature = portable.temperature; camera.tint = portable.tint
            camera.exposureReference = portable.exposureReference; camera.fbddLevel = portable.fbddLevel
            result.cameraDevelopmentSettings = camera
        }
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
        guard payload.fields.isDisjoint(with: Field.hdrTone) else {
            throw AdjustmentTransferError.incompatible("hdr.tone")
        }
        guard payload.fields.isDisjoint(with: Field.hdrColor) else {
            throw AdjustmentTransferError.incompatible("hdr.color")
        }
        guard payload.fields.isDisjoint(with: Field.hdrRendition) else {
            throw AdjustmentTransferError.incompatible("hdr.rendition")
        }
        guard payload.fields.isDisjoint(with: Field.hdrEffects) else {
            throw AdjustmentTransferError.incompatible("hdr.effects")
        }
        guard payload.fields.isDisjoint(with: Field.hdrDetail) else {
            throw AdjustmentTransferError.incompatible("hdr.detail")
        }
        guard !payload.fields.contains(.hdrLook) else { throw AdjustmentTransferError.incompatible("hdr.look") }
        guard !payload.fields.contains(.hdrCameraDevelopment) else { throw AdjustmentTransferError.incompatible("hdr.camera_development") }
        return try AdjustmentTransferPayload(source: .init(identifier: payload.source.identifier, isRaw: false,
            processingVersion: payload.source.processingVersion, recipe: nil), values: payload.values)
    }

    private static func cameraValue(_ camera: HDRCameraDevelopmentSettings) -> Value {
        .object(["version": .number(1), "white_balance_mode": .string(camera.whiteBalance.rawValue),
            "temperature": .number(camera.temperature), "tint": .number(camera.tint),
            "exposure_reference": .string(camera.exposureReference.rawValue), "fbdd_level": .number(Double(camera.fbddLevel))])
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
        let tone = settings.toneSettings
        result[Field.blackPoint.rawValue] = .number(tone.blackPoint)
        result[Field.whitePoint.rawValue] = .number(tone.whitePoint)
        result[Field.sCurve.rawValue] = .number(tone.curveStrength / 100)
        result[Field.curve.rawValue] = tone.curve.transferValue
        let color = settings.colorSettings
        result[Field.vibrance.rawValue] = .number(color.vibrance)
        for field in Field.hdrColor {
            if let location = field.hslLocation, let axis = HSLAxis(rawValue: location.axis) {
                result[field.rawValue] = .number(color.hsl.value(axis, channel: location.channel))
            }
            if let zone = field.gradingZone { result[field.rawValue] = color.grading[zone].transferValue }
        }
        for (field, key) in renditionKeys { result[field.rawValue] = .number(settings.renditionSettings[keyPath: key]) }
        for (field, key) in effectKeys { result[field.rawValue] = .number(settings.effectsSettings[keyPath: key]) }
        for (field, key) in detailKeys {
            let value = settings.detailSettings[keyPath: key]
            result[field.rawValue] = .number(field == .clarity || field == .dehaze ? value * 100 : value)
        }
        let look = settings.lookSettings
        if let sha256 = look.sha256, let name = look.name {
            result[Field.hdrLook.rawValue] = .object(["sha256": .string(sha256), "name": .string(name), "strength": .number(look.strength)])
        } else { result[Field.hdrLook.rawValue] = .null }
        return result
    }
}
