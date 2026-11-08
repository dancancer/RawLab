import Foundation

@main enum HDRModelTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        let legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(legacy.hdr == nil && !legacy.isHDREditing && legacy.processing == .legacy, "legacy record changed mode or processing")
        var sdr = Adjustments(); sdr.exposure = 1; sdr.contrast = -25; sdr.highlights = 50
        var recipe = sdr; recipe.setTransferRecipe(MasterRecipe.allRecipes[0].id); recipe.strength = 0.5
        recipe.contrast = 40; recipe.highlights = -60; recipe.shadows = 80; recipe.saturation = -20
        let recipeHDR = try recipe.withHDRMode(true, sourceIsHDR: true)
        check(recipeHDR.hdr?.exposure == 0.5 && abs(recipeHDR.hdr!.contrast - 20) < 0.00001 &&
              recipeHDR.hdr?.highlights == -30 && recipeHDR.hdr?.shadows == 40 &&
              abs(recipeHDR.hdr!.saturation + 10) < 0.00001, "Gain-map HDR did not start from effective recipe values")
        var extreme = sdr; extreme.exposure = 8; extreme.contrast = 200; extreme.highlights = -200; extreme.shadows = 200; extreme.saturation = -200
        let bounded = try extreme.withHDRMode(true, sourceIsHDR: true)
        check(bounded.hdr?.exposure == 4 && bounded.hdr?.contrast == 100 && bounded.hdr?.highlights == -100 &&
              bounded.hdr?.shadows == 100 && bounded.hdr?.saturation == -100,
              "Gain-map HDR did not clamp legacy values to HDR ranges")
        var recipeRestored = try recipeHDR.withHDRMode(false, sourceIsHDR: true)
        recipeRestored.hdr = nil
        check(recipeRestored == recipe,
              "HDR initialization changed the dormant SDR recipe")
        var active = try sdr.withHDRMode(true, sourceIsHDR: true)
        check(active.hdr?.exposure == 1 && active.hdr?.contrast == -25 && active.hdr?.highlights == 50, "conversion lost logical values")
        active.set(.exposure, to: 2); active.set(.temperature, to: 10000)
        active.rotateGeometry(clockwise: true)
        check(AdjustmentParameter.exposure.value(from: active) == 2 && active.hdr?.temperature == 10000 && active.hdr?.geometry.quarterTurns == 1,
            "HDR controls did not use the active snapshot")
        check(active.exposure == 1 && active.temperature == 6500 && active.geometry == nil, "HDR control mutated dormant SDR data")
        let data = try JSONEncoder().encode(active)
        let restored = try JSONDecoder().decode(Adjustments.self, from: data)
        check(restored == active, "HDR record did not round-trip")
        let disabled = try restored.withHDRMode(false, sourceIsHDR: true)
        check(!disabled.isHDREditing && disabled.exposure == 1 && disabled.hdr?.exposure == 2, "SDR restore lost either snapshot")
        let reenabled = try disabled.withHDRMode(true, sourceIsHDR: true)
        check(reenabled.hdr?.exposure == 2, "existing HDR snapshot was rebuilt")
        var reset = reenabled; reset.resetAll()
        check(reset.isHDREditing && reset.hdr?.isIdentity == true && reset.exposure == 1, "reset changed mode or dormant SDR edit")
        var cameraSDR = sdr
        cameraSDR.sharpening = 25
        cameraSDR.blackPoint = -8; cameraSDR.whitePoint = 9; cameraSDR.toneCurve = 12
        cameraSDR.curveSettings = .identity
        var cameraHDR = try cameraSDR.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        check(cameraHDR.hdr == HDRSettings() && cameraHDR.sharpening == 25 && cameraHDR.exposure == 1,
              "camera RAW HDR must start with an independent snapshot")
        cameraHDR.set(.exposure, to: 3)
        check(cameraHDR.hdr?.processingVersion == 1, "ordinary HDR edit upgraded the tone version")
        cameraHDR.set(.blackPoint, to: -25); cameraHDR.set(.whitePoint, to: 50); cameraHDR.set(.toneCurve, to: 30)
        check(AdjustmentParameter.blackPoint.value(from: cameraHDR) == -25 &&
              AdjustmentParameter.whitePoint.value(from: cameraHDR) == 50 &&
              AdjustmentParameter.toneCurve.value(from: cameraHDR) == 30 &&
              cameraHDR.hdr?.processingVersion == 2, "HDR tone controls did not update the active record")
        check(cameraHDR.blackPoint == -8 && cameraHDR.whitePoint == 9 && cameraHDR.toneCurve == 12 &&
              cameraHDR.curveSettings == .identity, "HDR tone controls changed the dormant SDR record")
        cameraHDR.editingCurveSettings = .identity.inserting(x: 0.5, y: 0.6)
        check(cameraHDR.hdr?.toneSettings.curve == cameraHDR.editingCurveSettings && cameraHDR.curveSettings == .identity,
              "HDR custom curve did not stay separate from the SDR curve")
        let savedCamera = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(cameraHDR))
        check(savedCamera == cameraHDR, "HDR tone settings did not survive serialization")
        let cameraOff = try savedCamera.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let cameraOn = try cameraOff.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        check(!cameraOff.isHDREditing && cameraOff.exposure == 1 && cameraOn.hdr?.exposure == 3,
              "camera RAW mode switch or persisted edit lost either snapshot")
        var ai = cameraOn
        ai.activeAIDenoise = true
        check(ai.hdrCameraAIEnabled && !ai.aiDenoiseEnabled && !ai.neutralSettings.activeAIDenoise,
              "HDR Bayer AI changed the SDR flag or neutral reference")
        let restoredAI = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(ai))
        check(restoredAI == ai, "HDR Bayer AI selection did not survive serialization")
        var aiSDR = try restoredAI.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        check(aiSDR.hdrCameraAIEnabled && !aiSDR.activeAIDenoise, "SDR mode used the saved HDR Bayer AI selection")
        aiSDR.resetAll()
        check(aiSDR.hdrCameraAIEnabled && !aiSDR.activeAIDenoise, "SDR reset cleared the dormant HDR Bayer AI selection")
        ai.resetAll()
        check(!ai.activeAIDenoise && ai.isHDREditing, "HDR reset kept the active AI selection")
        var sharpened = sdr; sharpened.sharpening = 10
        let hdrFromSharpened = try sharpened.withHDRMode(true, sourceIsHDR: true)
        let restoredSharpened = try hdrFromSharpened.withHDRMode(false, sourceIsHDR: true)
        check(hdrFromSharpened.isHDREditing && hdrFromSharpened.hdr?.detailSettings.sharpening == 0 &&
              restoredSharpened.sharpening == 10, "HDR switch did not preserve the SDR sharpening")
        let context=EditorAdjustmentContext(isRaw:false,defaultExposureMode:.sensor,neutralFilmID:"")
        let editedTone = PhotoEditState(settings: cameraHDR, filmID: "")
        if case .candidate(let candidate) = EditorAdjustmentRules.prepareReset(scope: .group(.light), snapshot: editedTone, context: context) {
            check(candidate.settings.hdr?.toneSettings.isDefault == true && candidate.settings.hdr?.processingVersion == 2 &&
                  candidate.settings.blackPoint == -8 && candidate.settings.curveSettings == .identity,
                  "HDR group reset lost its version or changed dormant tone")
        } else { fatalError("HDR tone group reset was not prepared") }
        var hdrColor = cameraHDR
        hdrColor.set(.vibrance, to: 35)
        hdrColor.editingHSLSettings.set(.hue, channel: 2, value: 18)
        hdrColor.editingGradingSettings.midtones = .init(hue: 180, saturation: 21)
        let colorSnapshot = PhotoEditState(settings: hdrColor, filmID: "")
        check(hdrColor.hdr?.processingVersion == 3 && hdrColor.vibrance == 0 &&
              hdrColor.hslSettings.isIdentity && hdrColor.gradingSettings.isDefault,
              "HDR color controls changed dormant SDR state")
        if case .candidate(let candidate) = EditorAdjustmentRules.prepareReset(scope: .group(.color), snapshot: colorSnapshot, context: context) {
            check(candidate.settings.hdr?.colorSettings.isDefault == true && candidate.settings.hdr?.processingVersion == 3 &&
                  candidate.settings.hdr?.toneSettings == cameraHDR.hdr?.toneSettings, "HDR color reset changed tone or processing version")
        } else { fatalError("HDR color group reset was not prepared") }
        var photograph=PhotoEditState(settings:active,filmID:"dormant-look")
        check(EditorAdjustmentRules.isModified(scope:.tool(.whiteBalance),snapshot:photograph,context:context),"HDR relative WB is not marked modified")
        if case .candidate(let candidate)=EditorAdjustmentRules.prepareReset(scope:.tool(.exposure),snapshot:photograph,context:context) {
            check(candidate.settings.hdr?.exposure==0 && candidate.settings.exposure==active.exposure && candidate.filmID==photograph.filmID,"tool reset changed inactive fields")
        } else { fatalError("HDR exposure reset was not prepared") }
        photograph.settings.hdr?.saturation=30
        if case .candidate(let candidate)=EditorAdjustmentRules.prepareReset(scope:.all,snapshot:photograph,context:context) {
            check(candidate.settings.hdr?.isIdentity==true && candidate.settings.isHDREditing && candidate.filmID==photograph.filmID &&
                  candidate.settings.exposure==active.exposure,"all reset lost mode or dormant SDR snapshot")
        } else { fatalError("HDR all reset was not prepared") }
        var effect=Adjustments(); effect.photoEffects=PhotoEffectsSettings(); effect.photoEffects?.vignetteMidpoint=60
        let hdrFromEffect = try effect.withHDRMode(true, sourceIsHDR: true)
        let restoredEffect = try hdrFromEffect.withHDRMode(false, sourceIsHDR: true)
        check(hdrFromEffect.isHDREditing && restoredEffect.photoEffects?.vignetteMidpoint == 60,
              "HDR switch did not preserve the SDR effect")
        print("PASS Mac HDR legacy, record, conversion, control routing and reset")
    }
}
