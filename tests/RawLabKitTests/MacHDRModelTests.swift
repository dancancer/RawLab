import Foundation
import XCTest
@testable import RawLabKit

final class MacHDRModelTests: XCTestCase {
    func testHDRLegacyRecordConversionControlRoutingAndReset() throws {
        var aiSource = Adjustments()
        aiSource.aiDenoiseEnabled = true
        aiSource.exposure = 0.8
        aiSource.rawNoiseReduction = 2
        let raster = aiSource.resolvedForRaster
        XCTAssertTrue(
            !raster.aiDenoiseEnabled && raster.rawNoiseReduction == 0 && raster.exposure == 0.8,
            "raster targets must omit RAW-only AI while retaining shared adjustments"
        )
        XCTAssertTrue(aiSource.aiDenoiseEnabled, "resolving a raster target must retain AI on the RAW source")

        let legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        XCTAssertTrue(
            legacy.hdr == nil && !legacy.isHDREditing && legacy.processing == .legacy,
            "legacy record changed mode or processing"
        )

        var sdr = Adjustments()
        sdr.exposure = 1
        sdr.contrast = 0.75
        sdr.highlights = -0.5

        var recipe = sdr
        recipe.setTransferRecipe(MasterRecipe.allRecipes[0].id)
        recipe.strength = 0.5
        recipe.contrast = 1.4
        recipe.highlights = 0.6
        recipe.shadows = 0.8
        recipe.saturation = 0.8
        let recipeHDR = try recipe.withHDRMode(true, sourceIsHDR: true)
        XCTAssertTrue(
            recipeHDR.hdr?.exposure == 0.5 && abs(recipeHDR.hdr!.contrast - 20) < 0.00001 &&
                recipeHDR.hdr?.highlights == -30 && recipeHDR.hdr?.shadows == 40 &&
                abs(recipeHDR.hdr!.saturation + 10) < 0.00001,
            "Gain-map HDR did not start from effective recipe values"
        )

        var extreme = sdr
        extreme.exposure = 8
        extreme.contrast = 3
        extreme.highlights = 2
        extreme.shadows = 2
        extreme.saturation = -1
        let bounded = try extreme.withHDRMode(true, sourceIsHDR: true)
        XCTAssertTrue(
            bounded.hdr?.exposure == 4 && bounded.hdr?.contrast == 100 && bounded.hdr?.highlights == -100 &&
                bounded.hdr?.shadows == 100 && bounded.hdr?.saturation == -100,
            "Gain-map HDR did not clamp legacy values to HDR ranges"
        )

        var recipeRestored = try recipeHDR.withHDRMode(false, sourceIsHDR: true)
        recipeRestored.hdr = nil
        XCTAssertEqual(recipeRestored, recipe, "HDR initialization changed the dormant SDR recipe")

        var active = try sdr.withHDRMode(true, sourceIsHDR: true)
        XCTAssertTrue(
            active.hdr?.exposure == 1 && active.hdr?.contrast == -25 && active.hdr?.highlights == 50,
            "conversion lost logical values"
        )

        active.set(.exposure, to: 2)
        active.set(.temperature, to: 10000)
        active.rotateGeometry(clockwise: true)
        XCTAssertTrue(
            AdjustmentParameter.exposure.value(from: active) == 2 && active.hdr?.temperature == 10000 &&
                active.hdr?.geometry.quarterTurns == 1,
            "HDR controls did not use the active snapshot"
        )
        XCTAssertTrue(
            active.exposure == 1 && active.temperature == 6500 && active.geometry == nil,
            "HDR control mutated dormant SDR data"
        )

        let data = try JSONEncoder().encode(active)
        let restored = try JSONDecoder().decode(Adjustments.self, from: data)
        XCTAssertEqual(restored, active, "HDR record did not round-trip")

        let disabled = try restored.withHDRMode(false, sourceIsHDR: true)
        XCTAssertTrue(
            !disabled.isHDREditing && disabled.exposure == 1 && disabled.hdr?.exposure == 2,
            "SDR restore lost either snapshot"
        )
        let reenabled = try disabled.withHDRMode(true, sourceIsHDR: true)
        XCTAssertEqual(reenabled.hdr?.exposure, 2, "existing HDR snapshot was rebuilt")

        var reset = reenabled
        reset.resetAll()
        XCTAssertTrue(
            reset.isHDREditing && reset.hdr?.isIdentity == true && reset.exposure == 1,
            "reset changed mode or dormant SDR edit"
        )

        var cameraSDR = sdr
        cameraSDR.sharpening = 0.25
        cameraSDR.blackPoint = -8
        cameraSDR.whitePoint = 9
        cameraSDR.toneCurve = 0.12
        cameraSDR.curveSettings = .identity
        var cameraHDR = try cameraSDR.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        XCTAssertTrue(
            cameraHDR.hdr == HDRSettings() && cameraHDR.sharpening == 0.25 && cameraHDR.exposure == 1,
            "camera RAW HDR must start with an independent snapshot"
        )

        cameraHDR.set(.exposure, to: 3)
        XCTAssertEqual(cameraHDR.hdr?.processingVersion, 1, "ordinary HDR edit upgraded the tone version")

        cameraHDR.set(.blackPoint, to: -25)
        cameraHDR.set(.whitePoint, to: 50)
        cameraHDR.set(.toneCurve, to: 30)
        XCTAssertTrue(
            AdjustmentParameter.blackPoint.value(from: cameraHDR) == -25 &&
                AdjustmentParameter.whitePoint.value(from: cameraHDR) == 50 &&
                AdjustmentParameter.toneCurve.value(from: cameraHDR) == 30 &&
                cameraHDR.hdr?.processingVersion == 2,
            "HDR tone controls did not update the active record"
        )
        XCTAssertTrue(
            cameraHDR.blackPoint == -8 && cameraHDR.whitePoint == 9 && cameraHDR.toneCurve == 0.12 &&
                cameraHDR.curveSettings == .identity,
            "HDR tone controls changed the dormant SDR record"
        )

        cameraHDR.editingCurveSettings = .identity.inserting(x: 0.5, y: 0.6)
        XCTAssertTrue(
            cameraHDR.hdr?.toneSettings.curve == cameraHDR.editingCurveSettings && cameraHDR.curveSettings == .identity,
            "HDR custom curve did not stay separate from the SDR curve"
        )

        let savedCamera = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(cameraHDR))
        XCTAssertEqual(savedCamera, cameraHDR, "HDR tone settings did not survive serialization")

