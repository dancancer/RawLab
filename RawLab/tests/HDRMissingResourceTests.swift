import Foundation
import UIKit

@main enum HDRMissingResourceTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func wait(_ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(ready(), "HDR resource recovery timed out")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let store = try EditPersistence(directory: root.appendingPathComponent("missing-resource-edits"))
        for profile in [false, true] {
            let identity = PhotoIdentity(resourceIdentifier: "missing-hdr-\(profile)")
            var saved = RawSettings.default; saved.hdr = HDRSettings()
            if profile {
                saved.hdr?.cameraDevelopmentSettings.cameraProfile = HDRCameraProfile(
                    sha256: String(repeating: "f", count: 64), name: "Missing profile")
            } else {
                saved.hdr?.lookSettings = HDRLookSettings(sha256: String(repeating: "e", count: 64), name: "Missing look", strength: 1)
            }
            try store.save(identity, state: PhotoEditState(settings: saved))
            let gateModel = RawEditorViewModel(editPersistence: store)
            check(!gateModel.isLookAvailable(for: saved), "Missing HDR resources must block export")
            let before = try store.readState(for: identity)
            let model = RawEditorViewModel(editPersistence: store)
            let source: PhotoImportSource = profile
                ? .raw(URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWLAB_TEST_CAMERA_RAW"]!)) : .raster(input)
            model.importImage(from: source, identity: identity)
            wait { !model.isBusy }
            check(model.hasImage && model.hdrPresentation != nil && model.currentPreviewSettings == saved,
                  "Missing HDR resource blocked import or rewrote saved settings")
            check(model.statusMessage != nil && !model.previewFailed, "Missing HDR resource was not explained")
            let after = try store.readState(for: identity)
            check(before == after, "Preview recovery changed the saved edit record")
            check(model.hdrResourceNotice.message != nil &&
                  model.hdrResourceNotice.message == saved.hdr?.missingResourceMessage,
                  "HDR import delivery records the warning it already showed")
            if profile {
                // 同照片 HDR → SDR → HDR 交付转换（缺 cameraProfile 不触发 look 门禁）。
                var sdr = saved
                sdr.hdr?.mode = .sdr
                model.updatePreview(settings: sdr)
                wait { !model.previewRendering }
                check(model.hdrResourceNotice.message == nil && model.statusMessage == nil,
                      "Switching the same RAW photo to the SDR preview resets the notice cache and withdraws the warning")
                model.updatePreview(settings: saved)
                wait { !model.previewRendering }
                check(model.hdrResourceNotice.message == saved.hdr?.missingResourceMessage &&
                      model.statusMessage == saved.hdr?.missingResourceMessage,
                      "Re-enabling HDR editing on the same photo shows the missing-resource warning again")
            }
            var cleared = saved
            cleared.hdr?.lookSettings = HDRLookSettings()
            cleared.hdr?.cameraDevelopmentSettings.cameraProfile = nil
            check(model.isLookAvailable(for: cleared), "Cleared HDR resources still block export")
            model.retryPreview(settings: cleared)
            wait { !model.previewRendering }
            check(!model.previewFailed && model.hdrPresentation != nil && model.statusMessage == nil,
                  "Clearing missing HDR resources did not restore the preview")
            if profile {
                model.updatePreview(settings: saved)
                wait { !model.previewRendering }
                check(model.hdrResourceNotice.message != nil, "HDR frames re-record the warning after resource recovery cleared it")
                model.importImage(from: source, identity: PhotoIdentity(resourceIdentifier: "sdr-reset-\(profile)"))
                wait { !model.isBusy }
                check(model.hdrResourceNotice.message == nil, "SDR photo import delivery resets the HDR resource notice cache")
            }
        }
        let rasterIdentity = PhotoIdentity(resourceIdentifier: "sdr-toggle-raster")
        var rasterSettings = RawSettings.default
        rasterSettings.hdr = HDRSettings()
        rasterSettings.hdr?.cameraDevelopmentSettings.cameraProfile = HDRCameraProfile(sha256: String(repeating: "a", count: 64), name: "Missing profile")
        try store.save(rasterIdentity, state: PhotoEditState(settings: rasterSettings))
        let rasterModel = RawEditorViewModel(editPersistence: store)
        rasterModel.importImage(from: .raster(input), identity: rasterIdentity)
        wait { !rasterModel.isBusy }
        check(rasterModel.hasImage && rasterModel.hdrResourceNotice.message != nil &&
              rasterModel.hdrResourceNotice.message == rasterSettings.hdr?.missingResourceMessage,
              "Raster HDR import delivery records the missing-profile warning")
        var rasterSDR = rasterSettings
        rasterSDR.hdr?.mode = .sdr
        rasterModel.updatePreview(settings: rasterSDR)
        wait { !rasterModel.previewRendering }
        check(rasterModel.hdrResourceNotice.message == nil && rasterModel.statusMessage == nil,
              "Raster SDR preview delivery resets the notice cache and withdraws the warning")
        rasterModel.updatePreview(settings: rasterSettings)
        wait { !rasterModel.previewRendering }
        check(rasterModel.hdrResourceNotice.message == rasterSettings.hdr?.missingResourceMessage &&
              rasterModel.statusMessage == rasterSettings.hdr?.missingResourceMessage,
              "Re-enabling HDR editing on the raster photo shows the missing-profile warning again")
        // 预存 SDR 模式记录，让重导入真实走 raster SDR 交付分支（rasterHDR && state == nil 才默认进 HDR）。
        try store.save(PhotoIdentity(resourceIdentifier: "sdr-reset-raster"), state: PhotoEditState(settings: rasterSDR))
        rasterModel.importImage(from: .raster(input), identity: PhotoIdentity(resourceIdentifier: "sdr-reset-raster"))
        wait { !rasterModel.isBusy }
        check(rasterModel.hdrResourceNotice.message == nil && !rasterModel.currentPreviewSettings.isHDREditing,
              "Raster SDR import delivery resets the HDR resource notice cache")
        print("PASS iOS HDR import preserves missing resource references and allows clearing")
    }
}
