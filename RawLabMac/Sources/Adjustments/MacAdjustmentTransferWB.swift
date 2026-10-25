import Foundation

extension MacAdjustmentTransfer {
    static func applyWhiteBalance(_ payload: AdjustmentTransferPayload, target: Adjustments,
                                  to result: inout Adjustments, context: MacAdjustmentTransferContext,
                                  fullRecipe: Bool, contextChanged: Bool) throws {
        let selected = payload.fields.intersection(Field.whiteBalanceFields)
        if selected.isEmpty {
            if context.isRaw && contextChanged && renderWB(result) != renderWB(target) {
                // 不能把 renderer 缺少校准时的 fallback 当成目标真实校准。
                try requireTargetCalibrationForMaterialization(target)
                try applyResolvedWB(renderWB(target), to: &result)
            }
            return
        }
        guard context.isRaw || !payload.source.isRaw else {
            throw AdjustmentTransferError.incompatible("color.white_balance")
        }
        let targetValues = values(PhotoEditState(settings: target, filmID: "", masterRecipeID: target.masterRecipeID), isRaw: context.isRaw)
        let targetRecipe = target.masterRecipeID.map {
            AdjustmentRecipeContext(id: $0, strength: target.strength, settingsVersion: target.recipeSettingsVersion)
        }
        if !contextChanged && payload.source.isRaw == context.isRaw && payload.source.recipe == targetRecipe
            && selected.allSatisfy({ payload[$0] == targetValues[$0.rawValue] }) { return }
        if selected == Field.whiteBalanceFields {
            let mode = payload[.whiteBalanceMode]!.string!
            let balance: [String: Value] = [
                "mode": .string(mode == "none" && payload.source.recipe != nil ? "camera" : mode),
                "temperature": payload[.temperature]!, "tint": .number(payload[.tint]?.number ?? 0),
                "tint_mode": .string(payload.source.recipe != nil || mode == "camera" ? "camera_offset" : "absolute")
            ]
            let desired = try resolvedWB(balance, recipe: payload.source.recipe, target: target,
                sourceIsRaw: payload.source.isRaw, targetIsRaw: context.isRaw)
            if fullRecipe { applyLogicalWB(balance, to: &result) }
            else if context.isRaw { try applyResolvedWB(desired, to: &result) }
            return
        }
        // 普通图片的 WB 请求不生效；完整配方才保留其可跨 RAW 复用的相对色调上下文。
        guard context.isRaw else { return }
        try applyPartialWhiteBalance(payload, target: target, to: &result, contextChanged: contextChanged)
    }

