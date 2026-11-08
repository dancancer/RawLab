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
    static func waitForHistogram(_ model: RawEditorViewModel) {
        let deadline = Date().addingTimeInterval(4)
        while model.histogram == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
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
        model.updatePreview(settings: .default, includeHistogram: false)
        wait(model)
        check(model.previewFailed, "preview fails when neither its source nor its buffer is present")

        let viewportURL = out.appendingPathComponent("viewport.png")
        let viewportImage = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 960), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 960))
            UIColor.blue.setFill(); context.fill(CGRect(x: 640, y: 0, width: 640, height: 960))
        }
        try viewportImage.pngData()!.write(to: viewportURL)
        let cacheModel = RawEditorViewModel(editPersistence: try EditPersistence(directory: out.appendingPathComponent("cache-edits")))
        cacheModel.hasImage = true
        cacheModel.sourceKind = .raster
        cacheModel.sourceFile = .externallyManaged(viewportURL)
        cacheModel.updatePreviewSize(320, settings: .default)
        wait(cacheModel)
        waitForHistogram(cacheModel)
        let fitImage = cacheModel.previewImage
        let fitHistogram = cacheModel.histogram
        let fitNativeSize = cacheModel.nativeImageSize
        check(fitImage?.cgImage?.width == 320, "initial Fit preview is bounded by its viewport")
        check(fitHistogram != nil && fitNativeSize != nil, "initial Fit statistics and native size completed")
        cacheModel.updatePreviewSize(1280, settings: .default)
        wait(cacheModel)
        let zoomImage = cacheModel.previewImage
        check(zoomImage?.cgImage?.width == 1280, "zoom renders a larger viewport preview")
        cacheModel.updatePreviewSize(320, settings: .default)
        wait(cacheModel)
        check(cacheModel.previewImage === fitImage,
              "returning from 100% to Fit reuses the completed exact preview image")
        check(cacheModel.histogram == fitHistogram && cacheModel.nativeImageSize == fitNativeSize,
              "returning to Fit reuses the completed preview statistics and native size")
        cacheModel.updatePreviewSize(1280, settings: .default)
        wait(cacheModel)
        check(cacheModel.previewImage === zoomImage, "zoom also reuses pixels if histogram analysis was interrupted")
        waitForHistogram(cacheModel)
        check(cacheModel.histogram?.width == 1280, "reused zoom preview gets its own histogram")
        print("PASS: completed raster Fit and zoom previews reuse pixels and preserve their own histograms")
        let buffer = try model.processor.loadRasterBuffer(url: url).buffer
        model.sourceFile = .externallyManaged(url)
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
        // A raster can reload from its source even when both in-memory buffers are gone.
        model.sourceFile = nil
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
        model.sourceFile = .externallyManaged(url)
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
            let rawZoom = rawModel.previewImage
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
            let rawFit = rawModel.previewImage
            rawModel.updatePreviewSize(1280, settings: edited)
            wait(rawModel)
            check(rawFit != nil && rawZoom != nil && rawZoom !== rawFit && rawModel.previewImage === rawZoom,
                  "first RAW zoom reuses a matching exact frame from import")
            rawModel.updatePreviewSize(320, settings: edited)
            wait(rawModel)
            check(rawModel.previewImage === rawFit, "RAW Fit reuses the completed frame")
            rawModel.updatePreviewSize(1280, settings: edited)
            wait(rawModel)
            check(rawModel.previewImage === rawZoom, "RAW zoom reuses the completed frame")
            print("PASS: RAW matched native pixel oracle; lens report=\(rawModel.lensInfo?.message ?? "none")")
        }
        if CommandLine.arguments.count > 3, !CommandLine.arguments[3].isEmpty {
            let url = URL(fileURLWithPath: CommandLine.arguments[3])
            let model = RawEditorViewModel(editPersistence: try EditPersistence(directory: out.appendingPathComponent("hdr-edits")))
            model.hasImage = true
            model.sourceKind = .raster
            model.sourceFile = .externallyManaged(url)
            var settings = RawSettings.default
            settings.hdr = HDRSettings()
            model.updatePreviewSize(320, settings: settings)
            wait(model)
            let fit = model.hdrPresentation
            check(fit != nil && max(fit!.width, fit!.height) == 320,
                  "HDR Fit produced a bounded pair: \(model.statusMessage ?? "none")")
            model.updatePreviewSize(704, settings: settings)
            wait(model)
            let zoom = model.hdrPresentation
            check(zoom != nil && max(zoom!.width, zoom!.height) == 704, "HDR zoom produced a larger pair")
            model.updatePreviewSize(320, settings: settings)
            wait(model)
            check(model.hdrPresentation === fit, "HDR Fit reuses the completed pair")
            model.updatePreviewSize(704, settings: settings)
            wait(model)
            check(model.hdrPresentation === zoom, "HDR zoom reuses the completed pair")
            let reference = model.hdrReference
            settings.hdr?.exposure = 0.5
            model.updatePreview(settings: settings)
            wait(model)
            check(reference != nil && model.hdrReference === reference && model.hdrPresentation !== zoom,
                  "HDR exposure regenerates edited pixels and reuses the unchanged reference")
            print("PASS: HDR viewport round trip and comparison reuse")

            let acceptedHDR = model.hdrPresentation
            let acceptedFrameID = model.acceptedPreviewFrameID
            let unreadable = out.appendingPathComponent("invalid-hdr.jpg")
            try Data("invalid image".utf8).write(to: unreadable)
            model.sourceFile = .externallyManaged(unreadable)
            var failingSettings = settings
            failingSettings.hdr?.exposure = 0.75
            model.updatePreview(settings: failingSettings)
            wait(model)
            check(model.previewFailed && model.statusHasDiagnostics && model.hdrPresentation === acceptedHDR,
                  "Failed HDR rendering retains the accepted pixels and exposes error diagnostics")
            guard let diagnosticData = try ErrorDiagnostics.app.reportData() else {
                check(false, "Failed HDR rendering records an exportable diagnostic")
                return
            }
            let report = try JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any]
            let last = (report?["events"] as? [[String: Any]])?.last
            let context = last?["context"] as? [String: String]
            check(last?["stage"] as? String == "renderHDR" && context?["mode"] == "hdr" && context?["longEdge"] == "704",
                  "The exported diagnostic includes the HDR stage and viewport demand")
            model.sourceFile = .externallyManaged(url)
            model.updatePreview(settings: settings)
            wait(model)
            check(!model.previewFailed && model.acceptedPreviewFrameID != acceptedFrameID && model.hdrReference === reference,
                  "HDR retry accepts a preview and reuses the still-valid reference")
            print("PASS: HDR preview failure retains pixels, exports diagnostics and preserves comparison reuse on retry")
        }
    }
}
