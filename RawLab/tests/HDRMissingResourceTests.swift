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
            let before = try store.versionedState(for: identity)
            let model = RawEditorViewModel(editPersistence: store)
            let source: PhotoImportSource = profile
                ? .raw(URL(fileURLWithPath: ProcessInfo.processInfo.environment["RAWLAB_TEST_CAMERA_RAW"]!)) : .raster(input)
            model.importImage(from: source, identity: identity)
            wait { !model.isBusy }
            check(model.hasImage && model.hdrPresentation != nil && model.currentPreviewSettings == saved,
                  "Missing HDR resource blocked import or rewrote saved settings")
            check(model.statusMessage != nil && !model.previewFailed, "Missing HDR resource was not explained")
            let after = try store.versionedState(for: identity)
            check(before == after, "Preview recovery changed the saved edit record")
            var cleared = saved
            cleared.hdr?.lookSettings = HDRLookSettings()
            cleared.hdr?.cameraDevelopmentSettings.cameraProfile = nil
            check(model.isLookAvailable(for: cleared), "Cleared HDR resources still block export")
            model.retryPreview(settings: cleared)
            wait { !model.previewRendering }
            check(!model.previewFailed && model.hdrPresentation != nil && model.statusMessage == nil,
                  "Clearing missing HDR resources did not restore the preview")
        }
        print("PASS iOS HDR import preserves missing resource references and allows clearing")
    }
}
