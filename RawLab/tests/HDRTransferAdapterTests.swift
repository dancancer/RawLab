import Foundation

@main enum HDRTransferAdapterTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        var settings = RawSettings.default; settings.hdr = HDRSettings(); settings.hdr?.exposure = 1
        settings.hdr?.temperature = 10000; settings.denoise.enabled = true
        let source = PhotoEditState(settings: settings, filmID: nil)
        let context = IOSAdjustmentTransferContext(identifier: "source", isRaw: false, sourceIsHDR: true)
        let payload = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: source, context: context)
        check(payload.source.isHDR && payload.payloadVersion == 2, "HDR capture used legacy fields")
        var targetSettings = RawSettings.default; targetSettings.exposure = -2; targetSettings.hdr = HDRSettings()
        let target = PhotoEditState(settings: targetSettings, filmID: nil)
        let prepared = try IOSAdjustmentTransfer.prepare(payload: payload, target: target, context: context)
        check(prepared.settings.hdr?.exposure == 1 && prepared.settings.exposure == -2 && prepared.settings.isHDREditing,
            "HDR target lost its dormant SDR snapshot or mode")
        var sdrSettings = target.settings; sdrSettings.hdr = nil
        let sdr = target.replacing(settings: sdrSettings, preservingFilmID: target.filmID)
        do { _ = try IOSAdjustmentTransfer.prepare(payload: payload, target: sdr, context: context); fatalError("relative WB reached SDR target") }
        catch AdjustmentTransferError.incompatible {}
        let common = try IOSAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: source, context: context)
        let legacy = try IOSAdjustmentTransfer.prepare(payload: common, target: sdr, context: context)
        check(legacy.settings.hdr == nil && legacy.settings.exposure == 1, "copy silently switched target mode")
        print("PASS iOS HDR transfer capture, target preflight and mixed-mode isolation")
    }
}
