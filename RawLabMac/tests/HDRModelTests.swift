import Foundation

@main enum HDRModelTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        let legacy = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        check(legacy.hdr == nil && !legacy.isHDREditing && legacy.processing == .legacy, "legacy record changed mode or processing")
        var sdr = Adjustments(); sdr.exposure = 1; sdr.contrast = -25; sdr.highlights = 50
        var active = try sdr.withHDRMode(true, sourceIsHDR: true, hasLook: false)
        check(active.hdr?.exposure == 1 && active.hdr?.contrast == -25 && active.hdr?.highlights == 50, "conversion lost logical values")
        active.set(.exposure, to: 2); active.set(.temperature, to: 10000)
        active.rotateGeometry(clockwise: true)
        check(AdjustmentParameter.exposure.value(from: active) == 2 && active.hdr?.temperature == 10000 && active.hdr?.geometry.quarterTurns == 1,
            "HDR controls did not use the active snapshot")
        check(active.exposure == 1 && active.temperature == 6500 && active.geometry == nil, "HDR control mutated dormant SDR data")
        let data = try JSONEncoder().encode(active)
        let restored = try JSONDecoder().decode(Adjustments.self, from: data)
        check(restored == active, "HDR record did not round-trip")
        let disabled = try restored.withHDRMode(false, sourceIsHDR: true, hasLook: false)
        check(!disabled.isHDREditing && disabled.exposure == 1 && disabled.hdr?.exposure == 2, "SDR restore lost either snapshot")
        let reenabled = try disabled.withHDRMode(true, sourceIsHDR: true, hasLook: true)
        check(reenabled.hdr?.exposure == 2, "existing HDR snapshot was rebuilt")
        var reset = reenabled; reset.resetAll()
        check(reset.isHDREditing && reset.hdr?.isIdentity == true && reset.exposure == 1, "reset changed mode or dormant SDR edit")
        var conflict = sdr; conflict.sharpening = 10
        do { _ = try conflict.withHDRMode(true, sourceIsHDR: true, hasLook: false); fatalError("unsupported control accepted") }
        catch HDRSettings.ModeError.conflicts(let fields) { check(fields.contains("sharpening"), "conflict field missing") }
        check(conflict.hdr == nil && conflict.sharpening == 10, "failed conversion changed state")
        let context=EditorAdjustmentContext(isRaw:false,defaultExposureMode:.sensor,neutralFilmID:"")
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
        do { _ = try effect.withHDRMode(true,sourceIsHDR:true,hasLook:false); fatalError("nonidentity effect settings converted") }
        catch HDRSettings.ModeError.conflicts(let fields) { check(fields.contains("effects"),"effect conflict missing") }
        print("PASS Mac HDR legacy, record, conversion, control routing and reset")
    }
}
