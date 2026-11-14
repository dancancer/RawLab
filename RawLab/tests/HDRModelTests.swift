import Foundation

@main enum HDRModelTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func resetAll(_ settings: RawSettings,
                         context: EditorAdjustmentContext = .init(isRaw: false, defaultExposureMode: .sensor)) -> RawSettings {
        switch EditorAdjustmentRules.prepareReset(.all, snapshot: PhotoEditState(settings: settings), context: context) {
        case .candidate(let state, _): return state.settings
        case .unchanged: return settings
        case .blocked(let reason): fatalError("unexpected reset block: \(reason)")
        }
    }
    static func main() throws {
        let legacy = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        check(legacy.hdr == nil && !legacy.isHDREditing && legacy.processing == .legacy, "legacy record changed mode or processing")
        var sdr = RawSettings.default; sdr.exposure = 1; sdr.contrast = 0.75; sdr.highlights = -0.5
        var recipe = sdr; recipe.masterRecipeID = "test-recipe"; recipe.lutStrength = 0.5
        recipe.contrast = 1.4; recipe.highlights = 0.6; recipe.shadows = 0.8; recipe.saturation = 0.8
        let recipeHDR = try recipe.withHDRMode(true, sourceIsHDR: true)
        check(recipeHDR.hdr?.exposure == 0.5 && abs(recipeHDR.hdr!.contrast - 20) < 0.00001 &&
              recipeHDR.hdr?.highlights == -30 && recipeHDR.hdr?.shadows == 40 &&
              abs(recipeHDR.hdr!.saturation + 10) < 0.00001, "Gain-map HDR did not start from effective recipe values")
        var extreme = sdr; extreme.exposure = 8; extreme.contrast = 3; extreme.highlights = 2; extreme.shadows = 2; extreme.saturation = -1
        let bounded = try extreme.withHDRMode(true, sourceIsHDR: true)
        check(bounded.hdr?.exposure == 4 && bounded.hdr?.contrast == 100 && bounded.hdr?.highlights == -100 &&
              bounded.hdr?.shadows == 100 && bounded.hdr?.saturation == -100,
              "Gain-map HDR did not clamp legacy values to HDR ranges")
        var recipeRestored = try recipeHDR.withHDRMode(false, sourceIsHDR: true)
        recipeRestored.hdr = nil
        check(recipeRestored == recipe,
              "HDR initialization changed the dormant SDR recipe")
        var active = try sdr.withHDRMode(true, sourceIsHDR: true)
        check(active.hdr?.exposure == 1 && active.hdr?.contrast == -25 && active.hdr?.highlights == 50, "conversion lost UI scale/direction")
        AdjustmentKind.exposure.setValue(2, in: &active)
        AdjustmentKind.temperature.setValue(10000, in: &active)
        check(AdjustmentKind.exposure.value(from: active) == 2 && active.hdr?.temperature == 10000, "HDR controls did not use active snapshot")
        check(active.exposure == 1 && active.temperature == 6500, "HDR control mutated dormant SDR data")
        let data = try JSONEncoder().encode(active)
        let restored = try JSONDecoder().decode(RawSettings.self, from: data)
        check(restored == active, "HDR record did not round-trip")
        let disabled = try restored.withHDRMode(false, sourceIsHDR: true)
        check(!disabled.isHDREditing && disabled.exposure == 1 && disabled.hdr?.exposure == 2, "SDR restore lost either snapshot")
        let reenabled = try disabled.withHDRMode(true, sourceIsHDR: true)
        check(reenabled.hdr?.exposure == 2, "existing HDR snapshot was rebuilt")
        let reset = resetAll(reenabled)
        check(reset.isHDREditing && reset.hdr?.isIdentity == true && reset.exposure == 1, "reset changed mode or dormant SDR edit")
        var cameraSDR = sdr
        cameraSDR.sharpening = 0.1
        cameraSDR.blackPoint = -8; cameraSDR.whitePoint = 9; cameraSDR.toneCurve = 0.12
        cameraSDR.curveSettings = .identity
        var cameraHDR = try cameraSDR.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        check(cameraHDR.hdr == HDRSettings() && cameraHDR.sharpening == 0.1 && cameraHDR.exposure == 1,
              "camera RAW HDR must start with an independent snapshot")
        AdjustmentKind.exposure.setValue(3, in: &cameraHDR)
        check(cameraHDR.hdr?.processingVersion == 1, "ordinary HDR edit upgraded the tone version")
        AdjustmentKind.blackPoint.setValue(-25, in: &cameraHDR)
        AdjustmentKind.whitePoint.setValue(50, in: &cameraHDR)
        AdjustmentKind.toneCurve.setValue(30, in: &cameraHDR)
        check(AdjustmentKind.blackPoint.value(from: cameraHDR) == -25 &&
              AdjustmentKind.whitePoint.value(from: cameraHDR) == 50 &&
              AdjustmentKind.toneCurve.value(from: cameraHDR) == 30 &&
              cameraHDR.hdr?.processingVersion == 2, "HDR tone controls did not update the active record")
        check(cameraHDR.blackPoint == -8 && cameraHDR.whitePoint == 9 && cameraHDR.toneCurve == 0.12 &&
              cameraHDR.curveSettings == .identity, "HDR tone controls changed the dormant SDR record")
        cameraHDR.editingCurveSettings = .identity.inserting(x: 0.5, y: 0.6)
        check(cameraHDR.hdr?.toneSettings.curve == cameraHDR.editingCurveSettings && cameraHDR.curveSettings == .identity,
              "HDR custom curve did not stay separate from the SDR curve")
        let savedCamera = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(cameraHDR))
        check(savedCamera == cameraHDR, "HDR tone settings did not survive serialization")
        let resetTone = resetAll(cameraHDR)
        check(resetTone.hdr?.toneSettings.isDefault == true && resetTone.hdr?.processingVersion == 2 &&
              resetTone.blackPoint == -8 && resetTone.curveSettings == .identity,
              "HDR reset lost its version or changed dormant tone")
        var hdrColor = cameraHDR
        AdjustmentKind.vibrance.setValue(35, in: &hdrColor)
        hdrColor.editingHSLSettings.set(.hue, channel: 2, value: 18)
        hdrColor.editingGradingSettings.midtones = .init(hue: 180, saturation: 21)
        check(hdrColor.hdr?.processingVersion == 3 && hdrColor.vibrance == 0 && hdrColor.hsl.isIdentity &&
              hdrColor.gradingSettings.isDefault && AdjustmentKind.hsl.progress(in: hdrColor) != 0,
              "HDR color controls changed dormant SDR state or progress used its values")
        let resetColor = resetAll(hdrColor)
        check(resetColor.hdr?.colorSettings.isDefault == true && resetColor.hdr?.processingVersion == 3,
              "HDR reset retained color or changed processing version")
        let cameraOff = try savedCamera.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let cameraOn = try cameraOff.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        check(!cameraOff.isHDREditing && cameraOff.exposure == 1 && cameraOn.hdr?.exposure == 3,
              "camera RAW mode switch or persisted edit lost either snapshot")
        var sharpened = sdr; sharpened.sharpening = 0.1
        let hdrFromSharpened = try sharpened.withHDRMode(true, sourceIsHDR: true)
        let restoredSharpened = try hdrFromSharpened.withHDRMode(false, sourceIsHDR: true)
        check(hdrFromSharpened.isHDREditing && hdrFromSharpened.hdr?.detailSettings.sharpening == 0 &&
              restoredSharpened.sharpening == 0.1, "HDR switch did not preserve the SDR sharpening")
        check(AdjustmentKind.temperature.progress(in:active) != 0,"HDR WB progress used inactive SDR values")
        var effect=RawSettings.default; effect.photoEffects.vignetteMidpoint=60
        let hdrFromEffect = try effect.withHDRMode(true, sourceIsHDR: true)
        let restoredEffect = try hdrFromEffect.withHDRMode(false, sourceIsHDR: true)
        check(hdrFromEffect.isHDREditing && restoredEffect.photoEffects.vignetteMidpoint == 60,
              "HDR switch did not preserve the SDR effect")
        let context = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        var modeSource = RawSettings.default; modeSource.exposure = 1; modeSource.proRAWDecodeVersion = 2
        var modeHDR = try modeSource.withHDRMode(true, sourceIsHDR: true)
        AdjustmentKind.exposure.setValue(2, in: &modeHDR)
        let modeSDR = try modeHDR.withHDRMode(false, sourceIsHDR: true)
        var cleanSDR = modeSDR; cleanSDR.exposure = 0
        check(!EditorAdjustmentRules.isModified(.all, snapshot: PhotoEditState(settings: cleanSDR), context: context),
              "dormant HDR marked clean normal mode modified")
        guard case .candidate(let sdrCandidate, _) = EditorAdjustmentRules.prepareReset(.all,
            snapshot: PhotoEditState(settings: modeSDR), context: context) else {
            fatalError("normal reset all was not prepared")
        }
        check(!sdrCandidate.settings.isHDREditing && sdrCandidate.settings.hdr == modeSDR.hdr &&
              sdrCandidate.settings.proRAWDecodeVersion == 2 && sdrCandidate.settings.exposure == 0,
              "normal reset all altered dormant HDR or decode version")
        check(!EditorAdjustmentRules.isModified(.all, snapshot: sdrCandidate, context: context),
              "normal reset all left the all marker set")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: sdrCandidate, context: context) {} else {
            fatalError("normal reset all is not idempotent with dormant HDR")
        }
        guard case .candidate(let hdrCandidate, _) = EditorAdjustmentRules.prepareReset(.all,
            snapshot: PhotoEditState(settings: modeHDR), context: context) else {
            fatalError("HDR reset all was not prepared")
        }
        check(hdrCandidate.settings.isHDREditing && hdrCandidate.settings.hdr?.isIdentity == true &&
              hdrCandidate.settings.exposure == 1 && hdrCandidate.settings.proRAWDecodeVersion == 2,
              "HDR reset all altered dormant SDR snapshot or decode version")
        check(!EditorAdjustmentRules.isModified(.all, snapshot: hdrCandidate, context: context),
              "HDR reset all left the all marker set despite dormant SDR")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: hdrCandidate, context: context) {} else {
            fatalError("HDR reset all is not idempotent with dormant SDR")
        }

        // Q5: HDR 显示映射（HDR 亮度上限 + SDR 底图曝光/对比度/饱和度）分组归属、显隐、单重置与重置全部隔离
        check(EditorAdjustmentRules.tools(.hdrRendition) == [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation],
              "HDR rendition group did not own the exact four display-mapping tools")
        check(EditorAdjustmentGroup.visibleGroups(isHDREditing: false) == [.looks, .light, .color, .effects, .detail, .geometry] &&
              !EditorAdjustmentGroup.visibleGroups(isHDREditing: false).contains(.hdrRendition),
              "SDR mode exposed hdrRendition")
        check(EditorAdjustmentGroup.visibleGroups(isHDREditing: true) == EditorAdjustmentGroup.allCases,
              "HDR mode did not expose all seven groups including hdrRendition")
        for tool in EditorAdjustmentRules.tools(.hdrRendition) {
            check(EditorAdjustmentRules.normalizedTool(tool, isHDREditing: true) == tool,
                  "HDR mode did not retain \(tool)")
            check(EditorAdjustmentRules.normalizedTool(tool, isHDREditing: false) == .adjustment(.exposure) &&
                  EditorAdjustmentRules.groupFor(EditorAdjustmentRules.normalizedTool(tool, isHDREditing: false)) != .hdrRendition,
                  "SDR normalization did not exit hdrRendition from \(tool)")
        }

        var renditionHDR = try sdr.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        AdjustmentKind.exposure.setValue(1.5, in: &renditionHDR)
        renditionHDR.hdr?.cameraDevelopmentSettings.fbddLevel = 2
        let untouchedRendition = PhotoEditState(settings: renditionHDR, filmID: "dormant-look")
        check(!EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: untouchedRendition, context: context) &&
              EditorAdjustmentRules.tools(.hdrRendition).allSatisfy { !EditorAdjustmentRules.isModified(.tool($0), snapshot: untouchedRendition, context: context) },
              "Untouched HDR rendition or camera development falsely marked HDR rendition modified")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: untouchedRendition, context: context),
           renditionHDR.hdr?.processingVersion == 1 {} else {
            fatalError("No-op HDR rendition group reset mutated version or returned a candidate")
        }

        var fullRendition = HDRRenditionSettings()
        fullRendition.peakLimitEV = 2.4
        fullRendition.sdrExposureEV = -1.2
        fullRendition.sdrContrast = 35
        fullRendition.sdrSaturation = -25
        renditionHDR.hdr?.renditionSettings = fullRendition
        let renditionSnapshot = PhotoEditState(settings: renditionHDR, filmID: "dormant-look")
        check(renditionHDR.hdr?.processingVersion == 4, "HDR rendition edit did not upgrade processingVersion to 4")
        check(EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: renditionSnapshot, context: context) &&
              EditorAdjustmentRules.tools(.hdrRendition).allSatisfy { EditorAdjustmentRules.isModified(.tool($0), snapshot: renditionSnapshot, context: context) },
              "Modified HDR rendition fields did not mark group and tools modified")

        for (tool, keyPath) in [
            (EditorToolSelection.hdrPeakLimit, \HDRRenditionSettings.peakLimitEV),
            (.hdrSDRExposure, \.sdrExposureEV),
            (.hdrSDRContrast, \.sdrContrast),
            (.hdrSDRSaturation, \.sdrSaturation),
        ] {
            guard case .candidate(let singleReset, let singleRequiresConfirmation) =
                    EditorAdjustmentRules.prepareReset(.tool(tool), snapshot: renditionSnapshot, context: context) else {
                fatalError("Single HDR rendition tool reset was not prepared for \(tool)")
            }
            check(!singleRequiresConfirmation, "Single HDR rendition tool reset for \(tool) skips confirmation")
            var expectedRendition = fullRendition
            expectedRendition[keyPath: keyPath] = 0
            check(singleReset.settings.hdr?.renditionSettings == expectedRendition,
                  "Single HDR rendition reset for \(tool) mutated sibling rendition fields")
            check(!EditorAdjustmentRules.isModified(.tool(tool), snapshot: singleReset, context: context) &&
                  EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: singleReset, context: context),
                  "Single HDR rendition reset for \(tool) left wrong modified state")
            check(singleReset.settings.hdr?.exposure == 1.5 &&
                  singleReset.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
                  singleReset.settings.exposure == sdr.exposure && singleReset.filmID == "dormant-look",
                  "Single HDR rendition reset touched other HDR groups, camera development, or dormant SDR")
        }

        guard case .candidate(let groupReset, let groupRequiresConfirmation) =
                EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: renditionSnapshot, context: context) else {
            fatalError("HDR rendition group reset was not prepared")
        }
        check(groupRequiresConfirmation, "HDR rendition group reset requires confirmation aligned with Mac")
        check(groupReset.settings.hdr?.renditionSettings == HDRRenditionSettings() &&
              groupReset.settings.hdr?.renditionSettings.isDefault == true &&
              groupReset.settings.hdr?.processingVersion == 4,
              "HDR rendition group reset did not restore all four fields to default or lost processingVersion")
        check(groupReset.settings.hdr?.exposure == 1.5 &&
              groupReset.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
              groupReset.settings.exposure == sdr.exposure &&
              groupReset.settings.contrast == sdr.contrast &&
              groupReset.filmID == "dormant-look",
              "HDR rendition group reset mutated other HDR edits, camera development, or dormant SDR")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: groupReset, context: context),
           !EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: groupReset, context: context) {} else {
            fatalError("HDR rendition group reset was not idempotent")
        }

        let dormantRenditionSDR = try renditionHDR.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let dormantSnapshot = PhotoEditState(settings: dormantRenditionSDR, filmID: "dormant-look")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: dormantSnapshot, context: context),
           !EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: dormantSnapshot, context: context),
           EditorAdjustmentRules.tools(.hdrRendition).allSatisfy({
               guard case .unchanged = EditorAdjustmentRules.prepareReset(.tool($0), snapshot: dormantSnapshot, context: context) else { return false }
               return !EditorAdjustmentRules.isModified(.tool($0), snapshot: dormantSnapshot, context: context)
           }) {} else {
            fatalError("Dormant HDR rendition was exposed or resettable in ordinary SDR mode")
        }
        guard case .candidate(let sdrResetAll, _) = EditorAdjustmentRules.prepareReset(.all, snapshot: dormantSnapshot, context: context) else {
            fatalError("Ordinary SDR reset-all with dormant HDR rendition was not prepared")
        }
        check(sdrResetAll.settings.hdr?.renditionSettings == fullRendition &&
              sdrResetAll.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
              !sdrResetAll.settings.isHDREditing && sdrResetAll.settings.exposure == 0,
              "Ordinary SDR reset-all mutated dormant HDR rendition or camera development")
        guard case .candidate(let hdrResetAll, let allRequiresConfirmation) =
                EditorAdjustmentRules.prepareReset(.all, snapshot: renditionSnapshot, context: context) else {
            fatalError("HDR reset-all with rendition edits was not prepared")
        }
        check(allRequiresConfirmation, "HDR reset-all requires confirmation aligned with Mac")
        check(hdrResetAll.settings.isHDREditing &&
              hdrResetAll.settings.hdr?.renditionSettings.isDefault == true &&
              hdrResetAll.settings.hdr?.isIdentity == true &&
              hdrResetAll.settings.exposure == sdr.exposure &&
              hdrResetAll.settings.contrast == sdr.contrast &&
              hdrResetAll.filmID == "dormant-look",
              "HDR reset-all failed to reset HDR rendition or mutated dormant SDR")

        print("PASS iOS HDR legacy, record, conversion, control routing and reset")
    }
}
