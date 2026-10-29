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
