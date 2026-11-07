import Foundation

@main enum HDRTransferAdapterTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        var settings = Adjustments(); settings.hdr = HDRSettings(); settings.hdr?.exposure = 1
        settings.hdr?.temperature = 10000; settings.aiDenoiseEnabled = true
        let source = PhotoEditState(settings: settings, filmID: "")
        let context = MacAdjustmentTransferContext(identifier: "source", isRaw: false, sourceIsHDR: true)
        let payload = try MacAdjustmentTransfer.capture(scope: .all, snapshot: source, context: context)
        check(payload.source.isHDR && payload.payloadVersion == 2, "HDR capture used legacy fields")
        var targetSettings = Adjustments(); targetSettings.exposure = -2; targetSettings.hdr = HDRSettings()
        let target = PhotoEditState(settings: targetSettings, filmID: "")
        let prepared = try MacAdjustmentTransfer.prepare(payload: payload, target: target, context: context)
        check(prepared.settings.hdr?.exposure == 1 && prepared.settings.exposure == -2 && prepared.settings.isHDREditing,
            "HDR target lost its dormant SDR snapshot or mode")
        var sdr = target; sdr.settings.hdr = nil
        do { _ = try MacAdjustmentTransfer.prepare(payload: payload, target: sdr, context: context); fatalError("relative WB reached SDR target") }
        catch AdjustmentTransferError.incompatible {}
        let common = try MacAdjustmentTransfer.capture(scope: .custom([.exposure]), snapshot: source, context: context)
        let legacy = try MacAdjustmentTransfer.prepare(payload: common, target: sdr, context: context)
        check(legacy.settings.hdr == nil && legacy.settings.exposure == 1, "copy silently switched target mode")

        let proRAWContext = MacAdjustmentTransferContext(identifier: "proraw", isRaw: true,
            sourceSupportsCameraHDR: true)
        let proRAWPayload = try MacAdjustmentTransfer.capture(scope: .all, snapshot: source, context: proRAWContext)
        var proRAWTargetSettings = Adjustments(); proRAWTargetSettings.hdr = HDRSettings()
        let proRAWTarget = PhotoEditState(settings: proRAWTargetSettings, filmID: "")
        let proRAWPrepared = try MacAdjustmentTransfer.prepare(payload: proRAWPayload,
            target: proRAWTarget, context: proRAWContext)
        check(proRAWPrepared.settings.hdr?.exposure == 1 && proRAWPrepared.settings.isHDREditing,
              "ProRAW HDR target rejected a valid HDR payload")
        do {
            _ = try MacAdjustmentTransfer.prepare(payload: proRAWPayload, target: sdr, context: proRAWContext)
            fatalError("non-neutral ProRAW HDR white balance reached an SDR target")
        } catch AdjustmentTransferError.incompatible {}
        let proRAWSDR = try MacAdjustmentTransfer.prepare(payload: common, target: sdr, context: proRAWContext)
        check(proRAWSDR.settings.hdr == nil && proRAWSDR.settings.exposure == 1,
              "ProRAW HDR transfer upgraded an SDR target")
        let cameraContext = MacAdjustmentTransferContext(identifier: "camera", isRaw: true, sourceSupportsCameraHDR: true)
        var cameraSettings = settings
        cameraSettings.hdr?.renditionSettings.sdrExposureEV = -0.75
        let cameraPayload = try MacAdjustmentTransfer.capture(scope: .modified,
            snapshot: PhotoEditState(settings: cameraSettings, filmID: ""), context: cameraContext)
        let cameraTarget = try MacAdjustmentTransfer.prepare(payload: cameraPayload, target: target, context: cameraContext)
        check(cameraTarget.settings.hdr == cameraSettings.hdr && cameraTarget.settings.exposure == -2 &&
              cameraTarget.settings.proRAWDecodeVersion == nil, "Camera RAW transfer lost either edit or invented a ProRAW version")
        do {
            _ = try MacAdjustmentTransfer.capture(scope: .all, snapshot: source,
                context: MacAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true))
            fatalError("RAW without HDR capability was accepted as a source")
        } catch AdjustmentTransferError.incompatible {}
        do {
            _ = try MacAdjustmentTransfer.prepare(payload: proRAWPayload, target: proRAWTarget,
                context: MacAdjustmentTransferContext(identifier: "raw", isRaw: true, sourceIsHDR: true))
            fatalError("RAW without HDR capability was accepted as a target")
        } catch AdjustmentTransferError.incompatible {}
        print("PASS Mac HDR transfer capture, target preflight and mixed-mode isolation")
    }
}
