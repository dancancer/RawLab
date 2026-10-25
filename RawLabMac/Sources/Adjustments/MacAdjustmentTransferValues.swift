import Foundation

extension MacAdjustmentTransfer {
    static let scalarKeys: [Field: WritableKeyPath<Adjustments, Double>] = [
        .strength: \.strength, .exposure: \.exposure, .contrast: \.contrast,
        .highlights: \.highlights, .shadows: \.shadows, .sCurve: \.toneCurve,
        .saturation: \.saturation, .sharpening: \.sharpening
    ]
    static let effectKeys: [Field: WritableKeyPath<PhotoEffectsSettings, Double>] = [
        .vignetteAmount: \.vignetteAmount, .vignetteMidpoint: \.vignetteMidpoint,
        .vignetteRoundness: \.vignetteRoundness, .vignetteFeather: \.vignetteFeather,
        .vignetteHighlights: \.vignetteHighlights, .grainAmount: \.grainAmount,
        .grainSize: \.grainSize, .grainRoughness: \.grainRoughness
    ]
    static let geometryKeys: [Field: WritableKeyPath<GeometrySettings, Double>] = [
        .cropX: \.cropX, .cropY: \.cropY, .cropWidth: \.cropWidth, .cropHeight: \.cropHeight,
        .straighten: \.straightenDegrees, .perspectiveHorizontal: \.perspectiveHorizontal,
        .perspectiveVertical: \.perspectiveVertical
    ]

    static func logical(_ value: Double, field: Field) -> Double {
        switch field {
        case .contrast, .saturation: return 1 + value / 100
        case .highlights: return -value / 100
        case .shadows, .sCurve, .sharpening: return value / 100
        default: return value
        }
    }

    static func assignLogical(_ value: Double, field: Field, to settings: inout Adjustments) {
        let native: Double
        switch field {
        case .contrast, .saturation: native = (value - 1) * 100
        case .highlights: native = -value * 100
        case .shadows, .sCurve, .sharpening: native = value * 100
        default: native = value
        }
        settings[keyPath: scalarKeys[field]!] = native
    }

