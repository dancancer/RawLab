import Foundation
import XCTest
@testable import RawLabKit

final class IOSHDRModelTests: XCTestCase {
    private func resetAll(
        _ settings: RawSettings,
        context: EditorAdjustmentContext = .init(isRaw: false, defaultExposureMode: .sensor),
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RawSettings {
        switch EditorAdjustmentRules.prepareReset(.all, snapshot: PhotoEditState(settings: settings), context: context) {
        case .candidate(let state, _): return state.settings
        case .unchanged: return settings
        case .blocked(let reason):
            XCTFail("unexpected reset block: \(reason)", file: file, line: line)
            return settings
        }
    }

    func testHDRLegacyRecordConversionControlRoutingAndReset() throws {
        let legacy = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(
            legacy.hdr == nil && !legacy.isHDREditing && legacy.processing == .legacy,
            "legacy record changed mode or processing"
        )
        var sdr = RawSettings.default; sdr.exposure = 1; sdr.contrast = 0.75; sdr.highlights = -0.5
        var recipe = sdr; recipe.masterRecipeID = "test-recipe"; recipe.lutStrength = 0.5
        recipe.contrast = 1.4; recipe.highlights = 0.6; recipe.shadows = 0.8; recipe.saturation = 0.8
        let recipeHDR = try recipe.withHDRMode(true, sourceIsHDR: true)
        XCTAssertTrue(
            recipeHDR.hdr?.exposure == 0.5 && abs(recipeHDR.hdr!.contrast - 20) < 0.00001 &&
                recipeHDR.hdr?.highlights == -30 && recipeHDR.hdr?.shadows == 40 &&
                abs(recipeHDR.hdr!.saturation + 10) < 0.00001,
            "Gain-map HDR did not start from effective recipe values"
        )
        var extreme = sdr; extreme.exposure = 8; extreme.contrast = 3; extreme.highlights = 2; extreme.shadows = 2; extreme.saturation = -1
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
            "conversion lost UI scale/direction"
        )
        AdjustmentKind.exposure.setValue(2, in: &active)
        AdjustmentKind.temperature.setValue(10000, in: &active)
        XCTAssertTrue(
            AdjustmentKind.exposure.value(from: active) == 2 && active.hdr?.temperature == 10000,
            "HDR controls did not use active snapshot"
        )
        XCTAssertTrue(active.exposure == 1 && active.temperature == 6500, "HDR control mutated dormant SDR data")
        let data = try JSONEncoder().encode(active)
        let restored = try JSONDecoder().decode(RawSettings.self, from: data)
        XCTAssertEqual(restored, active, "HDR record did not round-trip")
        let disabled = try restored.withHDRMode(false, sourceIsHDR: true)
        XCTAssertTrue(
            !disabled.isHDREditing && disabled.exposure == 1 && disabled.hdr?.exposure == 2,
            "SDR restore lost either snapshot"
        )
        let reenabled = try disabled.withHDRMode(true, sourceIsHDR: true)
        XCTAssertEqual(reenabled.hdr?.exposure, 2, "existing HDR snapshot was rebuilt")
        let reset = resetAll(reenabled)
        XCTAssertTrue(
            reset.isHDREditing && reset.hdr?.isIdentity == true && reset.exposure == 1,
            "reset changed mode or dormant SDR edit"
        )
        var cameraSDR = sdr
        cameraSDR.sharpening = 0.1
        cameraSDR.blackPoint = -8; cameraSDR.whitePoint = 9; cameraSDR.toneCurve = 0.12
        cameraSDR.curveSettings = .identity
        var cameraHDR = try cameraSDR.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        XCTAssertTrue(
            cameraHDR.hdr == HDRSettings() && cameraHDR.sharpening == 0.1 && cameraHDR.exposure == 1,
            "camera RAW HDR must start with an independent snapshot"
        )
        AdjustmentKind.exposure.setValue(3, in: &cameraHDR)
        XCTAssertEqual(cameraHDR.hdr?.processingVersion, 1, "ordinary HDR edit upgraded the tone version")
        AdjustmentKind.blackPoint.setValue(-25, in: &cameraHDR)
        AdjustmentKind.whitePoint.setValue(50, in: &cameraHDR)
        AdjustmentKind.toneCurve.setValue(30, in: &cameraHDR)
        XCTAssertTrue(
            AdjustmentKind.blackPoint.value(from: cameraHDR) == -25 &&
                AdjustmentKind.whitePoint.value(from: cameraHDR) == 50 &&
                AdjustmentKind.toneCurve.value(from: cameraHDR) == 30 &&
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
        let savedCamera = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(cameraHDR))
        XCTAssertEqual(savedCamera, cameraHDR, "HDR tone settings did not survive serialization")
        let resetTone = resetAll(cameraHDR)
        XCTAssertTrue(
            resetTone.hdr?.toneSettings.isDefault == true && resetTone.hdr?.processingVersion == 2 &&
                resetTone.blackPoint == -8 && resetTone.curveSettings == .identity,
            "HDR reset lost its version or changed dormant tone"
        )
        var hdrColor = cameraHDR
        AdjustmentKind.vibrance.setValue(35, in: &hdrColor)
        hdrColor.editingHSLSettings.set(.hue, channel: 2, value: 18)
        hdrColor.editingGradingSettings.midtones = .init(hue: 180, saturation: 21)
        XCTAssertTrue(
            hdrColor.hdr?.processingVersion == 3 && hdrColor.vibrance == 0 && hdrColor.hslSettings.isIdentity &&
                hdrColor.gradingSettings.isDefault && AdjustmentKind.hsl.progress(in: hdrColor) != 0,
            "HDR color controls changed dormant SDR state or progress used its values"
        )
        let resetColor = resetAll(hdrColor)
        XCTAssertTrue(
            resetColor.hdr?.colorSettings.isDefault == true && resetColor.hdr?.processingVersion == 3,
            "HDR reset retained color or changed processing version"
        )
        let cameraOff = try savedCamera.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let cameraOn = try cameraOff.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        XCTAssertTrue(
            !cameraOff.isHDREditing && cameraOff.exposure == 1 && cameraOn.hdr?.exposure == 3,
            "camera RAW mode switch or persisted edit lost either snapshot"
        )
        var sharpened = sdr; sharpened.sharpening = 0.1
        let hdrFromSharpened = try sharpened.withHDRMode(true, sourceIsHDR: true)
        let restoredSharpened = try hdrFromSharpened.withHDRMode(false, sourceIsHDR: true)
        XCTAssertTrue(
            hdrFromSharpened.isHDREditing && hdrFromSharpened.hdr?.detailSettings.sharpening == 0 &&
                restoredSharpened.sharpening == 0.1,
            "HDR switch did not preserve the SDR sharpening"
        )
        XCTAssertTrue(AdjustmentKind.temperature.progress(in: active) != 0, "HDR WB progress used inactive SDR values")
        var effect = RawSettings.default; effect.effectSettings.vignetteMidpoint = 60
        let hdrFromEffect = try effect.withHDRMode(true, sourceIsHDR: true)
        let restoredEffect = try hdrFromEffect.withHDRMode(false, sourceIsHDR: true)
        XCTAssertTrue(
            hdrFromEffect.isHDREditing && restoredEffect.effectSettings.vignetteMidpoint == 60,
            "HDR switch did not preserve the SDR effect"
        )
        let context = EditorAdjustmentContext(isRaw: false, defaultExposureMode: .sensor)
        var modeSource = RawSettings.default; modeSource.exposure = 1; modeSource.proRAWDecodeVersion = 2
        var modeHDR = try modeSource.withHDRMode(true, sourceIsHDR: true)
        AdjustmentKind.exposure.setValue(2, in: &modeHDR)
        let modeSDR = try modeHDR.withHDRMode(false, sourceIsHDR: true)
        var cleanSDR = modeSDR; cleanSDR.exposure = 0
        XCTAssertFalse(
            EditorAdjustmentRules.isModified(.all, snapshot: PhotoEditState(settings: cleanSDR), context: context),
            "dormant HDR marked clean normal mode modified"
        )
        guard case .candidate(let sdrCandidate, _) = EditorAdjustmentRules.prepareReset(
            .all,
            snapshot: PhotoEditState(settings: modeSDR),
            context: context
        ) else {
            XCTFail("normal reset all was not prepared")
            return
        }
        XCTAssertTrue(
            !sdrCandidate.settings.isHDREditing && sdrCandidate.settings.hdr == modeSDR.hdr &&
                sdrCandidate.settings.proRAWDecodeVersion == 2 && sdrCandidate.settings.exposure == 0,
            "normal reset all altered dormant HDR or decode version"
        )
        XCTAssertFalse(
            EditorAdjustmentRules.isModified(.all, snapshot: sdrCandidate, context: context),
            "normal reset all left the all marker set"
        )
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: sdrCandidate, context: context) {} else {
            XCTFail("normal reset all is not idempotent with dormant HDR")
        }
        guard case .candidate(let hdrCandidate, _) = EditorAdjustmentRules.prepareReset(
            .all,
            snapshot: PhotoEditState(settings: modeHDR),
            context: context
        ) else {
            XCTFail("HDR reset all was not prepared")
            return
        }
        XCTAssertTrue(
            hdrCandidate.settings.isHDREditing && hdrCandidate.settings.hdr?.isIdentity == true &&
                hdrCandidate.settings.exposure == 1 && hdrCandidate.settings.proRAWDecodeVersion == 2,
            "HDR reset all altered dormant SDR snapshot or decode version"
        )
        XCTAssertFalse(
            EditorAdjustmentRules.isModified(.all, snapshot: hdrCandidate, context: context),
            "HDR reset all left the all marker set despite dormant SDR"
        )
        if case .unchanged = EditorAdjustmentRules.prepareReset(.all, snapshot: hdrCandidate, context: context) {} else {
            XCTFail("HDR reset all is not idempotent with dormant SDR")
        }

