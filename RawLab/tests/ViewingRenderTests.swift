import Foundation
import UIKit

@main
struct ViewingRenderTests {
    static func wait(_ model: RawEditorViewModel) {
        let deadline = Date().addingTimeInterval(8)
        while model.previewRendering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func check(_ condition: Bool, _ message: String = "contract", line: Int = #line) {
        if !condition { print("FAIL line \(line): \(message)"); exit(1) }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            UIColor.blue.setFill(); context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        }
        let url = out.appendingPathComponent("source.png")
        try image.pngData()!.write(to: url)
        let model = RawEditorViewModel(editPersistence: try EditPersistence(directory: out.appendingPathComponent("edits")))
        model.hasImage = true
        model.sourceKind = .raster
        model.sourceFile = .externallyManaged(url)
        model.updatePreview(settings: .default, includeHistogram: false)
        wait(model)
        let buffer = try model.processor.loadRasterBuffer(url: url).buffer
        model.draftBuffer = buffer
        model.updatePreview(settings: .default, includeHistogram: false)
        wait(model)
        guard model.previewImage != nil else {
            print("FAIL: retrying identical settings after unavailable input must produce a frame; duplicate failed request was suppressed")
            exit(1)
        }
        print("PASS: identical failed preview can retry without changing edit settings")
        var committed = RawSettings.default
        committed.geometry.cropWidth = 0.75
        model.committedPreviewSettings = committed
        var draft = committed
        draft.geometry.cropWidth = 1
        draft.exposure = 1
        model.updatePreview(settings: draft, includeHistogram: false)
        wait(model)
        check(model.basePreviewGeometry.cropWidth == 0.75)
        print("REFERENCE_RECT before=\(model.basePreviewImage!.size) after=\(model.previewImage!.size) buffer=\(buffer.width)x\(buffer.height)")
        check(model.basePreviewImage!.size.width == model.basePreviewImage!.size.height && model.previewImage!.size.width / model.previewImage!.size.height == 4.0 / 3.0,
                     "reference must keep committed crop while draft result is uncropped")
        let before = model.basePreviewImage!
        let neutral = try model.processor.processBuffer(buffer: buffer, settings: committed,
            previewLongEdge: 1280, lutURL: nil, viewportPreview: true)
        check(before.pngData() == model.processor.makeUIImage(from: neutral, orientation: .up)?.pngData(),
                     "reference pixels must be default neutral, not current exposure")
        check(model.baseHistogram == model.processor.computeRGBHistogram(from: neutral),
              "neutral RGB belongs to the actual committed crop/reference buffer")
        draft.exposure = 2
        model.histogram = model.processor.computeRGBHistogram(from: buffer)
        check(model.histogram != nil)
        model.updatePreview(settings: draft, includeHistogram: false, quality: .interactive)
        wait(model)
        check(model.basePreviewImage === before, "user exposure must reuse unchanged neutral")
        check(model.histogram == nil, "accepted no-statistics frame must not keep prior bins")
        check(model.baseHistogram != nil)
        model.committedPreviewSettings = draft
        model.updatePreview(settings: draft, includeHistogram: false, quality: .interactive)
        wait(model)
        guard model.basePreviewGeometry.cropWidth == 1 else {
            print("FAIL: committing an already-rendered draft must refresh neutral even when result request/settings are identical")
            exit(1)
        }
        committed = draft
        committed.lensCorrection = LensCorrectionSettings(distortion: true)
        model.committedPreviewSettings = committed
        model.updatePreview(settings: committed, includeHistogram: false)
        wait(model)
        check(model.basePreviewLens.distortion && model.comparisonReferenceKey?.lens.distortion == true)
        check(model.basePreviewImage !== before, "lens-only committed change must invalidate neutral")
        let key = model.comparisonReferenceKey!
        model.updatePreviewSize(256, settings: committed)
        wait(model)
        check(model.comparisonReferenceKey?.longEdge == 256 && model.comparisonReferenceKey != key)
        let statisticsDeadline = Date().addingTimeInterval(4)
        while model.histogram == nil && Date() < statisticsDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        for (histogram, image) in [(model.histogram, model.previewImage), (model.baseHistogram, model.basePreviewImage)] {
            check(histogram != nil && histogram?.width == image?.cgImage?.width && histogram?.height == image?.cgImage?.height,
                  "viewport resize binds neutral and after RGB to each actual displayed frame")
        }
        print("PASS: neutral pixels and key follow committed crop/lens/demand, not draft crop or user exposure; empty stats remain empty")
        let accepted = model.previewImage!
        model.draftBuffer = nil
        model.draftPreviewBuffer = nil
        var failed = committed; failed.exposure = 0.4
        model.editSaveState = .failed("fixture unsaved")
        model.updatePreview(settings: failed, includeHistogram: false)
        wait(model)
        check(model.previewFailed && model.previewImage === accepted)
        var exportRejected = false
        model.exportJPEG(settings: failed) { result in if case .failure = result { exportRejected = true } }
        check(exportRejected, "failed preview is not current/exact for export")
        model.draftBuffer = buffer
        model.retryPreview(settings: failed)
        wait(model)
        check(!model.previewFailed && model.previewImage !== accepted)
        check(model.editSaveState == .failed("fixture unsaved"), "preview success must not clear save error")
        let sourceKey = model.comparisonReferenceKey!
        model.invalidatePreviewRequests()
        model.sourceRevision = UUID()
        model.updatePreview(settings: failed, includeHistogram: false)
        wait(model)
        check(model.comparisonReferenceKey != sourceKey)
        print("PASS: failure keeps accepted pixels, blocks export, retries same candidate, preserves unsaved error, and source invalidates reference")
        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            let raw = URL(fileURLWithPath: CommandLine.arguments[2])
            let rawStore = try EditPersistence(directory: out.appendingPathComponent("raw-edits"))
            let identity = try PhotoIdentity.fallback(for: raw)
            var edited = RawSettings.default
            edited.processing = .legacy
            edited.exposure = 1
            edited.whiteBalanceMode = .custom
            edited.temperature = 7800
            edited.tint = 20
            edited.hsl.set(.hue, channel: 0, value: 25)
            edited.geometry.cropWidth = 0.85
            edited.lensCorrection = LensCorrectionSettings(distortion: true, tca: true)
            try rawStore.save(identity, state: PhotoEditState(settings: edited))
            let rawModel = RawEditorViewModel(editPersistence: rawStore)
            rawModel.importImage(from: .raw(raw), identity: identity)
            let deadline = Date().addingTimeInterval(35)
            while rawModel.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(rawModel.hasImage, "RAW import succeeds: \(rawModel.statusMessage ?? "nil")")
            rawModel.updatePreviewSize(320, settings: edited)
            wait(rawModel)
            check(!rawModel.previewFailed && rawModel.basePreviewProcessing == .legacy && rawModel.basePreviewLens.distortion,
                  "RAW reference retains legacy processing and committed lens")
            check(rawModel.comparisonReferenceKey?.kind == .raw && rawModel.comparisonReferenceKey?.longEdge == 320)
            var neutral = RawSettings.default
            neutral.processing = .legacy
            neutral.geometry = edited.geometry
            neutral.lensCorrection = edited.lensCorrection
            let expected = try rawModel.processor.processRaw(url: raw, settings: neutral,
                previewLongEdge: 320, lutURL: nil, viewportPreview: true)
            check(rawModel.basePreviewImage?.pngData() == rawModel.processor.makeUIImage(from: expected.buffer, orientation: .up)?.pngData(),
                  "actual RAW neutral uses camera WB/default exposure, no user exposure/WB/HSL, same geometry/lens/processing/demand")
            check(rawModel.baseHistogram == rawModel.processor.computeRGBHistogram(from: expected.buffer),
                  "RAW neutral RGB counts match the shown reference at the requested preview dimensions")
            print("PASS: RAW matched native pixel oracle; lens report=\(rawModel.lensInfo?.message ?? "none")")
        }

    }
}
