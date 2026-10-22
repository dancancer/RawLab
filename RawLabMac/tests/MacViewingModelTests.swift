import AppKit
import Combine

@main struct MacViewingModelTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        guard condition() else { throw NSError(domain: "MacViewingModel", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        count += 1; print("PASS: \(text)")
    }
    static func wait(_ text: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if condition() { print("PASS: \(text)"); return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        throw NSError(domain: "MacViewingModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "timeout: \(text)"])
    }
    static func histogramMatches(_ frame: RenderedImage, _ label: String) throws {
        let image = frame.image, bytes = image.dataProvider!.data! as Data
        var expected = Array(repeating: Array(repeating: 0.0, count: 256), count: 3)
        for y in 0..<image.height { for x in 0..<image.width { for channel in 0..<3 {
            expected[channel][Int(bytes[y * image.bytesPerRow + x * 4 + channel])] += 1
        } } }
        try check(frame.histogram == expected, "\(label): all 768 RGB bins match this frame's actual pixels")
        try check(frame.histogram.allSatisfy { $0.reduce(0, +) == Double(image.width * image.height) },
                  "\(label): each channel counts the actual displayed dimensions")
    }
    static func statisticsChecks(_ fixture: URL) throws {
        let pixels: [UInt8] = [0,0,0,0, 255,0,0,17, 0,255,0,128, 91,92,93,94,
                               0,0,255,255, 255,255,255,1, 10,10,10,99, 81,82,83,84]
        var expected = Array(repeating: Array(repeating: 0.0, count: 256), count: 3)
        for channel in 0..<3 { expected[channel][0] = 3; expected[channel][255] = 2; expected[channel][10] = 1 }
        var measured: PreviewStatistics?
        try pixels.withUnsafeBytes { bytes in
            var buffer = sony2fuji_buffer()
            buffer.data = UnsafeMutableRawPointer(mutating: bytes.baseAddress)
            buffer.width = 3; buffer.height = 2; buffer.stride_bytes = 16; buffer.size_bytes = pixels.count
            buffer.pixel_format = SONY2FUJI_PIXEL_RGBA8
            measured = PreviewStatistics.analyze(&buffer)
            try check(measured?.histogram == expected, "padded RGBA counts exact RGB bins and ignores alpha/padding")
        }
        try check(measured?.histogram == expected, "statistics own counts after input access ends")
        let mask = measured!.clipping
        let maskPixels: [UInt8] = [0,130,255,160, 255,0,0,160, 255,0,0,160,
                                   255,0,0,160, 255,0,0,160, 0,0,0,0]
        try check(mask.width == 3 && mask.height == 2 && mask.bytesPerRow == 12 &&
                  mask.dataProvider!.data! as Data == Data(maskPixels),
                  "Swift clipping image owns exact dimensions, stride and pixels after native mask release")
        var invalid = sony2fuji_buffer()
        try check(PreviewStatistics.analyze(&invalid) == nil, "invalid native buffer reports unavailable statistics")
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let expectedFrame = try engine.render(fixture, settings: Adjustments(), lut: nil, edge: 512)!
        try histogramMatches(expectedFrame, "CPU RAW preview")
        var calls = 0
        let unavailable = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, statisticsProvider: { _ in
            calls += 1
            return PreviewStatistics.analyze(&invalid)
        })
        let frame = try unavailable.render(fixture, settings: Adjustments(), lut: nil, edge: 512)!
        try check(calls == 1 && frame.image.dataProvider!.data! as Data == expectedFrame.image.dataProvider!.data! as Data,
                  "native statistics failure retains the successfully rendered photo")
        try check(frame.histogram.isEmpty && frame.clipping == nil && frame.shadows == nil && frame.highlights == nil,
                  "failed statistics clear bins, clipping and percentages together")
    }
    static func statisticsRecoveryChecks(_ fixture: URL, output: URL) throws {
        for geometry in [false, true] {
            let directory = output.appendingPathComponent(geometry ? "geometry-recovery" : "original-recovery")
            let model = EditorModel(lookDirectory: directory.appendingPathComponent("looks"),
                editDirectory: directory.appendingPathComponent("edits"), batchDirectory: directory.appendingPathComponent("batch"))
            var calls = 0
            model.engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF, statisticsProvider: { buffer in
                calls += 1
                return calls == (geometry ? 2 : 1) ? nil : PreviewStatistics.analyze(&buffer)
            })
            model.films = []; model.updatePreviewLongEdge(256); model.open(fixture)
            if geometry {
                var crop = GeometrySettings(); crop.cropX = 0.1; crop.cropWidth = 0.8
                model.settings.geometry = crop
            }
            try wait("statistics failure still accepts a complete photo pair") { !model.busy && model.result != nil && model.neutral != nil }
            try check(model.neutral!.histogram.isEmpty && !model.result!.histogram.isEmpty,
                      "failure fixture isolates unavailable neutral statistics: geometry=\(geometry)")
            model.schedule()
            try wait("same-source same-settings statistics retry settles") { !model.busy }
            try histogramMatches(model.neutral!, "same-engine recovered neutral geometry=\(geometry)")
            let reference = model.neutral!.image, attempts = calls
            model.schedule()
            try wait("complete neutral statistics return to cache reuse") { !model.busy }
            try check(model.neutral!.image === reference && calls == attempts + 1,
                      "healthy neutral is reused while only after is rendered: geometry=\(geometry)")
        }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath(), output = URL(fileURLWithPath: CommandLine.arguments[2])
        try statisticsChecks(fixture)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try statisticsRecoveryChecks(fixture, output: output)
        let file = output.appendingPathComponent("source-a.dng"), next = output.appendingPathComponent("source-b.dng")
        try FileManager.default.copyItem(at: fixture, to: file); try FileManager.default.copyItem(at: fixture, to: next)
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: next) }
        let model = EditorModel(lookDirectory: output.appendingPathComponent("looks"), editDirectory: output.appendingPathComponent("edits"), batchDirectory: output.appendingPathComponent("batch"))
        model.films = []; model.updatePreviewLongEdge(512); model.open(file)
        try wait("initial RAW pair accepted") { !model.busy && model.result != nil && model.neutral != nil }
        try histogramMatches(model.result!, "accepted after")
        try histogramMatches(model.neutral!, "accepted neutral")
        let original = model.neutral!.image
        model.settings.exposure = 0.6
        try wait("user exposure changes after frame only") { !model.busy && model.error == nil }
        try check(model.neutral!.image === original, "neutral original cache is immutable across color edits")
        try histogramMatches(model.result!, "edited after")
        try histogramMatches(model.neutral!, "cached neutral")
        model.settings.lensCorrection = LensCorrectionSettings(); model.settings.lensCorrection?.distortion = true
        try wait("lens-only reference accepted") { !model.busy && model.error == nil }
        try check(model.neutral!.image !== original, "lens-only committed setting uses an independently rendered reference")
        let engine = try RenderEngine()
        let expected = try engine.render(file, settings: model.settings.neutralGeometrySettings, lut: nil, edge: nil)!
        try check(model.neutral!.image.width == expected.image.width && model.neutral!.image.height == expected.image.height,
                  "lens-only before and after reference use matching committed canvas and demand")
        try check(model.neutral!.image.dataProvider!.data! as Data == expected.image.dataProvider!.data! as Data,
                  "lens-only neutral pixels match default-color committed-lens rendering")
        let accepted = model.result!.image
        try FileManager.default.removeItem(at: file)
        model.settings.exposure = 0.7
        try wait("real missing-file render fails") { !model.busy && model.error != nil }
        try check(model.result?.image === accepted, "latest preview failure preserves the last valid frame")
        #if !RAWLAB_VIEWING_BASELINE
        try check(model.previewOutdated && !model.canApplySettings && !model.prepareBatch(), "failed latest preview remains ineligible for exact actions")
        model.error = nil
        try check(model.previewOutdated && !model.canApplySettings, "dismissing an error does not promote the old frame to current")
        try wait("independent autosave failure becomes visible") { model.saveError != nil }
        let saveError = model.saveError
        try FileManager.default.copyItem(at: fixture, to: file)
        model.schedule()
        try check(model.previewOutdated && model.busy, "retry stays outdated until a successful accepted frame")
        try wait("retry accepts current exact frame") { !model.busy && !model.previewOutdated && model.error == nil }
        try check(model.result != nil && model.saveError == saveError, "render completion does not clear independent save failure")
        try check(model.saveEdits(), "successful save can clear its own error")
        try FileManager.default.removeItem(at: file); model.settings.exposure = 0.8
        try wait("second current-source failure") { !model.busy && model.previewOutdated }
        try FileManager.default.copyItem(at: fixture, to: file)
        model.open(next)
        try check(model.file == next && !model.previewOutdated && model.result == nil, "new source clears stale-frame status and old pair")
        try wait("new source pair accepted") { !model.busy && model.result != nil && model.neutral != nil }
        try histogramMatches(model.result!, "new source after")
        try histogramMatches(model.neutral!, "new source neutral")
        try check(model.neutral!.image !== original, "new source never reuses the old source reference")
        let priorSource = MacReferenceSource(next, raster: false), priorRevision = model.sourceRevision, priorEngine = model.engine
        var metadata = stat()
        guard fstatat(AT_FDCWD, next.path, &metadata, 0) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let replacement = output.appendingPathComponent("replacement.dng")
        try FileManager.default.copyItem(at: fixture, to: replacement)
        guard rename(replacement.path, next.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let times = [metadata.st_atimespec, metadata.st_mtimespec]
        let updated = times.withUnsafeBufferPointer { utimensat(AT_FDCWD, next.path, $0.baseAddress, 0) }
        guard updated == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let replacedSource = MacReferenceSource(next, raster: false)
        try check(priorSource.size == replacedSource.size && priorSource.modified == replacedSource.modified && priorSource.fileNumber != replacedSource.fileNumber,
                  "atomic replacement fixture preserves native path/size/mtime while changing inode")
        model.open(next)
        try check(model.sourceRevision != priorRevision && model.result == nil, "same-URL replacement advances the common viewing and metadata revision")
        try wait("same-URL inode replacement accepts a new frame pair") { !model.busy && model.result != nil }
        try check(model.engine !== priorEngine, "same-URL identity replacement rebuilds the native client session before neutral rendering")
        let validFrame = model.result!.image
        var replacementMetadata = stat()
        guard fstatat(AT_FDCWD, next.path, &replacementMetadata, 0) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var corrupted = try Data(contentsOf: fixture)
        corrupted.replaceSubrange(0..<min(32, corrupted.count), with: repeatElement(UInt8(0), count: min(32, corrupted.count)))
        try corrupted.write(to: replacement)
        guard rename(replacement.path, next.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let preservedTimes = [replacementMetadata.st_atimespec, replacementMetadata.st_mtimespec]
        guard preservedTimes.withUnsafeBufferPointer({ utimensat(AT_FDCWD, next.path, $0.baseAddress, 0) }) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let corruptIdentity = MacReferenceSource(next, raster: false)
        try check(corruptIdentity.size == replacedSource.size && corruptIdentity.modified == replacedSource.modified && corruptIdentity.fileNumber != replacedSource.fileNumber,
                  "corrupt replacement preserves path/size/mtime with a new inode")
        model.schedule()
        try wait("corrupt same-metadata replacement fails real RAW decoding") { !model.busy && model.error != nil }
        try check(model.result?.image === validFrame && model.previewOutdated && !model.canApplySettings,
                  "changed-inode corrupt RAW cannot masquerade as a successful cached preview")
        try FileManager.default.removeItem(at: next)
        try FileManager.default.copyItem(at: fixture, to: next)
        model.schedule()
        try wait("restored RAW retry accepts current exact pair") { !model.busy && model.error == nil && !model.previewOutdated }
        #endif
        print("PASS: \(count) Mac view/reference model checks")
    }
}