        // Q5: HDR 显示映射（HDR 亮度上限 + SDR 底图曝光/对比度/饱和度）分组归属、显隐、单重置与重置全部隔离
        XCTAssertEqual(
            EditorAdjustmentRules.tools(.hdrRendition),
            [.hdrPeakLimit, .hdrSDRExposure, .hdrSDRContrast, .hdrSDRSaturation],
            "HDR rendition group did not own the exact four display-mapping tools"
        )
        XCTAssertTrue(
            EditorAdjustmentGroup.visibleGroups(isHDREditing: false) == [.looks, .light, .color, .effects, .detail, .geometry] &&
                !EditorAdjustmentGroup.visibleGroups(isHDREditing: false).contains(.hdrRendition),
            "SDR mode exposed hdrRendition"
        )
        XCTAssertEqual(
            EditorAdjustmentGroup.visibleGroups(isHDREditing: true),
            EditorAdjustmentGroup.allCases,
            "HDR mode did not expose all seven groups including hdrRendition"
        )
        for tool in EditorAdjustmentRules.tools(.hdrRendition) {
            XCTAssertEqual(
                EditorAdjustmentRules.normalizedTool(tool, isHDREditing: true),
                tool,
                "HDR mode did not retain \(tool)"
            )
            XCTAssertTrue(
                EditorAdjustmentRules.normalizedTool(tool, isHDREditing: false) == .adjustment(.exposure) &&
                    EditorAdjustmentRules.groupFor(EditorAdjustmentRules.normalizedTool(tool, isHDREditing: false)) != .hdrRendition,
                "SDR normalization did not exit hdrRendition from \(tool)"
            )
        }

