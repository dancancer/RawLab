import Foundation
import UIKit

@main
struct ViewportStateTests {
    static func settle(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func checkDNGResize(directory: URL, succeeds: Bool) throws -> Bool {
        let imageURL = directory.appendingPathComponent("resize-source.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
        try image.jpegData(compressionQuality: 0.9)!.write(to: imageURL)
        let model = RawEditorViewModel(editPersistence: try EditPersistence(directory: directory.appendingPathComponent(UUID().uuidString)))
        model.hasImage = true
        model.sourceKind = .raster
        model.sourceURL = imageURL
        let buffer = try model.processor.loadRasterBuffer(url: imageURL).buffer
        model.draftBuffer = succeeds ? buffer : nil
        model.draftPreviewBuffer = buffer
        var settings = RawSettings.default
        settings.denoise.apply(.clean)
        var completed = false, expectedResult = false
        model.exportDNG(settings: settings, longEdge: 64) { result in
            switch result {
            case .success(let output):
                expectedResult = succeeds && FileManager.default.fileExists(atPath: output.path)
                try? FileManager.default.removeItem(at: output)
            case .failure:
                expectedResult = !succeeds
            }
            completed = true
        }
        precondition(model.isBusy)
        model.updatePreviewSize(1216, settings: settings)
        settings.exposure = 0.5
        model.updatePreviewSize(896, settings: settings)
        precondition(model.requestedPreviewLongEdge == 896 && model.previewLongEdge == 1280)
        let deadline = Date().addingTimeInterval(10)
        while !completed && Date() < deadline { settle(0.01) }
        settle()
        let passed = completed && expectedResult && !model.isBusy && !model.previewResizePending &&
            model.previewLongEdge == 896 && model.lastPreviewRequest?.settings.exposure == 0.5
        print("\(passed ? "PASS" : "FAIL"): DNG \(succeeds ? "success" : "failure") replays busy resize and latest settings")
        return passed
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("edits")
        let model = RawEditorViewModel(editPersistence: try EditPersistence(directory: directory))
        model.hasImage = true
        var settings = RawSettings.default
        settings.denoise.apply(.clean)
        model.isBusy = true
        model.updatePreviewSize(1216, settings: settings)
        precondition(model.requestedPreviewLongEdge == 1216 && model.previewLongEdge == 1280)
        model.isBusy = false
        model.updatePreviewSize(model.requestedPreviewLongEdge, settings: model.currentPreviewSettings)
        precondition(model.previewResizePending)
        model.updatePreviewSize(768, settings: settings)
        settings.exposure = 0.5
        model.updatePreview(settings: settings)
        precondition(model.previewLongEdge == 1280)
        settle()
        precondition(model.previewLongEdge == 768 && !model.previewResizePending && !model.previewRendering)
        precondition(model.lastPreviewRequest?.settings.exposure == 0.5)
        model.updatePreviewSize(640, settings: settings)
        model.updatePreviewSize(768, settings: settings)
        precondition(!model.previewResizePending)
        settle()
        precondition(model.previewLongEdge == 768)
        model.updatePreviewSize(512, settings: settings)
        settings.denoise.enabled = false
        model.updatePreview(settings: settings)
        precondition(model.previewLongEdge == 512 && !model.previewResizePending)
        settle()
        precondition(!model.previewRendering)
        print("PASS: busy resize replay, quiet resize, latest edits, cancellation, disable denoise")
        let output = directory.deletingLastPathComponent()
        let successReplay = try checkDNGResize(directory: output, succeeds: true)
        let failureReplay = try checkDNGResize(directory: output, succeeds: false)
        if !successReplay || !failureReplay { exit(1) }
    }
}