    static func effectiveNumbers(_ settings: Adjustments) -> [Field: Double] {
        var request = sony2fuji_request(); settings.apply(to: &request)
        var result: [Field: Double] = [
            .strength: settings.strength, .exposure: Double(request.exposure_ev), .contrast: Double(request.contrast),
            .highlights: Double(request.highlights), .shadows: Double(request.shadows), .sCurve: Double(request.tone_curve),
            .saturation: Double(request.saturation), .sharpening: Double(request.sharpening)
        ]
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field] = settings.renderHSLSettings.value(HSLAxis(rawValue: location.axis)!, channel: location.channel)
            }
        }
        return result
    }

    static func values(_ snapshot: PhotoEditState, isRaw: Bool) -> [String: Value] {
        let settings = snapshot.settings
        var result = [String: Value]()
        for (field, key) in scalarKeys { result[field.rawValue] = .number(logical(settings[keyPath: key], field: field)) }
        let look: [String: Value]
        if let recipe = settings.masterRecipeID { look = ["kind": .string("recipe"), "id": .string(recipe)] }
        else if snapshot.filmID.isEmpty { look = ["kind": .string("neutral"), "id": .null] }
        else if snapshot.filmID.hasPrefix("builtin:") { look = ["kind": .string("builtin"), "id": .string(String(snapshot.filmID.dropFirst(8)))] }
        else if snapshot.filmID.hasPrefix("recipe-lut:") { look = ["kind": .string("recipe_lut"), "id": .string(String(snapshot.filmID.dropFirst(11)))] }
        else { look = ["kind": .string("managed"), "id": .string(snapshot.filmID)] }
        result[Field.look.rawValue] = .object(look)
        result[Field.exposureMode.rawValue] = .string(!isRaw ? "sensor" : settings.exposureMode == .scene ? "scene" : settings.exposureMode == .preview ? "preview" : "sensor")
        let camera = !isRaw || settings.usesAsShotWhiteBalance
        let recipe = settings.masterRecipe != nil
        result[Field.whiteBalanceMode.rawValue] = .string(!isRaw ? "none" : camera ? "camera" : "temperature")
        result[Field.temperature.rawValue] = !isRaw || camera ? .null : .number(settings.temperature)
        result[Field.tint.rawValue] = recipe ? .number(settings.tint) : !isRaw || camera ? .null : .number(settings.tint)
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field.rawValue] = .number(settings.hslSettings.value(HSLAxis(rawValue: location.axis)!, channel: location.channel))
            }
        }
        for (field, key) in effectKeys { result[field.rawValue] = .number(settings.effectSettings[keyPath: key]) }
        let wavelet: Value = settings.waveletNoiseReduction.map { .object([
            "enabled": .boolean($0.enabled), "luma": .number($0.luma), "chroma": .number($0.chroma),
            "coarse": .number($0.coarse), "preset": .string($0.preset.rawValue)
        ]) } ?? .null
        result[Field.rawDenoise.rawValue] = .number(isRaw ? settings.rawNoiseReduction : 0)
        result[Field.postRGBDenoise.rawValue] = .number(0)
        result[Field.chromaDenoise.rawValue] = settings.chromaNoiseReduction.map(Value.number) ?? .null
        result[Field.waveletDenoise.rawValue] = wavelet
        let geometry = settings.geometrySettings
        result[Field.quarterTurns.rawValue] = .number(Double(geometry.quarterTurns))
        result[Field.flipHorizontal.rawValue] = .boolean(geometry.flipHorizontal)
        result[Field.flipVertical.rawValue] = .boolean(geometry.flipVertical)
        for (field, key) in geometryKeys { result[field.rawValue] = .number(geometry[keyPath: key]) }
        let lens = isRaw ? settings.lensSettings : LensCorrectionSettings()
        result[Field.lensDistortion.rawValue] = .boolean(lens.distortion)
        result[Field.lensTCA.rawValue] = .boolean(lens.tca)
        result[Field.lensAutoCrop.rawValue] = .boolean(lens.autoCrop)
        result[Field.lensProfile.rawValue] = lens.mode == .automatic ? .null : .string(lens.coreProfileID)
        return result
    }

    static func applyObjects(_ payload: AdjustmentTransferPayload, to settings: inout Adjustments,
                             context: MacAdjustmentTransferContext) throws {
        if let value = payload[.postRGBDenoise]?.number, value != 0 {
            throw AdjustmentTransferError.incompatible(Field.postRGBDenoise.rawValue)
        }
        if let raw = payload[.rawDenoise]?.number {
            guard raw == 0 || (context.isRaw && settings.supportsRawNoiseReduction) else {
                throw AdjustmentTransferError.incompatible(Field.rawDenoise.rawValue)
            }
            settings.rawNoiseReduction = raw
        }
        if let value = payload[.chromaDenoise] { settings.chromaNoiseReduction = value.number }
        if let value = payload[.waveletDenoise] {
            if let wavelet = value.object {
                settings.waveletNoiseReduction = WaveletDenoiseSettings(enabled: wavelet["enabled"]!.boolean!,
                    luma: wavelet["luma"]!.number!, chroma: wavelet["chroma"]!.number!, coarse: wavelet["coarse"]!.number!,
                    preset: DenoisePreset(rawValue: wavelet["preset"]!.string!)!)
            } else { settings.waveletNoiseReduction = nil }
        }
        if payload.fields.contains(where: { $0.group == "geometry" && !Field.lensFields.contains($0) }) {
            var geometry = settings.geometrySettings
            if let turns = payload[.quarterTurns]?.number { geometry.quarterTurns = Int(turns) }
            if let flip = payload[.flipHorizontal]?.boolean { geometry.flipHorizontal = flip }
            if let flip = payload[.flipVertical]?.boolean { geometry.flipVertical = flip }
            for (field, key) in geometryKeys { if let value = payload[field]?.number { geometry[keyPath: key] = value } }
            guard geometry.isValid else { throw AdjustmentTransferError.unrepresentable("geometry.crop") }
            if geometry != settings.geometrySettings { settings.geometry = geometry.isIdentity ? nil : geometry }
        }
        if !payload.fields.isDisjoint(with: Field.lensFields) {
            if !context.isRaw {
                let neutral: [Field: Value] = [.lensDistortion: .boolean(false), .lensTCA: .boolean(false),
                    .lensAutoCrop: .boolean(true), .lensProfile: .null]
                guard neutral.allSatisfy({ payload[$0.key] == nil || payload[$0.key] == $0.value }) else {
                    throw AdjustmentTransferError.incompatible("geometry.lens")
                }
            }
            var lens = settings.lensSettings
            if let value = payload[.lensDistortion]?.boolean { lens.distortion = value }
            if let value = payload[.lensTCA]?.boolean { lens.tca = value }
            if let value = payload[.lensAutoCrop]?.boolean { lens.autoCrop = value }
            if let value = payload[.lensProfile] {
                lens.mode = value == .null ? .automatic : .manual
                lens.profileID = value.string == "__rawlab_manual_selection_required__" ? nil : value.string
            }
            if lens.isEnabled && lens.mode == .manual && lens.profileID == nil {
                throw AdjustmentTransferError.unrepresentable(Field.lensProfile.rawValue)
            }
            guard context.isRaw || !lens.isEnabled else { throw AdjustmentTransferError.incompatible("geometry.lens") }
            if lens.isEnabled {
                guard let validate = context.validateLensRequest else {
                    throw AdjustmentTransferError.incompatible("target lens calibration unavailable")
                }
                try validate(lens)
            }
            let existing = settings.lensSettings
            if lens.distortion != existing.distortion || lens.tca != existing.tca || lens.autoCrop != existing.autoCrop
                || lens.mode != existing.mode || (lens.mode == .manual && lens.profileID != existing.profileID) {
                settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
            }
        }
    }
}