        var renditionHDR = try sdr.withHDRMode(true, sourceIsHDR: false, cameraRAW: true)
        AdjustmentKind.exposure.setValue(1.5, in: &renditionHDR)
        renditionHDR.hdr?.cameraDevelopmentSettings.fbddLevel = 2
        let untouchedRendition = PhotoEditState(settings: renditionHDR, filmID: "dormant-look")
        XCTAssertTrue(
            !EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: untouchedRendition, context: context) &&
                EditorAdjustmentRules.tools(.hdrRendition).allSatisfy { !EditorAdjustmentRules.isModified(.tool($0), snapshot: untouchedRendition, context: context) },
            "Untouched HDR rendition or camera development falsely marked HDR rendition modified"
        )
        if case .unchanged = EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: untouchedRendition, context: context),
           renditionHDR.hdr?.processingVersion == 1 {} else {
            XCTFail("No-op HDR rendition group reset mutated version or returned a candidate")
        }

        var fullRendition = HDRRenditionSettings()
        fullRendition.peakLimitEV = 2.4
        fullRendition.sdrExposureEV = -1.2
        fullRendition.sdrContrast = 35
        fullRendition.sdrSaturation = -25
        renditionHDR.hdr?.renditionSettings = fullRendition
        let renditionSnapshot = PhotoEditState(settings: renditionHDR, filmID: "dormant-look")
        XCTAssertEqual(renditionHDR.hdr?.processingVersion, 4, "HDR rendition edit did not upgrade processingVersion to 4")
        XCTAssertTrue(
            EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: renditionSnapshot, context: context) &&
                EditorAdjustmentRules.tools(.hdrRendition).allSatisfy { EditorAdjustmentRules.isModified(.tool($0), snapshot: renditionSnapshot, context: context) },
            "Modified HDR rendition fields did not mark group and tools modified"
        )

        for (tool, keyPath) in [
            (EditorToolSelection.hdrPeakLimit, \HDRRenditionSettings.peakLimitEV),
            (.hdrSDRExposure, \.sdrExposureEV),
            (.hdrSDRContrast, \.sdrContrast),
            (.hdrSDRSaturation, \.sdrSaturation),
        ] {
            guard case .candidate(let singleReset, let singleRequiresConfirmation) =
                    EditorAdjustmentRules.prepareReset(.tool(tool), snapshot: renditionSnapshot, context: context) else {
                XCTFail("Single HDR rendition tool reset was not prepared for \(tool)")
                return
            }
            XCTAssertFalse(singleRequiresConfirmation, "Single HDR rendition tool reset for \(tool) skips confirmation")
            var expectedRendition = fullRendition
            expectedRendition[keyPath: keyPath] = 0
            XCTAssertEqual(
                singleReset.settings.hdr?.renditionSettings,
                expectedRendition,
                "Single HDR rendition reset for \(tool) mutated sibling rendition fields"
            )
            XCTAssertTrue(
                !EditorAdjustmentRules.isModified(.tool(tool), snapshot: singleReset, context: context) &&
                    EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: singleReset, context: context),
                "Single HDR rendition reset for \(tool) left wrong modified state"
            )
            XCTAssertTrue(
                singleReset.settings.hdr?.exposure == 1.5 &&
                    singleReset.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
                    singleReset.settings.exposure == sdr.exposure && singleReset.filmID == "dormant-look",
                "Single HDR rendition reset touched other HDR groups, camera development, or dormant SDR"
            )
        }

        guard case .candidate(let groupReset, let groupRequiresConfirmation) =
                EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: renditionSnapshot, context: context) else {
            XCTFail("HDR rendition group reset was not prepared")
            return
        }
        XCTAssertTrue(groupRequiresConfirmation, "HDR rendition group reset requires confirmation aligned with Mac")
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
        if case .unchanged = EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: groupReset, context: context),
           !EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: groupReset, context: context) {} else {
            XCTFail("HDR rendition group reset was not idempotent")
        }

        let dormantRenditionSDR = try renditionHDR.withHDRMode(false, sourceIsHDR: false, cameraRAW: true)
        let dormantSnapshot = PhotoEditState(settings: dormantRenditionSDR, filmID: "dormant-look")
        if case .unchanged = EditorAdjustmentRules.prepareReset(.group(.hdrRendition), snapshot: dormantSnapshot, context: context),
           !EditorAdjustmentRules.isModified(.group(.hdrRendition), snapshot: dormantSnapshot, context: context),
           EditorAdjustmentRules.tools(.hdrRendition).allSatisfy({
               guard case .unchanged = EditorAdjustmentRules.prepareReset(.tool($0), snapshot: dormantSnapshot, context: context) else { return false }
               return !EditorAdjustmentRules.isModified(.tool($0), snapshot: dormantSnapshot, context: context)
           }) {} else {
            XCTFail("Dormant HDR rendition was exposed or resettable in ordinary SDR mode")
        }
        guard case .candidate(let sdrResetAll, _) = EditorAdjustmentRules.prepareReset(.all, snapshot: dormantSnapshot, context: context) else {
            XCTFail("Ordinary SDR reset-all with dormant HDR rendition was not prepared")
            return
        }
        XCTAssertTrue(
            sdrResetAll.settings.hdr?.renditionSettings == fullRendition &&
                sdrResetAll.settings.hdr?.cameraDevelopmentSettings.fbddLevel == 2 &&
                !sdrResetAll.settings.isHDREditing && sdrResetAll.settings.exposure == 0,
            "Ordinary SDR reset-all mutated dormant HDR rendition or camera development"
        )
        guard case .candidate(let hdrResetAll, let allRequiresConfirmation) =
                EditorAdjustmentRules.prepareReset(.all, snapshot: renditionSnapshot, context: context) else {
            XCTFail("HDR reset-all with rendition edits was not prepared")
            return
        }
        XCTAssertTrue(allRequiresConfirmation, "HDR reset-all requires confirmation aligned with Mac")
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
        var settings = RawSettings.default; settings.hdr = HDRSettings(); settings.hdr?.exposure = 1
        settings.hdr?.temperature = 10000; settings.denoise.enabled = true
        let source = PhotoEditState(settings: settings, filmID: nil)
        let context = IOSAdjustmentTransferContext(identifier: "source", isRaw: false, sourceIsHDR: true)
        let payload = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: source, context: context)
        XCTAssertTrue(payload.source.isHDR && payload.payloadVersion == 2, "HDR capture used legacy fields")
        var targetSettings = RawSettings.default; targetSettings.exposure = -2; targetSettings.hdr = HDRSettings()
        let target = PhotoEditState(settings: targetSettings, filmID: nil)
        let prepared = try IOSAdjustmentTransfer.prepare(payload: payload, target: target, context: context)
        XCTAssertTrue(
            prepared.settings.hdr?.exposure == 1 && prepared.settings.exposure == -2 && prepared.settings.isHDREditing,
            "HDR target lost its dormant SDR snapshot or mode"
        )
        var sdrSettings = target.settings; sdrSettings.hdr = nil
        let sdr = target.replacing(settings: sdrSettings, preservingFilmID: target.filmID)
        do {
            _ = try IOSAdjustmentTransfer.prepare(payload: payload, target: sdr, context: context)
            XCTFail("relative WB reached SDR target")
        } catch AdjustmentTransferError.incompatible {}
        let common = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: source, context: context)
        let legacy = try IOSAdjustmentTransfer.prepare(payload: common, target: sdr, context: context)
        XCTAssertTrue(legacy.settings.hdr == nil && legacy.settings.exposure == 1, "copy silently switched target mode")

        let proRAWContext = IOSAdjustmentTransferContext(
            identifier: "proraw",
            isRaw: true,
            sourceSupportsCameraHDR: true
        )
        let proRAWPayload = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: source, context: proRAWContext)
        var proRAWTargetSettings = RawSettings.default; proRAWTargetSettings.hdr = HDRSettings()
        let proRAWTarget = PhotoEditState(settings: proRAWTargetSettings, filmID: nil)
        let proRAWPrepared = try IOSAdjustmentTransfer.prepare(
            payload: proRAWPayload,
            target: proRAWTarget,
            context: proRAWContext
        )
        XCTAssertTrue(
            proRAWPrepared.settings.hdr?.exposure == 1 && proRAWPrepared.settings.isHDREditing,
            "ProRAW HDR target rejected a valid HDR payload"
        )
        do {
            _ = try IOSAdjustmentTransfer.prepare(payload: proRAWPayload, target: sdr, context: proRAWContext)
            XCTFail("non-neutral ProRAW HDR white balance reached an SDR target")
        } catch AdjustmentTransferError.incompatible {}
        let proRAWSDR = try IOSAdjustmentTransfer.prepare(payload: common, target: sdr, context: proRAWContext)
        XCTAssertTrue(proRAWSDR.settings.hdr == nil && proRAWSDR.settings.exposure == 1, "ProRAW HDR transfer upgraded an SDR target")
        let cameraContext = IOSAdjustmentTransferContext(identifier: "camera", isRaw: true, sourceSupportsCameraHDR: true)
        var cameraSettings = settings
        cameraSettings.hdr?.renditionSettings.sdrExposureEV = -0.75
        let cameraPayload = try IOSAdjustmentTransfer.capture(
            scope: .modified,
            snapshot: PhotoEditState(settings: cameraSettings, filmID: nil),
            context: cameraContext
        )
        let cameraTarget = try IOSAdjustmentTransfer.prepare(payload: cameraPayload, target: target, context: cameraContext)
        XCTAssertTrue(
            cameraTarget.settings.hdr == cameraSettings.hdr && cameraTarget.settings.exposure == -2 &&
                cameraTarget.settings.proRAWDecodeVersion == nil,
            "Camera RAW transfer lost either edit or invented a ProRAW version"
        )
        do {
            _ = try IOSAdjustmentTransfer.capture(
                scope: .all,
                snapshot: source,
                context: IOSAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true)
            )
            XCTFail("RAW without HDR capability was accepted as a source")
        } catch AdjustmentTransferError.incompatible {}
        do {
            _ = try IOSAdjustmentTransfer.prepare(
                payload: proRAWPayload,
                target: proRAWTarget,
                context: IOSAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true)
            )
            XCTFail("RAW without HDR capability was accepted as a target")
        } catch AdjustmentTransferError.incompatible {}
    }
}
