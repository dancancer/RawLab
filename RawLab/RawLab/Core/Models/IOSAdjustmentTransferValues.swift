import Foundation

extension IOSAdjustmentTransfer {
    static let scalarKeys: [Field: WritableKeyPath<RawSettings, Double>] = [
        .strength: \.lutStrength, .exposure: \.exposure, .contrast: \.contrast, .highlights: \.highlights,
        .shadows: \.shadows, .sCurve: \.toneCurve, .saturation: \.saturation, .sharpening: \.sharpening,
        .blackPoint: \.blackPoint, .whitePoint: \.whitePoint, .vibrance: \.vibrance
    ]
    static let effectKeys: [Field: WritableKeyPath<PhotoEffectsSettings, Double>] = [
        .vignetteAmount: \.vignetteAmount, .vignetteMidpoint: \.vignetteMidpoint, .vignetteRoundness: \.vignetteRoundness,
        .vignetteFeather: \.vignetteFeather, .vignetteHighlights: \.vignetteHighlights, .grainAmount: \.grainAmount,
        .grainSize: \.grainSize, .grainRoughness: \.grainRoughness
    ]
    static let geometryKeys: [Field: WritableKeyPath<GeometrySettings, Double>] = [
        .cropX: \.cropX, .cropY: \.cropY, .cropWidth: \.cropWidth, .cropHeight: \.cropHeight,
        .straighten: \.straightenDegrees, .perspectiveHorizontal: \.perspectiveHorizontal,
        .perspectiveVertical: \.perspectiveVertical
    ]
    static func presetID(_ preset: RawDenoisePreset) -> String {
        switch preset { case .detail: return "detail"; case .clean: return "clean"; case .custom: return "custom" }
    }
    static func effectiveNumbers(_ settings: RawSettings) -> [Field: Double] {
        let rendered = settings.renderedRecipe(cameraTemperature: 6500, cameraTint: 0)
        var result = scalarKeys.mapValues { Double(Float(rendered[keyPath: $0])) }
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field] = rendered.hsl.value(HSLAxis(rawValue: location.axis)!, channel: location.channel)
            }
        }
        return result
    }
    static func values(_ settings: RawSettings, context: IOSAdjustmentTransferContext) -> [String: Value] {
        var result = [String: Value]()
        for (field, key) in scalarKeys { result[field.rawValue] = .number(settings[keyPath: key]) }
        result[Field.strength.rawValue] = .number(Double(settings.clampedLUTStrength))
        let look: [String: Value]
        if let id = settings.masterRecipeID { look = ["kind": .string("recipe"), "id": .string(id)] }
        else if let id = settings.lutID {
            if id.hasPrefix("recipe-lut:") { look = ["kind": .string("recipe_lut"), "id": .string(String(id.dropFirst(11)))] }
            else if let filename = context.builtinLookIDs.first(where: { $0.value == id })?.key {
                look = ["kind": .string("builtin"), "id": .string(filename)]
            } else { look = ["kind": .string("managed"), "id": .string(id)] }
        } else { look = ["kind": .string("neutral"), "id": .null] }
        result[Field.look.rawValue] = .object(look)
        result[Field.exposureMode.rawValue] = .string(!context.isRaw ? "sensor" : settings.exposureMode == .scene ? "scene" : settings.exposureMode == .preview ? "preview" : "sensor")
        let camera = !context.isRaw || settings.whiteBalanceMode == .camera
        result[Field.whiteBalanceMode.rawValue] = .string(!context.isRaw ? "none" : camera ? "camera" : "temperature")
        result[Field.temperature.rawValue] = camera ? .null : .number(settings.temperature)
        result[Field.tint.rawValue] = settings.masterRecipeID != nil ? .number(settings.tint) : camera ? .null : .number(settings.tint)
        for field in Field.allCases {
            if let location = field.hslLocation {
                result[field.rawValue] = .number(settings.hsl.value(HSLAxis(rawValue: location.axis)!, channel: location.channel))
            }
        }
        for (field, key) in effectKeys { result[field.rawValue] = .number(settings.photoEffects[keyPath: key]) }
        result[Field.rawDenoise.rawValue] = .number(0)
        result[Field.postRGBDenoise.rawValue] = .number(context.isRaw ? settings.noiseReduction : 0)
        result[Field.chromaDenoise.rawValue] = .number(Double(settings.displayChromaDenoise))
        let denoise = settings.denoise
        result[Field.waveletDenoise.rawValue] = .object(["enabled": .boolean(denoise.enabled),
            "luma": .number(denoise.luma), "chroma": .number(denoise.chroma), "coarse": .number(denoise.coarse),
            "preset": .string(presetID(denoise.preset))])
        for (field, key) in geometryKeys { result[field.rawValue] = .number(settings.geometry[keyPath: key]) }
        result[Field.quarterTurns.rawValue] = .number(Double(settings.geometry.quarterTurns))
        result[Field.flipHorizontal.rawValue] = .boolean(settings.geometry.flipHorizontal)
        result[Field.flipVertical.rawValue] = .boolean(settings.geometry.flipVertical)
        let lens = context.isRaw ? settings.lensSettings : LensCorrectionSettings()
        result[Field.lensDistortion.rawValue] = .boolean(lens.distortion)
        result[Field.lensTCA.rawValue] = .boolean(lens.tca)
        result[Field.lensAutoCrop.rawValue] = .boolean(lens.autoCrop)
        result[Field.lensProfile.rawValue] = lens.mode == .automatic ? .null : .string(lens.profileID ?? "")
        return result
    }
    static func applyObjects(_ payload: AdjustmentTransferPayload, to settings: inout RawSettings,
                             context: IOSAdjustmentTransferContext) throws {
        if let raw = payload[.rawDenoise]?.number, raw != 0 { throw AdjustmentTransferError.incompatible(Field.rawDenoise.rawValue) }
        if let post = payload[.postRGBDenoise]?.number {
            guard context.isRaw || post == 0 else { throw AdjustmentTransferError.incompatible(Field.postRGBDenoise.rawValue) }
            settings.noiseReduction = post
        }
        if let chroma = payload[.chromaDenoise] { settings.displayChromaDenoise = Int(chroma.number ?? 0) }
        if let value = payload[.waveletDenoise] {
            if let wavelet = value.object {
                let denoise = RawDenoiseSettings(enabled: wavelet["enabled"]!.boolean!, luma: wavelet["luma"]!.number!,
                    chroma: wavelet["chroma"]!.number!, coarse: wavelet["coarse"]!.number!)
                guard presetID(denoise.preset) == wavelet["preset"]!.string! else {
                    throw AdjustmentTransferError.unrepresentable("detail.denoise.wavelet.preset")
                }
                settings.denoise = denoise
            } else { settings.denoise = RawDenoiseSettings() }
        }
        if payload.fields.contains(where: { $0.group == "geometry" && !Field.lensFields.contains($0) }) {
            var geometry = settings.geometry
            for (field, key) in geometryKeys { if let value = payload[field]?.number { geometry[keyPath: key] = value } }
            if let value = payload[.quarterTurns]?.number { geometry.quarterTurns = Int(value) }
            if let value = payload[.flipHorizontal]?.boolean { geometry.flipHorizontal = value }
            if let value = payload[.flipVertical]?.boolean { geometry.flipVertical = value }
            guard geometry.isValid else { throw AdjustmentTransferError.unrepresentable("geometry.crop") }
            settings.geometry = geometry
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
            if let value = payload[.lensProfile] { lens.mode = value == .null ? .automatic : .manual; lens.profileID = value.string }
            guard context.isRaw || !lens.isEnabled else { throw AdjustmentTransferError.incompatible("geometry.lens") }
            if lens.isEnabled {
                guard let validate = context.validateLensRequest else { throw AdjustmentTransferError.incompatible("target lens calibration unavailable") }
                try validate(lens)
            }
            let previous = settings.lensSettings
            if lens.distortion != previous.distortion || lens.tca != previous.tca || lens.autoCrop != previous.autoCrop
                || lens.mode != previous.mode || lens.mode == .manual && lens.profileID != previous.profileID {
                settings.lensCorrection = lens == LensCorrectionSettings() ? nil : lens
            }
        }
    }
}
