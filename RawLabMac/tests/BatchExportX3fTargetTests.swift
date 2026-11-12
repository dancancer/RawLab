import Foundation

enum BatchExportX3fTargetTests {
    private enum ProbeFailure: Error {
        case corruptHeader
        case unexpectedProbe
    }

    private struct Failure: Error { let message: String }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }

    static func run(root: URL) throws {
        let directory = root.appendingPathComponent("x3f-target")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacySourceURL = directory.appendingPathComponent("source-legacy.X3F")
        let normalSourceURL = directory.appendingPathComponent("source-normal.X3F")
        let rawSourceURL = directory.appendingPathComponent("source.ARW")
        let rasterSourceURL = directory.appendingPathComponent("source.png")
        let normalTargetURL = directory.appendingPathComponent("target-normal.X3F")
        let lowerNormalTargetURL = directory.appendingPathComponent("target-lower.x3f")
        let legacyTargetURL = directory.appendingPathComponent("target-legacy.X3F")
        let rawTargetURL = directory.appendingPathComponent("target.ARW")
        let rasterTargetURL = directory.appendingPathComponent("target.png")
        let brokenTargetURL = directory.appendingPathComponent("target-broken.X3F")
        for url in [legacySourceURL, normalSourceURL, rawSourceURL, rasterSourceURL,
                    normalTargetURL, lowerNormalTargetURL, legacyTargetURL,
                    rawTargetURL, rasterTargetURL, brokenTargetURL] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        let normalItem = try BatchExportItem(url: normalTargetURL)
        let lowerNormalItem = try BatchExportItem(url: lowerNormalTargetURL)
        let legacyItem = try BatchExportItem(url: legacyTargetURL)
        let rawItem = try BatchExportItem(url: rawTargetURL)
        let rasterItem = try BatchExportItem(url: rasterTargetURL)
        let brokenItem = try BatchExportItem(url: brokenTargetURL)

        // (a) 源为 legacy、resolver 对目标返回 normal → 模式为 .normal，三个镜头标志与 AI 降噪全 false。
        var legacySource = Adjustments()
        legacySource.x3fMode = .legacy
        legacySource.exposure = 0.6
        legacySource.aiDenoiseEnabled = true
        legacySource.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: false, mode: .manual,
            profileID: "sigma-lens", vignetting: true
        )
        let legacyJob = BatchExportJob(source: legacySourceURL, settings: legacySource, look: nil, lookName: "Neutral")
        var probed: [URL] = []
        let resolvedNormal = try legacyJob.snapshot(for: normalItem, x3fDefaultMode: { url in
            probed.append(url)
            return .normal
        })
        try check(probed == [normalItem.input], "X3F mode resolver must probe the target file, not the source")
        try check(resolvedNormal.settings.x3fMode == .normal,
                  "legacy source exporting to a normal X3F target resolves x3fMode to .normal")
        try check(!resolvedNormal.settings.lensSettings.distortion &&
                  !resolvedNormal.settings.lensSettings.tca &&
                  !resolvedNormal.settings.lensSettings.vignetting &&
                  !resolvedNormal.settings.lensSettings.isEnabled,
                  "normal X3F target clears distortion, tca and vignetting together")
        try check(!resolvedNormal.settings.aiDenoiseEnabled,
                  "normal X3F target disables AI denoise together with lens flags")
        try check(resolvedNormal.settings.exposure == 0.6 &&
                  resolvedNormal.settings.lensSettings.profileID == "sigma-lens" &&
                  resolvedNormal.settings.lensSettings.mode == .manual &&
                  !resolvedNormal.settings.lensSettings.autoCrop &&
                  legacyJob.settings == legacySource,
                  "normal X3F target preserves other adjustments and leaves job source snapshot immutable")

        // 非 X3F RAW 源（默认 x3fMode == .normal，但开启了镜头校正与 AI 降噪）导出到小写 .x3f normal 目标，同样执行 normal 契约。
        var rawSource = legacySource
        rawSource.x3fMode = .normal
        let rawToNormalJob = BatchExportJob(source: rawSourceURL, settings: rawSource, look: nil, lookName: "Neutral")
        let rawToNormal = try rawToNormalJob.snapshot(for: lowerNormalItem, x3fDefaultMode: { _ in .normal })
        try check(rawToNormal.settings.x3fMode == .normal &&
                  !rawToNormal.settings.lensSettings.distortion &&
                  !rawToNormal.settings.lensSettings.tca &&
                  !rawToNormal.settings.lensSettings.vignetting &&
                  !rawToNormal.settings.aiDenoiseEnabled,
                  "normal contract applies whenever X3F target resolves to .normal regardless of source format")

        // (b) 源为 normal 且带镜头标志、resolver 对目标返回 legacy → 模式为 .legacy，镜头标志保持源值。
        var normalWithLens = Adjustments()
        normalWithLens.x3fMode = .normal
        normalWithLens.exposure = -0.35
        normalWithLens.aiDenoiseEnabled = true
        normalWithLens.lensCorrection = LensCorrectionSettings(
            distortion: true, tca: true, autoCrop: true, mode: .automatic, vignetting: true
        )
        let normalJob = BatchExportJob(source: normalSourceURL, settings: normalWithLens, look: nil, lookName: "Neutral")
        let resolvedLegacy = try normalJob.snapshot(for: legacyItem, x3fDefaultMode: { _ in .legacy })
        try check(resolvedLegacy.settings.x3fMode == .legacy,
                  "normal source exporting to a legacy X3F target resolves x3fMode to .legacy")
        try check(resolvedLegacy.settings.lensSettings.distortion &&
                  resolvedLegacy.settings.lensSettings.tca &&
                  resolvedLegacy.settings.lensSettings.vignetting &&
                  resolvedLegacy.settings.aiDenoiseEnabled &&
                  resolvedLegacy.settings.exposure == -0.35,
                  "legacy X3F target preserves source lens flags and adjustments")

        // 非 X3F RAW 目标不调用 X3F resolver，按现状返回。
        let nonX3fTarget = try legacyJob.snapshot(for: rawItem, x3fDefaultMode: { _ in throw ProbeFailure.unexpectedProbe })
        try check(nonX3fTarget.settings == legacySource,
                  "non-X3F RAW target does not invoke X3F resolver and keeps existing behavior")

        // raster 源 → X3F 目标：先走既有 raster→RAW 清理分支，再解析目标 X3F 模式。
        var dormantRasterSource = Adjustments()
        dormantRasterSource.x3fMode = .normal
        dormantRasterSource.exposureMode = .sensor
        dormantRasterSource.whiteBalanceMode = .custom
        dormantRasterSource.temperature = 4300
        dormantRasterSource.tint = 28
        dormantRasterSource.rawNoiseReduction = 2
        dormantRasterSource.aiDenoiseEnabled = true
        dormantRasterSource.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, vignetting: true)
        let rasterToX3fJob = BatchExportJob(source: rasterSourceURL, settings: dormantRasterSource, look: nil, lookName: "Mixed")
        let rasterToLegacyX3f = try rasterToX3fJob.snapshot(for: legacyItem, x3fDefaultMode: { _ in .legacy })
        try check(rasterToLegacyX3f.settings.x3fMode == .legacy &&
                  rasterToLegacyX3f.settings.exposureMode == .preview &&
                  rasterToLegacyX3f.settings.whiteBalanceMode == .asShot &&
                  rasterToLegacyX3f.settings.temperature == 6500 &&
                  rasterToLegacyX3f.settings.tint == 0 &&
                  rasterToLegacyX3f.settings.rawNoiseReduction == 0 &&
                  rasterToLegacyX3f.settings.lensCorrection == nil,
                  "raster source to legacy X3F clears dormant camera state first, then applies target X3F mode")
        let rasterToNormalX3f = try rasterToX3fJob.snapshot(for: normalItem, x3fDefaultMode: { _ in .normal })
        try check(rasterToNormalX3f.settings.x3fMode == .normal &&
                  rasterToNormalX3f.settings.lensCorrection == nil &&
                  !rasterToNormalX3f.settings.aiDenoiseEnabled,
                  "raster source to normal X3F applies raster cleanup and normal contract")

        // (c) raster 目标：resolvedForRaster 既有行为不变，且不触发 X3F resolver。
        var rawWithCameraControls = legacySource
        rawWithCameraControls.exposureMode = .preview
        rawWithCameraControls.whiteBalanceMode = .custom
        rawWithCameraControls.temperature = 5100
        rawWithCameraControls.tint = 19
        rawWithCameraControls.rawNoiseReduction = 2
        let toRasterJob = BatchExportJob(source: legacySourceURL, settings: rawWithCameraControls, look: nil, lookName: "Raster")
        let resolvedRaster = try toRasterJob.snapshot(for: rasterItem, x3fDefaultMode: { _ in throw ProbeFailure.unexpectedProbe })
        try check(resolvedRaster.settings == rawWithCameraControls.resolvedForRaster &&
                  resolvedRaster.settings.exposureMode == .sensor &&
                  resolvedRaster.settings.whiteBalanceMode == .asShot &&
                  resolvedRaster.settings.temperature == 6500 &&
                  resolvedRaster.settings.tint == 0 &&
                  resolvedRaster.settings.rawNoiseReduction == 0 &&
                  !resolvedRaster.settings.aiDenoiseEnabled &&
                  resolvedRaster.settings.lensCorrection == nil,
                  "raster target keeps resolvedForRaster behavior without probing X3F mode")

        // (d) resolver 抛错 → snapshot(for:) 抛错，不得吞掉错误返回源模式。
        var threwExpected = false
        do {
            _ = try legacyJob.snapshot(for: brokenItem, x3fDefaultMode: { _ in throw ProbeFailure.corruptHeader })
        } catch ProbeFailure.corruptHeader {
            threwExpected = true
        }
        try check(threwExpected, "X3F resolver failure propagates out of snapshot(for:) instead of falling back to source mode")

        // (e) BatchExportRunner.run 错误隔离与身份校验顺序：
        // 1) 未被替换但 FOVb 头损坏的 .X3F 目标在 snapshot(for:) 探测时抛错，只将该项标为 .failed，不中断整批，后续目标继续导出。
        let runnerOutput = directory.appendingPathComponent("runner-output")
        try FileManager.default.createDirectory(at: runnerOutput, withIntermediateDirectories: true)
        let runnerJournal = BatchJournal(directory: directory.appendingPathComponent("runner-journal"))
        let corruptFovbURL = directory.appendingPathComponent("target-corrupt-fovb.X3F")
        try Data("FOVb-corrupt-header".utf8).write(to: corruptFovbURL)
        var isolatedJob = BatchExportJob(source: rawSourceURL, settings: legacySource, look: nil, lookName: "Neutral")
        isolatedJob.outputDirectory = runnerOutput
        var invalidX3fItem = try BatchExportItem(url: corruptFovbURL)
        invalidX3fItem.selected = true
        var validRawItem = try BatchExportItem(url: rawTargetURL)
        validRawItem.selected = true
        isolatedJob.items = [invalidX3fItem, validRawItem]
        try BatchExportRunner.run(job: &isolatedJob, journal: runnerJournal, scope: .unfinished,
                                 shouldCancel: { false }) { _, _, _, destination in
            try Data("rendered".utf8).write(to: destination)
        }
        try check(!isolatedJob.interrupted && isolatedJob.failure == nil &&
                  isolatedJob.items[0].status == .failed &&
                  isolatedJob.items[0].error != nil &&
                  isolatedJob.items[0].error != BatchExportFailure.changedInput.localizedDescription &&
                  isolatedJob.items[1].status == .succeeded,
                  "single X3F probe failure marks only that item .failed without interrupting subsequent targets")

        // 2) 导出前被替换为损坏 FOVb 头的 .X3F 目标先命中 OriginalFileIdentity 校验，报 changedInput 而非 X3F 探测错误，且不影响后续目标。
        let replacedURL = directory.appendingPathComponent("target-replaced.X3F")
        try Data("initial".utf8).write(to: replacedURL)
        var replacedItem = try BatchExportItem(url: replacedURL)
        replacedItem.selected = true
        try Data("FOVb-replaced-corrupt-header".utf8).write(to: replacedURL)
        var secondRawItem = try BatchExportItem(url: rawTargetURL)
        secondRawItem.selected = true
        var replacedJob = BatchExportJob(source: rawSourceURL, settings: legacySource, look: nil, lookName: "Neutral")
        replacedJob.outputDirectory = runnerOutput
        replacedJob.items = [replacedItem, secondRawItem]
        try BatchExportRunner.run(job: &replacedJob, journal: runnerJournal, scope: .unfinished,
                                 shouldCancel: { false }) { _, _, _, destination in
            try Data("rendered-after-replaced".utf8).write(to: destination)
        }
        try check(!replacedJob.interrupted && replacedJob.failure == nil &&
                  replacedJob.items[0].status == .failed &&
                  replacedJob.items[0].error == BatchExportFailure.changedInput.localizedDescription &&
                  replacedJob.items[1].status == .succeeded,
                  "replaced X3F target reports changedInput before X3F probing and keeps remaining batch running")
        print("PASS: batch export X3F target mode resolution and normal contract")
    }
}
