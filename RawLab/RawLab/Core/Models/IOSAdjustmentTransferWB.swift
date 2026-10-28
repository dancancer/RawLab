import Foundation

extension IOSAdjustmentTransfer {
    struct ResolvedWB: Equatable {
        let camera: Bool
        let temperature: Double
        let tint: Double
        static func == (left: Self, right: Self) -> Bool {
            left.camera == right.camera && Float(left.temperature) == Float(right.temperature) && Float(left.tint) == Float(right.tint)
        }
    }
    static func renderWB(_ settings: RawSettings, context: IOSAdjustmentTransferContext) -> ResolvedWB {
        let rendered = settings.renderedRecipe(cameraTemperature: context.cameraTemperature ?? 6500, cameraTint: context.cameraTint ?? 0)
        let camera = rendered.whiteBalanceMode == .camera
        return .init(camera: camera, temperature: camera ? 6500 : Double(Float(rendered.temperature)),
            tint: camera ? 0 : Double(Float(rendered.tint)))
    }
    private static func targetCamera(_ context: IOSAdjustmentTransferContext) throws -> ResolvedWB {
        guard let temperature = context.cameraTemperature, let tint = context.cameraTint,
              temperature.isFinite, tint.isFinite, RawSettings.temperatureRange.contains(temperature), RawSettings.tintRange.contains(tint) else {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        return .init(camera: false, temperature: temperature, tint: tint)
    }
    private static func requireTargetCalibration(_ target: RawSettings, context: IOSAdjustmentTransferContext) throws {
        if target.masterRecipeID != nil && (target.tint * target.recipeScale != 0 || target.whiteBalanceMode != .camera) {
            _ = try targetCamera(context)
        }
    }
    static func applyWhiteBalance(_ payload: AdjustmentTransferPayload, target: RawSettings, to result: inout RawSettings,
                                  context: IOSAdjustmentTransferContext, fullRecipe: Bool, contextChanged: Bool) throws {
        let selected = payload.fields.intersection(Field.whiteBalanceFields)
        if selected.isEmpty {
            if context.isRaw && contextChanged && renderWB(result, context: context) != renderWB(target, context: context) {
                try requireTargetCalibration(target, context: context)
                try applyResolvedWB(renderWB(target, context: context), to: &result, context: context)
            }
            return
        }
        guard context.isRaw || !payload.source.isRaw else { throw AdjustmentTransferError.incompatible("color.white_balance") }
        let previousValues = values(target, context: context)
        let previousRecipe = target.masterRecipeID.map { AdjustmentRecipeContext(id: $0, strength: target.recipeScale, settingsVersion: target.masterRecipeSettingsVersion) }
        if !contextChanged && context.isRaw == payload.source.isRaw && previousRecipe == payload.source.recipe
            && selected.allSatisfy({ payload[$0] == previousValues[$0.rawValue] }) { return }
        if selected == Field.whiteBalanceFields {
            let mode = payload[.whiteBalanceMode]!.string!
            let balance: [String: Value] = ["mode": .string(mode == "none" && payload.source.recipe != nil ? "camera" : mode),
                "temperature": payload[.temperature]!, "tint": .number(payload[.tint]?.number ?? 0),
                "tint_mode": .string(payload.source.recipe != nil || mode == "camera" ? "camera_offset" : "absolute")]
            let desired = try resolvedWB(balance, recipe: payload.source.recipe, sourceIsRaw: payload.source.isRaw, context: context)
            if fullRecipe {
                applyLogicalWB(balance, to: &result)
                if context.isRaw && renderWB(result, context: context) != desired {
                    try applyResolvedWB(desired, to: &result, context: context)
                    if balance["mode"]!.string == "camera" { result.whiteBalanceMode = .camera }
                }
            } else if context.isRaw { try applyResolvedWB(desired, to: &result, context: context) }
            return
        }
        guard context.isRaw else { return }
        let selectedMode = payload[.whiteBalanceMode]?.string
        let cameraMode = selectedMode.map { $0 != "temperature" } ?? (target.whiteBalanceMode == .camera)
        let temperature = payload[.temperature], tint = payload[.tint]
        if temperature != nil && (cameraMode ? temperature != .null : temperature?.number == nil) {
            throw AdjustmentTransferError.incompatible("select white balance mode with temperature")
        }
        if let tint, cameraMode ? tint.number != nil && payload.source.recipe == nil : tint == .null {
            throw AdjustmentTransferError.incompatible("select white balance mode with tint")
        }
        try requireTargetCalibration(target, context: context)
        let previous = renderWB(target, context: context), desired: ResolvedWB
        if cameraMode {
            let offset: Double
            if let tint { offset = (tint.number ?? 0) * (payload.source.recipe?.strength ?? 1) }
            else if target.masterRecipeID != nil { offset = target.tint * target.recipeScale }
            else if target.whiteBalanceMode == .camera { offset = 0 }
            else { offset = previous.tint - (try targetCamera(context)).tint }
            if temperature == nil && target.whiteBalanceMode != .camera {
                guard Float(previous.temperature) == Float(try targetCamera(context).temperature) else {
                    throw AdjustmentTransferError.unrepresentable("unselected white balance temperature")
                }
            }
            if offset == 0 { desired = .init(camera: true, temperature: 6500, tint: 0) }
            else {
                let camera = try targetCamera(context), value = camera.tint + offset
                guard RawSettings.tintRange.contains(value) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
                desired = .init(camera: false, temperature: camera.temperature, tint: value)
            }
            if result.masterRecipeID == nil && offset != 0 && selectedMode == nil && !contextChanged {
                throw AdjustmentTransferError.incompatible("select white balance mode with relative tint")
            }
            if result.masterRecipeID == nil && offset != 0 && selectedMode != nil && tint == nil {
                throw AdjustmentTransferError.unrepresentable("unselected white balance tint")
            }
        } else {
            let fixedTemperature = try temperature?.number ?? (previous.camera ? targetCamera(context).temperature : previous.temperature)
            let fixedTint: Double
            if let value = tint?.number { fixedTint = try payload.source.recipe.map { (try targetCamera(context)).tint + value * $0.strength } ?? value }
            else { fixedTint = try previous.camera ? targetCamera(context).tint : previous.tint }
            guard RawSettings.tintRange.contains(fixedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
            desired = .init(camera: false, temperature: fixedTemperature, tint: fixedTint)
        }
        try applyResolvedWB(desired, to: &result, context: context)
        if cameraMode && result.masterRecipeID != nil { result.whiteBalanceMode = .camera }
        if !contextChanged {
            if temperature == nil { result.temperature = target.temperature }
            if tint == nil { result.tint = target.tint }
            if selectedMode == nil { result.whiteBalanceMode = target.whiteBalanceMode }
        }
        guard renderWB(result, context: context) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }
    static func resolvedWB(_ value: [String: Value], recipe: AdjustmentRecipeContext?, sourceIsRaw: Bool,
                           context: IOSAdjustmentTransferContext) throws -> ResolvedWB {
        guard context.isRaw && (sourceIsRaw || recipe != nil) else { return .init(camera: true, temperature: 6500, tint: 0) }
        let camera = value["mode"]!.string == "camera", offset = value["tint_mode"]!.string == "camera_offset"
        let tint = value["tint"]!.number! * (offset ? recipe?.strength ?? 1 : 1)
        if camera && tint == 0 { return .init(camera: true, temperature: 6500, tint: 0) }
        let calibration = try camera || offset ? targetCamera(context) : nil
        let resolvedTint = offset ? calibration!.tint + tint : tint
        guard RawSettings.tintRange.contains(resolvedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
        return .init(camera: false, temperature: camera ? calibration!.temperature : value["temperature"]!.number!, tint: resolvedTint)
    }
    static func applyResolvedWB(_ desired: ResolvedWB, to settings: inout RawSettings, context: IOSAdjustmentTransferContext) throws {
        if desired.camera { settings.whiteBalanceMode = .camera; settings.temperature = 6500; settings.tint = 0; return }
        settings.whiteBalanceMode = .custom; settings.temperature = desired.temperature
        if settings.masterRecipeID != nil {
            let delta = desired.tint - (try targetCamera(context)).tint, scale = settings.recipeScale
            guard scale != 0 || delta == 0 else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
            settings.tint = scale == 0 ? 0 : delta / scale
        } else { settings.tint = desired.tint }
        guard renderWB(settings, context: context) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }
    private static func applyLogicalWB(_ value: [String: Value], to settings: inout RawSettings) {
        settings.whiteBalanceMode = value["mode"]!.string == "temperature" ? .custom : .camera
        settings.temperature = value["temperature"]!.number ?? 6500
        settings.tint = value["tint"]!.number!
    }
}
