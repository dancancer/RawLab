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

        let proRAWContext = IOSAdjustmentTransferContext(identifier: "proraw", isRaw: true,
            sourceSupportsProRAWHDR: true)
        let proRAWPayload = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: source, context: proRAWContext)
        var proRAWTargetSettings = RawSettings.default; proRAWTargetSettings.hdr = HDRSettings()
        let proRAWTarget = PhotoEditState(settings: proRAWTargetSettings, filmID: nil)
        let proRAWPrepared = try IOSAdjustmentTransfer.prepare(payload: proRAWPayload,
            target: proRAWTarget, context: proRAWContext)
        check(proRAWPrepared.settings.hdr?.exposure == 1 && proRAWPrepared.settings.isHDREditing,
              "ProRAW HDR target rejected a valid HDR payload")
        do {
            _ = try IOSAdjustmentTransfer.prepare(payload: proRAWPayload, target: sdr, context: proRAWContext)
            fatalError("non-neutral ProRAW HDR white balance reached an SDR target")
        } catch AdjustmentTransferError.incompatible {}
        let proRAWSDR = try IOSAdjustmentTransfer.prepare(payload: common, target: sdr, context: proRAWContext)
        check(proRAWSDR.settings.hdr == nil && proRAWSDR.settings.exposure == 1,
              "ProRAW HDR transfer upgraded an SDR target")
        do {
            _ = try IOSAdjustmentTransfer.capture(scope: .all, snapshot: source,
                context: IOSAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true))
            fatalError("ordinary RAW HDR capture was accepted")
        } catch AdjustmentTransferError.incompatible {}
        do {
            _ = try IOSAdjustmentTransfer.prepare(payload: proRAWPayload, target: proRAWTarget,
                context: IOSAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true))
            fatalError("ordinary RAW HDR target was accepted")
        } catch AdjustmentTransferError.incompatible {}
        print("PASS iOS HDR transfer capture, target preflight and mixed-mode isolation")
    }
}
