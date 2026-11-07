import Foundation

@main enum HDRModelTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        let legacy = try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8))
        check(legacy.hdr == nil && !legacy.isHDREditing && legacy.processing == .legacy, "legacy record changed mode or processing")
        var sdr = RawSettings.default; sdr.exposure = 1; sdr.contrast = 0.75; sdr.highlights = -0.5
        var active = try sdr.withHDRMode(true, sourceIsHDR: true, hasLook: false)
        check(active.hdr?.exposure == 1 && active.hdr?.contrast == -25 && active.hdr?.highlights == 50, "conversion lost UI scale/direction")
        AdjustmentKind.exposure.setValue(2, in: &active)
        AdjustmentKind.temperature.setValue(10000, in: &active)
        check(AdjustmentKind.exposure.value(from: active) == 2 && active.hdr?.temperature == 10000, "HDR controls did not use active snapshot")
        check(active.exposure == 1 && active.temperature == 6500, "HDR control mutated dormant SDR data")
        let data = try JSONEncoder().encode(active)
        let restored = try JSONDecoder().decode(RawSettings.self, from: data)
        check(restored == active, "HDR record did not round-trip")
        let disabled = try restored.withHDRMode(false, sourceIsHDR: true, hasLook: false)
        check(!disabled.isHDREditing && disabled.exposure == 1 && disabled.hdr?.exposure == 2, "SDR restore lost either snapshot")
        let reenabled = try disabled.withHDRMode(true, sourceIsHDR: true, hasLook: true)
        check(reenabled.hdr?.exposure == 2, "existing HDR snapshot was rebuilt")
        let reset = reenabled.resettingAdjustments()
        check(reset.isHDREditing && reset.hdr?.isIdentity == true && reset.exposure == 1, "reset changed mode or dormant SDR edit")
        var cameraSDR = sdr
        cameraSDR.sharpening = 0.1
        cameraSDR.blackPoint = -8; cameraSDR.whitePoint = 9; cameraSDR.toneCurve = 0.12
        cameraSDR.curveSettings = .identity
        var cameraHDR = try cameraSDR.withHDRMode(true, sourceIsHDR: false, hasLook: true, cameraRAW: true)
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
        let resetTone = cameraHDR.resettingAdjustments()
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
        let resetColor = hdrColor.resettingAdjustments()
        check(resetColor.hdr?.colorSettings.isDefault == true && resetColor.hdr?.processingVersion == 3,
              "HDR reset retained color or changed processing version")
        let cameraOff = try savedCamera.withHDRMode(false, sourceIsHDR: false, hasLook: true, cameraRAW: true)
        let cameraOn = try cameraOff.withHDRMode(true, sourceIsHDR: false, hasLook: true, cameraRAW: true)
        check(!cameraOff.isHDREditing && cameraOff.exposure == 1 && cameraOn.hdr?.exposure == 3,
              "camera RAW mode switch or persisted edit lost either snapshot")
        var conflict = sdr; conflict.sharpening = 0.1
        do { _ = try conflict.withHDRMode(true, sourceIsHDR: true, hasLook: false); fatalError("unsupported control accepted") }
        catch HDRSettings.ModeError.conflicts(let fields) { check(fields.contains("sharpening"), "conflict field missing") }
        check(conflict.hdr == nil && conflict.sharpening == 0.1, "failed conversion changed state")
        check(AdjustmentKind.temperature.progress(in:active) != 0,"HDR WB progress used inactive SDR values")
        var effect=RawSettings.default; effect.photoEffects.vignetteMidpoint=60
        do { _ = try effect.withHDRMode(true,sourceIsHDR:true,hasLook:false); fatalError("nonidentity effect settings converted") }
        catch HDRSettings.ModeError.conflicts(let fields) { check(fields.contains("effects"),"effect conflict missing") }
        print("PASS iOS HDR legacy, record, conversion, control routing and reset")
    }
}
