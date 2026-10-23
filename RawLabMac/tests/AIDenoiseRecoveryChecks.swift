import AppKit

enum AIDenoiseRecoveryChecks {
    private enum Ending: String, CaseIterable { case cancel, disable, failure, reset }

    static func firstPreparation(root: URL) throws {
        let raw = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lutools/tests/fixtures/bayer-demosaic.dng")
        var failures: [String] = []
        for ending in Ending.allCases {
            let folder = root.appendingPathComponent(ending.rawValue)
            let model = EditorModel(lookDirectory: folder.appendingPathComponent("looks"),
                editDirectory: folder.appendingPathComponent("edits"), batchDirectory: folder.appendingPathComponent("batch"))
            model.debounceTimer?.cancel(); model.debounceTimer = nil
            model.file = raw; model.engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            model.schedule(forceExact: true); model.launchNextRender()
            try wait("Ordinary preview becomes exportable") { model.canExport }
            let original = pixels(model.result!.image)
            var started = false, completed = false
            let release = DispatchSemaphore(value: 0)
            model.prepareAIOperation = { _, _, _ in
                DispatchQueue.main.async { started = true }
                _ = release.wait(timeout: .now() + 8)
                defer { DispatchQueue.main.async { completed = true } }
                if ending == .failure { throw RenderError.aiFailed("Fixture model failure") }
            }
            model.requestAIDenoise()
            try wait("First AI preparation starts") { started && model.aiState.isRunning }
            switch ending {
            case .cancel: model.cancelAIDenoise()
            case .disable: model.setAIEnabled(false)
            case .failure: break
            case .reset: model.requestAdjustmentReset(.tool(.denoise))
            }
            release.signal()
            try wait("First AI preparation finishes") { completed && !model.aiState.isRunning }
            model.launchNextRender()
            try wait("Ordinary recovery finishes") { !model.workerActive && !model.scheduler.isBusy }
            let expected: EditorModel.AIDenoiseState = ending == .cancel ? .cancelled :
                ending == .failure ? .failed("Fixture model failure") : .idle
            let valid = !model.settings.aiDenoiseEnabled && model.aiState == expected &&
                !model.previewOutdated && model.canExport && pixels(model.result!.image) == original
            let message = "First AI \(ending.rawValue) restores ordinary preview/export without losing terminal state"
            print("\(valid ? "PASS" : "FAIL"): \(message)")
            if !valid { failures.append(message) }
            model.resetAITask()
        }
        if !failures.isEmpty { throw failure(failures.joined(separator: "\n")) }
    }

    private static func wait(_ message: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if !predicate() { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AIDenoiseRecoveryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func pixels(_ image: CGImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