        let cameraOff = try savedCamera.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let cameraOn = try cameraOff.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        XCTAssertTrue(
            !cameraOff.isHDREditing && cameraOff.exposure == 1 && cameraOn.hdr?.exposure == 3,
            "camera RAW mode switch or persisted edit lost either snapshot"
        )

        var ai = cameraOn
        ai.activeAIDenoise = true
        XCTAssertTrue(
            ai.hdrCameraAIEnabled && !ai.aiDenoiseEnabled && !ai.neutralSettings.activeAIDenoise,
            "HDR Bayer AI changed the SDR flag or neutral reference"
        )
        let restoredAI = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(ai))
        XCTAssertEqual(restoredAI, ai, "HDR Bayer AI selection did not survive serialization")

        var aiSDR = try restoredAI.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        XCTAssertTrue(aiSDR.hdrCameraAIEnabled && !aiSDR.activeAIDenoise, "SDR mode used the saved HDR Bayer AI selection")
        aiSDR.resetAll()
        XCTAssertTrue(aiSDR.hdrCameraAIEnabled && !aiSDR.activeAIDenoise, "SDR reset cleared the dormant HDR Bayer AI selection")

        ai.resetAll()
        XCTAssertTrue(!ai.activeAIDenoise && ai.isHDREditing, "HDR reset kept the active AI selection")

        var sharpened = sdr
        sharpened.sharpening = 0.1
        let hdrFromSharpened = try sharpened.withHDRMode(true, sourceIsHDR: true)
        let restoredSharpened = try hdrFromSharpened.withHDRMode(false, sourceIsHDR: true)
        XCTAssertTrue(
            hdrFromSharpened.isHDREditing && hdrFromSharpened.hdr?.detailSettings.sharpening == 0 &&
                restoredSharpened.sharpening == 0.1,
            "HDR switch did not preserve the SDR sharpening"
        )

        let context = MacEditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor, neutralFilmID: "")
        let editedTone = MacPhotoEditState(settings: cameraHDR, filmID: "")
        if case .candidate(let candidate) = MacEditorAdjustmentRules.prepareReset(scope: .group(.light), snapshot: editedTone, context: context) {
            XCTAssertTrue(
                candidate.settings.hdr?.toneSettings.isDefault == true && candidate.settings.hdr?.processingVersion == 2 &&
                    candidate.settings.blackPoint == -8 && candidate.settings.curveSettings == .identity,
                "HDR group reset lost its version or changed dormant tone"
            )
        } else {
            XCTFail("HDR tone group reset was not prepared")
        }

        var hdrColor = cameraHDR
        hdrColor.set(.vibrance, to: 35)
        hdrColor.editingHSLSettings.set(.hue, channel: 2, value: 18)
        hdrColor.editingGradingSettings.midtones = .init(hue: 180, saturation: 21)
        let colorSnapshot = MacPhotoEditState(settings: hdrColor, filmID: "")
        XCTAssertTrue(
            hdrColor.hdr?.processingVersion == 3 && hdrColor.vibrance == 0 &&
                hdrColor.hslSettings.isIdentity && hdrColor.gradingSettings.isDefault,
            "HDR color controls changed dormant SDR state"
        )
        if case .candidate(let candidate) = MacEditorAdjustmentRules.prepareReset(scope: .group(.color), snapshot: colorSnapshot, context: context) {
            XCTAssertTrue(
                candidate.settings.hdr?.colorSettings.isDefault == true && candidate.settings.hdr?.processingVersion == 3 &&
                    candidate.settings.hdr?.toneSettings == cameraHDR.hdr?.toneSettings,
                "HDR color reset changed tone or processing version"
            )
        } else {
            XCTFail("HDR color group reset was not prepared")
        }

        var photograph = MacPhotoEditState(settings: active, filmID: "dormant-look")
        XCTAssertTrue(
            MacEditorAdjustmentRules.isModified(scope: .tool(.whiteBalance), snapshot: photograph, context: context),
            "HDR relative WB is not marked modified"
        )
        if case .candidate(let candidate) = MacEditorAdjustmentRules.prepareReset(scope: .tool(.exposure), snapshot: photograph, context: context) {
            XCTAssertTrue(
                candidate.settings.hdr?.exposure == 0 && candidate.settings.exposure == active.exposure &&
                    candidate.filmID == photograph.filmID,
                "tool reset changed inactive fields"
            )
        } else {
            XCTFail("HDR exposure reset was not prepared")
        }

        photograph.settings.hdr?.saturation = 30
        if case .candidate(let candidate) = MacEditorAdjustmentRules.prepareReset(scope: .all, snapshot: photograph, context: context) {
            XCTAssertTrue(
                candidate.settings.hdr?.isIdentity == true && candidate.settings.isHDREditing &&
                    candidate.filmID == photograph.filmID && candidate.settings.exposure == active.exposure,
                "all reset lost mode or dormant SDR snapshot"
            )
        } else {
            XCTFail("HDR all reset was not prepared")
        }

        var modeSource = Adjustments()
        modeSource.exposure = 1
        modeSource.proRAWDecodeVersion = 2
        var modeHDR = try modeSource.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        modeHDR.set(.exposure, to: 2)
        modeHDR.activeAIDenoise = true
        let modeSDR = try modeHDR.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        var cleanSDR = modeSDR
        cleanSDR.exposure = 0
        XCTAssertFalse(
            MacEditorAdjustmentRules.isModified(scope: .all, snapshot: MacPhotoEditState(settings: cleanSDR, filmID: ""), context: context),
            "dormant HDR marked the SDR snapshot modified"
        )

        var sdrAll = modeSDR
        sdrAll.resetAll()
        XCTAssertTrue(
            sdrAll.hdr == modeSDR.hdr && sdrAll.hdrCameraAIEnabled && sdrAll.proRAWDecodeVersion == 2 && sdrAll.exposure == 0,
            "SDR reset all changed the dormant HDR record or decode version"
        )

        if case .candidate(let candidate) = MacEditorAdjustmentRules.prepareReset(
            scope: .all,
            snapshot: MacPhotoEditState(settings: modeSDR, filmID: ""),
            context: context
        ) {
            XCTAssertTrue(
                candidate.settings.hdr == modeSDR.hdr && candidate.settings.hdrCameraAIEnabled &&
                    candidate.settings.proRAWDecodeVersion == 2 && !candidate.settings.isHDREditing,
                "SDR all reset changed the dormant HDR record or decode version"
            )
            XCTAssertFalse(
                MacEditorAdjustmentRules.isModified(scope: .all, snapshot: candidate, context: context),
                "SDR all reset left the all marker set"
            )
            if case .unchanged = MacEditorAdjustmentRules.prepareReset(scope: .all, snapshot: candidate, context: context) {
                XCTAssertTrue(true)
            } else {
                XCTFail("SDR all reset is not idempotent")
            }
            let backToHDR = try candidate.settings.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
            XCTAssertTrue(
                backToHDR.hdr == modeHDR.hdr && backToHDR.activeAIDenoise &&
                    AdjustmentParameter.exposure.value(from: backToHDR) == 2 && backToHDR.proRAWDecodeVersion == 2,
                "HDR edit did not survive an SDR all reset"
            )
        } else {
            XCTFail("SDR all reset was not prepared")
        }

        var hdrAll = modeHDR
        hdrAll.resetAll()
        XCTAssertTrue(
            hdrAll.isHDREditing && hdrAll.hdr?.isIdentity == true && hdrAll.exposure == 1 && hdrAll.proRAWDecodeVersion == 2,
            "HDR reset all changed the dormant SDR snapshot or decode version"
        )
        if case .candidate(let candidate) = MacEditorAdjustmentRules.prepareReset(
            scope: .all,
            snapshot: MacPhotoEditState(settings: modeHDR, filmID: ""),
            context: context
        ) {
            XCTAssertTrue(
                candidate.settings.hdr?.isIdentity == true && candidate.settings.exposure == 1 &&
                    candidate.settings.proRAWDecodeVersion == 2,
                "HDR all reset changed the dormant SDR snapshot or decode version"
            )
            XCTAssertFalse(
                MacEditorAdjustmentRules.isModified(scope: .all, snapshot: candidate, context: context),
                "HDR all reset left the all marker set despite dormant SDR"
            )
            if case .unchanged = MacEditorAdjustmentRules.prepareReset(scope: .all, snapshot: candidate, context: context) {
                XCTAssertTrue(true)
            } else {
                XCTFail("HDR all reset is not idempotent")
            }
            let backToSDR = try candidate.settings.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
            XCTAssertTrue(
                !backToSDR.isHDREditing && backToSDR.exposure == 1 && backToSDR.proRAWDecodeVersion == 2,
                "SDR edit did not survive an HDR all reset"
            )
        } else {
            XCTFail("HDR all reset with dormant SDR was not prepared")
        }

        var effect = Adjustments()
        effect.photoEffects = PhotoEffectsSettings()
        effect.photoEffects?.vignetteMidpoint = 60
        let hdrFromEffect = try effect.withHDRMode(true, sourceIsHDR: true)
        let restoredEffect = try hdrFromEffect.withHDRMode(false, sourceIsHDR: true)
        XCTAssertTrue(
            hdrFromEffect.isHDREditing && restoredEffect.photoEffects?.vignetteMidpoint == 60,
            "HDR switch did not preserve the SDR effect"
        )

        // Q5: HDR 显示映射（HDR 亮度上限 + SDR 底图曝光/对比度/饱和度）分组重置与单项重置，且不混入相机显影、不破坏既有重置全部语义
        XCTAssertEqual(
            EditorAdjustmentGroup.hdrRendition.tools,
            [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation],
            "HDR rendition group did not own the exact four display-mapping tools"
        )
        var renditionHDR = try sdr.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        renditionHDR.set(.exposure, to: 1.5)
        renditionHDR.hdr?.cameraDevelopmentSettings.fbddLevel = 2
        let untouchedRendition = MacPhotoEditState(settings: renditionHDR, filmID: "dormant-look")
        XCTAssertTrue(
            !MacEditorAdjustmentRules.isModified(scope: .group(.hdrRendition), snapshot: untouchedRendition, context: context) &&
                EditorAdjustmentGroup.hdrRendition.tools.allSatisfy {
                    !MacEditorAdjustmentRules.isModified(scope: .tool($0), snapshot: untouchedRendition, context: context)
                },
            "Untouched HDR rendition or camera development falsely marked HDR rendition modified"
        )
        XCTAssertTrue(
            MacEditorAdjustmentRules.prepareReset(scope: .group(.hdrRendition), snapshot: untouchedRendition, context: context) == .unchanged &&
                renditionHDR.hdr?.processingVersion == 1,
            "No-op HDR rendition group reset mutated version or returned a candidate"
        )

        var fullRendition = HDRRenditionSettings()
        fullRendition.peakLimitEV = 2.4
        fullRendition.sdrExposureEV = -1.2
        fullRendition.sdrContrast = 35
        fullRendition.sdrSaturation = -25
        renditionHDR.hdr?.renditionSettings = fullRendition
        let renditionSnapshot = MacPhotoEditState(settings: renditionHDR, filmID: "dormant-look")
        XCTAssertEqual(renditionHDR.hdr?.processingVersion, 4, "HDR rendition edit did not upgrade processingVersion to 4")
        XCTAssertTrue(
            MacEditorAdjustmentRules.isModified(scope: .group(.hdrRendition), snapshot: renditionSnapshot, context: context) &&
                EditorAdjustmentGroup.hdrRendition.tools.allSatisfy {
                    MacEditorAdjustmentRules.isModified(scope: .tool($0), snapshot: renditionSnapshot, context: context)
                },
            "Modified HDR rendition fields did not mark group and tools modified"
        )

        for (tool, keyPath) in [
            (EditorAdjustmentTool.hdrPeakLimit, \HDRRenditionSettings.peakLimitEV),
            (.hdrSDRExposure, \.sdrExposureEV),
            (.hdrSDRContrast, \.sdrContrast),
            (.hdrSDRSaturation, \.sdrSaturation),
        ] {
            guard case .candidate(let singleReset) = MacEditorAdjustmentRules.prepareReset(
                scope: .tool(tool),
                snapshot: renditionSnapshot,
                context: context
            ) else {
                XCTFail("Single HDR rendition tool reset was not prepared for \(tool.rawValue)")
                return
            }
            var expectedRendition = fullRendition
            expectedRendition[keyPath: keyPath] = 0
            XCTAssertEqual(
                singleReset.settings.hdr?.renditionSettings,
                expectedRendition,
                "Single HDR rendition reset for \(tool.rawValue) mutated sibling rendition fields"
            )
            XCTAssertTrue(
                !MacEditorAdjustmentRules.isModified(scope: .tool(tool), snapshot: singleReset, context: context) &&
                    MacEditorAdjustmentRules.isModified(scope: .group(.hdrRendition), snapshot: singleReset, context: context),
                "Single HDR rendition reset for \(tool.rawValue) left wrong modified state"
            )
            XCTAssertTrue(
                singleReset.settings.hdr?.exposure == 1.5 &&
                    singleReset.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
                    singleReset.settings.exposure == sdr.exposure && singleReset.filmID == "dormant-look",
                "Single HDR rendition reset touched other HDR groups, camera development, or dormant SDR"
            )
        }

        guard case .candidate(let groupReset) = MacEditorAdjustmentRules.prepareReset(
            scope: .group(.hdrRendition),
            snapshot: renditionSnapshot,
            context: context
        ) else {
            XCTFail("HDR rendition group reset was not prepared")
            return
        }
        XCTAssertTrue(
            groupReset.settings.hdr?.renditionSettings == HDRRenditionSettings() &&
                groupReset.settings.hdr?.renditionSettings.isDefault == true &&
                groupReset.settings.hdr?.processingVersion == 4,
            "HDR rendition group reset did not restore all four fields to default or lost processingVersion"
        )
        XCTAssertTrue(
            groupReset.settings.hdr?.exposure == 1.5 &&
                groupReset.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
                groupReset.settings.exposure == sdr.exposure &&
                groupReset.settings.contrast == sdr.contrast &&
                groupReset.filmID == "dormant-look",
            "HDR rendition group reset mutated other HDR edits, camera development, or dormant SDR"
        )
        XCTAssertTrue(
            !MacEditorAdjustmentRules.isModified(scope: .group(.hdrRendition), snapshot: groupReset, context: context) &&
                MacEditorAdjustmentRules.prepareReset(scope: .group(.hdrRendition), snapshot: groupReset, context: context) == .unchanged,
            "HDR rendition group reset was not idempotent"
        )

        let dormantRenditionSDR = try renditionHDR.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let dormantSnapshot = MacPhotoEditState(settings: dormantRenditionSDR, filmID: "dormant-look")
        XCTAssertTrue(
            !MacEditorAdjustmentRules.isModified(scope: .group(.hdrRendition), snapshot: dormantSnapshot, context: context) &&
                EditorAdjustmentGroup.hdrRendition.tools.allSatisfy {
                    !MacEditorAdjustmentRules.isModified(scope: .tool($0), snapshot: dormantSnapshot, context: context)
                } &&
                MacEditorAdjustmentRules.prepareReset(scope: .group(.hdrRendition), snapshot: dormantSnapshot, context: context) == .unchanged,
            "Dormant HDR rendition was exposed or resettable in ordinary SDR mode"
        )
        guard case .candidate(let sdrResetAll) = MacEditorAdjustmentRules.prepareReset(
            scope: .all,
            snapshot: dormantSnapshot,
            context: context
        ) else {
            XCTFail("Ordinary SDR reset-all with dormant HDR rendition was not prepared")
            return
        }
        XCTAssertTrue(
            sdrResetAll.settings.hdr?.renditionSettings == fullRendition &&
                sdrResetAll.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
                !sdrResetAll.settings.isHDREditing && sdrResetAll.settings.exposure == 0,
            "Ordinary SDR reset-all mutated dormant HDR rendition or camera development"
        )
        guard case .candidate(let hdrResetAll) = MacEditorAdjustmentRules.prepareReset(
            scope: .all,
            snapshot: renditionSnapshot,
            context: context
        ) else {
            XCTFail("HDR reset-all with rendition edits was not prepared")
            return
        }
        XCTAssertTrue(
            hdrResetAll.settings.isHDREditing &&
                hdrResetAll.settings.hdr?.renditionSettings.isDefault == true &&
                hdrResetAll.settings.hdr?.isIdentity == true &&
                hdrResetAll.settings.exposure == sdr.exposure &&
                hdrResetAll.settings.contrast == sdr.contrast &&
                hdrResetAll.filmID == "dormant-look",
            "HDR reset-all failed to reset HDR rendition or mutated dormant SDR"
        )
    }

    func testHDRTransferCaptureTargetPreflightAndMixedModeIsolation() throws {
        var settings = Adjustments()
        settings.hdr = HDRSettings()
        settings.hdr?.exposure = 1
        settings.hdr?.temperature = 10000
        settings.aiDenoiseEnabled = true
        let source = MacPhotoEditState(settings: settings, filmID: "")
        let context = MacAdjustmentTransferContext(identifier: "source", isRaw: false, sourceIsHDR: true)

        let payload = try MacAdjustmentTransfer.capture(scope: .all, snapshot: source, context: context)
        XCTAssertTrue(payload.source.isHDR && payload.payloadVersion == 2, "HDR capture used legacy fields")

        var targetSettings = Adjustments()
        targetSettings.exposure = -2
        targetSettings.hdr = HDRSettings()
        let target = MacPhotoEditState(settings: targetSettings, filmID: "")
        let prepared = try MacAdjustmentTransfer.prepare(payload: payload, target: target, context: context)
        XCTAssertTrue(
            prepared.settings.hdr?.exposure == 1 && prepared.settings.exposure == -2 && prepared.settings.isHDREditing,
            "HDR target lost its dormant SDR snapshot or mode"
        )

        var sdr = target
        sdr.settings.hdr = nil
        XCTAssertThrowsError(
            try MacAdjustmentTransfer.prepare(payload: payload, target: sdr, context: context),
            "relative WB reached SDR target"
        ) { error in
            if case AdjustmentTransferError.incompatible = error { return }
            XCTFail("Expected AdjustmentTransferError.incompatible, got \(error)")
        }

        let common = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: source, context: context)
        let legacy = try MacAdjustmentTransfer.prepare(payload: common, target: sdr, context: context)
        XCTAssertTrue(legacy.settings.hdr == nil && legacy.settings.exposure == 1, "copy silently switched target mode")

        let proRAWContext = MacAdjustmentTransferContext(identifier: "proraw", isRaw: true, sourceSupportsCameraHDR: true)
        let proRAWPayload = try MacAdjustmentTransfer.capture(scope: .all, snapshot: source, context: proRAWContext)
        var proRAWTargetSettings = Adjustments()
        proRAWTargetSettings.hdr = HDRSettings()
        let proRAWTarget = MacPhotoEditState(settings: proRAWTargetSettings, filmID: "")
        let proRAWPrepared = try MacAdjustmentTransfer.prepare(payload: proRAWPayload, target: proRAWTarget, context: proRAWContext)
        XCTAssertTrue(
            proRAWPrepared.settings.hdr?.exposure == 1 && proRAWPrepared.settings.isHDREditing,
            "ProRAW HDR target rejected a valid HDR payload"
        )

        XCTAssertThrowsError(
            try MacAdjustmentTransfer.prepare(payload: proRAWPayload, target: sdr, context: proRAWContext),
            "non-neutral ProRAW HDR white balance reached an SDR target"
        ) { error in
            if case AdjustmentTransferError.incompatible = error { return }
            XCTFail("Expected AdjustmentTransferError.incompatible, got \(error)")
        }

        let proRAWSDR = try MacAdjustmentTransfer.prepare(payload: common, target: sdr, context: proRAWContext)
        XCTAssertTrue(proRAWSDR.settings.hdr == nil && proRAWSDR.settings.exposure == 1, "ProRAW HDR transfer upgraded an SDR target")

        let cameraContext = MacAdjustmentTransferContext(identifier: "camera", isRaw: true, sourceSupportsCameraHDR: true)
        var cameraSettings = settings
        cameraSettings.hdr?.renditionSettings.sdrExposureEV = -0.75
        let cameraPayload = try MacAdjustmentTransfer.capture(
            scope: .modified,
            snapshot: MacPhotoEditState(settings: cameraSettings, filmID: ""),
            context: cameraContext
        )
        let cameraTarget = try MacAdjustmentTransfer.prepare(payload: cameraPayload, target: target, context: cameraContext)
        XCTAssertTrue(
            cameraTarget.settings.hdr == cameraSettings.hdr && cameraTarget.settings.exposure == -2 &&
                cameraTarget.settings.proRAWDecodeVersion == nil,
            "Camera RAW transfer lost either edit or invented a ProRAW version"
        )

        XCTAssertThrowsError(
            try MacAdjustmentTransfer.capture(
                scope: .all,
                snapshot: source,
                context: MacAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true)
            ),
            "RAW without HDR capability was accepted as a source"
        ) { error in
            if case AdjustmentTransferError.incompatible = error { return }
            XCTFail("Expected AdjustmentTransferError.incompatible, got \(error)")
        }

        XCTAssertThrowsError(
            try MacAdjustmentTransfer.prepare(
                payload: proRAWPayload,
                target: proRAWTarget,
                context: MacAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true)
            ),
            "RAW without HDR capability was accepted as a target"
        ) { error in
            if case AdjustmentTransferError.incompatible = error { return }
            XCTFail("Expected AdjustmentTransferError.incompatible, got \(error)")
        }
    }
}