    private static func requireTargetCalibrationForMaterialization(_ target: Adjustments) throws {
        if target.masterRecipe != nil && target.asShotWhiteBalance == nil
            && (target.tint * target.strength != 0 || !target.usesAsShotWhiteBalance) {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
    }

    private static func targetCamera(_ target: Adjustments) throws -> WhiteBalance {
        guard let camera = target.asShotWhiteBalance else {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        return camera
    }

    private static func applyPartialWhiteBalance(_ payload: AdjustmentTransferPayload, target: Adjustments,
                                                to result: inout Adjustments, contextChanged: Bool) throws {
        let selectedMode = payload[.whiteBalanceMode]?.string
        let cameraMode = selectedMode.map { $0 != "temperature" } ?? target.usesAsShotWhiteBalance
        let temperature = payload[.temperature], tint = payload[.tint]
        if temperature != nil && (cameraMode ? temperature != .null : temperature?.number == nil) {
            throw AdjustmentTransferError.incompatible("select white balance mode with temperature")
        }
        if let tint, cameraMode ? tint.number != nil && payload.source.recipe == nil : tint == .null {
            throw AdjustmentTransferError.incompatible("select white balance mode with tint")
        }
        try requireTargetCalibrationForMaterialization(target)
        let previous = renderWB(target)
        let desired: ResolvedWB
        if cameraMode {
            let offset: Double
            if let tint { offset = (tint.number ?? 0) * (payload.source.recipe?.strength ?? 1) }
            else if target.masterRecipe != nil { offset = target.tint * target.strength }
            else if target.usesAsShotWhiteBalance { offset = 0 }
            else { offset = previous.tint - (try targetCamera(target)).tint }
            if temperature == nil && !target.usesAsShotWhiteBalance {
                guard Float(previous.temperature) == Float(try targetCamera(target).temperature) else {
                    throw AdjustmentTransferError.unrepresentable("unselected white balance temperature")
                }
            }
            if offset == 0 { desired = ResolvedWB(camera: true, temperature: 6500, tint: 0) }
            else {
                let camera = try targetCamera(target)
                let value = camera.tint + offset
                guard (-150...150).contains(value) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
                desired = ResolvedWB(camera: false, temperature: camera.temperature, tint: value)
            }
            if result.masterRecipe == nil && offset != 0 && selectedMode == nil && !contextChanged {
                throw AdjustmentTransferError.incompatible("select white balance mode with relative tint")
            }
            if result.masterRecipe == nil && offset != 0 && selectedMode != nil && tint == nil {
                throw AdjustmentTransferError.unrepresentable("unselected white balance tint")
            }
        } else {
            let fixedTemperature = try temperature?.number ?? (previous.camera ? targetCamera(target).temperature : previous.temperature)
            let fixedTint: Double
            if let value = tint?.number {
                fixedTint = try payload.source.recipe.map { (try targetCamera(target)).tint + value * $0.strength } ?? value
            } else { fixedTint = try previous.camera ? targetCamera(target).tint : previous.tint }
            guard (-150...150).contains(fixedTint) else { throw AdjustmentTransferError.unrepresentable(Field.tint.rawValue) }
            desired = ResolvedWB(camera: false, temperature: fixedTemperature, tint: fixedTint)
        }
        try applyResolvedWB(desired, to: &result)
        // recipe 的 camera 模式允许相对 tint，仍须保留逐目标相机温度。
        if cameraMode && result.masterRecipe != nil {
            result.whiteBalanceMode = .asShot
        }
        if !contextChanged {
            if temperature == nil { result.temperature = target.temperature }
            if tint == nil { result.tint = target.tint }
            if selectedMode == nil { result.whiteBalanceMode = target.whiteBalanceMode }
        }
        guard renderWB(result) == desired else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
    }

    struct ResolvedWB: Equatable {
        let camera: Bool
        let temperature: Double
        let tint: Double
    }

    static func renderWB(_ settings: Adjustments) -> ResolvedWB {
        var request = sony2fuji_request(); settings.apply(to: &request)
        return ResolvedWB(camera: request.wb_mode == SONY2FUJI_WB_CAMERA,
            temperature: Double(request.temperature), tint: Double(request.tint))
    }

    static func resolvedWB(_ value: [String: Value], recipe: AdjustmentRecipeContext?, target: Adjustments,
                           sourceIsRaw: Bool, targetIsRaw: Bool) throws -> ResolvedWB {
        guard targetIsRaw && (sourceIsRaw || recipe != nil) else { return ResolvedWB(camera: true, temperature: 6500, tint: 0) }
        let camera = value["mode"]!.string == "camera"
        let offset = value["tint_mode"]!.string == "camera_offset"
        let tint = value["tint"]!.number! * (offset ? recipe?.strength ?? 1 : 1)
        if camera && tint == 0 { return ResolvedWB(camera: true, temperature: 6500, tint: 0) }
        if (camera || offset) && target.asShotWhiteBalance == nil {
            throw AdjustmentTransferError.incompatible("target camera white balance unavailable")
        }
        let resolvedTint = offset ? target.asShotWhiteBalance!.tint + tint : tint
        guard resolvedTint.isFinite, (-150...150).contains(resolvedTint) else {
            throw AdjustmentTransferError.unrepresentable("color.white_balance")
        }
        return ResolvedWB(camera: false, temperature: camera ? target.asShotWhiteBalance!.temperature : value["temperature"]!.number!,
            tint: resolvedTint)
    }

    static func applyResolvedWB(_ desired: ResolvedWB, to settings: inout Adjustments) throws {
        if desired.camera { settings.resetWhiteBalance(); return }
        settings.whiteBalanceMode = .custom
        settings.temperature = desired.temperature
        if settings.masterRecipe != nil {
            guard let camera = settings.asShotWhiteBalance else { throw AdjustmentTransferError.incompatible("target camera white balance unavailable") }
            let delta = desired.tint - camera.tint
            guard settings.strength != 0 || delta == 0 else { throw AdjustmentTransferError.unrepresentable("color.white_balance") }
            settings.tint = settings.strength == 0 ? 0 : delta / settings.strength
        } else { settings.tint = desired.tint }
        let actual = renderWB(settings)
        guard !actual.camera, Float(actual.temperature) == Float(desired.temperature), Float(actual.tint) == Float(desired.tint) else {
            throw AdjustmentTransferError.unrepresentable("color.white_balance")
        }
    }

    static func applyLogicalWB(_ value: [String: Value], to settings: inout Adjustments) {
        if value["mode"]!.string == "temperature" {
            settings.whiteBalanceMode = .custom; settings.temperature = value["temperature"]!.number!
        } else { settings.resetWhiteBalance() }
        settings.tint = value["tint"]!.number!
    }
}
