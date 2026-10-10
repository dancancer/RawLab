import AppKit
import UniformTypeIdentifiers
import SwiftUI

private final class MatchProtocol: URLProtocol {
    static var response = Data()
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum Failure: Error { case failed(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try value() else { throw Failure.failed(name) }
    print("PASS: \(name)")
}

@main struct AIWorkflowTests {
    @MainActor static func main() {
        let ui = ProcessInfo.processInfo.environment["RAWLAB_AI_UI"] == "1"
        if ui { NSApplication.shared.setActivationPolicy(.regular) }
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        if ui { NSApplication.shared.run() }
        else { dispatchMain() }
    }

    @MainActor private static func run() async throws {
        setbuf(stdout, nil)
        let folder = try AITemporaryDirectory()
        let worker = AIColorWorker()
        let cancellation = AIWorkCancellation()
        cancellation.cancel()
        do {
            try await worker.perform(cancellation: cancellation) {
                throw Failure.failed("Cancelled local operation must not execute")
            }
            throw Failure.failed("Cancelled local operation must throw")
        } catch is CancellationError {}
        let retry = try await worker.perform { 7 }
        try check(retry == 7, "Cancelled local work leaves the worker available for retry")
        let raw = folder.url.appendingPathComponent("source.raw")
        try Data("raw identity fixture".utf8).write(to: raw)
        var settings = Adjustments()
        settings.exposure = 0.7; settings.temperature = 7200; settings.tint = 12; settings.whiteBalanceMode = .custom
        settings.contrast = 30; settings.highlights = -20; settings.shadows = 15; settings.toneCurve = 10
        settings.saturation = 25; settings.sharpening = 50
        settings.rawNoiseReduction = 0; settings.chromaNoiseReduction = 1
        settings.setEffect(.vignetteAmount, to: -30); settings.setEffect(.grainAmount, to: 17)
        let baseline = settings.aiBaseline
        try check(baseline.exposure == settings.exposure && baseline.temperature == settings.temperature &&
                  baseline.tint == settings.tint && baseline.whiteBalanceMode == .custom && baseline.sharpening == 50 &&
                  baseline.chromaNoiseReduction == 1, "AI baseline preserves input and detail settings")
        try check(baseline.photoEffects == settings.photoEffects, "AI baseline preserves main's existing photo effects")
        try check(baseline.contrast == 0 && baseline.highlights == 0 && baseline.shadows == 0 &&
                  baseline.toneCurve == 0 && baseline.saturation == 0 && baseline.strength == 1,
                  "AI baseline removes output adjustments without resetting the photo")
        let state = PhotoEditState(settings: settings, filmID: "")
        let snapshot = try EditorModel.AISnapshot(file: raw, state: state, look: nil, lookName: "中性", revision: 4)
        try check(snapshot.matches(file: raw, state: state, revision: 4), "Snapshot accepts the original edit and file")
        try check(!snapshot.matches(file: raw, state: state, revision: 5), "Editing away and back still invalidates a snapshot")
        var changed = state; changed.settings.exposure += 1
        try check(!snapshot.matches(file: raw, state: changed, revision: 4), "Changed settings invalidate a snapshot")
        try Data("changed original".utf8).write(to: raw)
        try check(!snapshot.matches(file: raw, state: state, revision: 4), "Externally changed RAW invalidates a snapshot")

        let recipe = AIColorRecipe.identity(name: "试验 / Color:Look", summary: "Local test only")
        let look = try AIColorLook.compile(recipe: recipe, model: "test-model")
        try check(look.report.gridSize == 65 && look.report.maxError < 0.00002, "Swift compiler bridge preserves the measured result")
        try check(look.url.deletingLastPathComponent() == look.directory.url && look.url.pathExtension == "cube",
                  "Recipe names cannot escape the private work directory")
        let stored = try String(contentsOf: look.url, encoding: .utf8)
        try check(stored.contains("#RawLabRecipe:") && stored.contains("test-model"), "Private look retains the validated recipe provenance")
        let regions = AIToneRegions(shadowStart: 0.1, shadowEnd: 0.45, highlightStart: 0.55, highlightEnd: 0.95)
        let adapted = try AIColorLook.compile(recipe: recipe, model: "test-model", regions: regions)
        let adaptedText = try String(contentsOf: adapted.url, encoding: .utf8)
        try check(adapted.regions == regions && adapted.recipe == recipe && adaptedText.contains("\"shadowEnd\":0.45"),
                  "Adapted compiler keeps style and region provenance separate")
        let adaptedExport = folder.url.appendingPathComponent("adapted-shared.cube")
        try AIFileExporter.write(source: adapted.url, destination: adaptedExport, protecting: [], overwrite: false)
        try check(try !String(contentsOf: adaptedExport, encoding: .utf8).contains("shadowEnd"),
                  "Public adapted CUBE strips region metadata")
        let exported = folder.url.appendingPathComponent("shared.cube")
        try AIFileExporter.write(source: look.url, destination: exported, protecting: [raw], overwrite: false)
        let publicText = try String(contentsOf: exported, encoding: .utf8)
        try check(!publicText.contains("RawLabRecipe") && !publicText.contains("test-model") &&
                  publicText.contains("#Gamma:sRGB to sRGB"), "Share export omits private recipe provenance")
        let before = try Data(contentsOf: raw)
        do {
            try AIFileExporter.write(source: look.url, destination: raw, protecting: [raw], overwrite: true)
            throw Failure.failed("Original overwrite must fail")
        } catch is AIError {}
        try check(try Data(contentsOf: raw) == before, "Protected source remains unchanged")
        let alias = folder.url.appendingPathComponent("alias.cube")
        try FileManager.default.linkItem(at: raw, to: alias)
        do {
            try AIFileExporter.write(source: look.url, destination: alias, protecting: [raw], overwrite: true)
            throw Failure.failed("Hard-link overwrite must fail")
        } catch is AIError {}
        try check(try Data(contentsOf: raw) == before, "Hard-link aliases cannot overwrite source content")
        do {
            try AIFileExporter.write(source: look.url, destination: exported, protecting: [], overwrite: false)
            throw Failure.failed("Existing destination must require explicit approval")
        } catch is AIError {}
        try AIFileExporter.write(source: look.url, destination: exported, protecting: [], overwrite: true)
        try check(sony2fuji_validate_look(exported.path, nil, nil) == SONY2FUJI_STATUS_OK, "Explicit overwrite leaves a valid importable CUBE")
        let library = try LookLibrary(directory: folder.url.appendingPathComponent("library"))
        let imported = try library.importLook(from: exported)
        try check(imported.aiGenerated == true, "Shared look remains recognizable after import without a key")
        let provider = AIShareFileProvider(source: look.url, name: recipe.name, owner: look.directory).itemProvider()
        let sharedText: String = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw Failure.failed("Share provider returned no file") }
                    continuation.resume(returning: try String(contentsOf: url, encoding: .utf8))
                } catch { continuation.resume(throwing: error) }
            }
        }
        try check(sharedText.contains("#Gamma:sRGB to sRGB") && !sharedText.contains("test-model") && !sharedText.contains("RawLabRecipe"),
                  "System file provider supplies a real sanitized CUBE attachment")

        if CommandLine.arguments.count > 1 {
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let model = EditorModel(lookDirectory: folder.url.appendingPathComponent("editor-looks"),
                editDirectory: folder.url.appendingPathComponent("edits"), batchDirectory: folder.url.appendingPathComponent("batch"))
            model.open(source)
            try await ready(model)
            model.exportLongEdge = 1234
            let original = try model.freezeAIEdit()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MatchProtocol.self]
            var fixtureRecipe = AIColorRecipe.identity(name: "Pipeline fixture", summary: "Synthetic HTTP fixture")
            fixtureRecipe.chroma = 0.9
            fixtureRecipe.toning[0].a = -0.002; fixtureRecipe.toning[1].b = 0.002; fixtureRecipe.toning[2].b = 0.003
            let content = String(data: try JSONEncoder().encode(fixtureRecipe), encoding: .utf8)!
            MatchProtocol.response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
            let match = try AIColorMatchModel(editor: model, service: AIService(sessionConfiguration: config))
            let preparing = Task { await match.prepare() }
            while match.phase == .idle { await Task.yield() }
            match.cancelGeneration()
            await preparing.value
            try check(match.source == nil && match.phase == .idle, "Stopping preparation discards local work and permits retry")
            await match.prepare()
            try check(match.source != nil && match.baseline != nil && match.error == nil, "Match prepares a frozen neutral source")
            let reference = folder.url.appendingPathComponent("reference.jpg")
            try match.source!.jpeg.write(to: reference)
            let loading = Task { await match.addReferences([reference]) }
            while match.phase == .idle { await Task.yield() }
            match.cancelGeneration()
            await loading.value
            try check(match.references.isEmpty && match.phase == .idle, "Stopping reference loading preserves the previous reference list")
            await match.addReferences([reference])
            try check(match.references.count == 1, "Reference loading prepares a bounded upload image")
            match.generate(configuration: AIConfiguration(baseURL: "https://fixture.invalid", model: "test"), key: "fixture-key")
            try await ready(match)
            try check(match.candidate != nil && match.preview != nil && match.candidate?.recipe.name == fixtureRecipe.name,
                      "HTTP recipe compiles and renders through the real RAW pipeline")
            let candidateURL = match.candidate?.url
            match.generate(configuration: AIConfiguration(baseURL: "https://fixture.invalid", model: "test"), key: "fixture-key")
            match.cancelGeneration()
            try await Task.sleep(nanoseconds: 50_000_000)
            try check(!match.isBusy && match.candidate?.url == candidateURL, "Cancellation retains the previous validated candidate")
            let calls = MatchProtocol.calls
            match.updateRegions(regions)
            try check(!match.canApply && !match.canExport, "Pending adaptation cannot apply or export the previous look")
            try await ready(match)
            try check(match.candidate?.recipe == fixtureRecipe && match.candidate?.regions == regions &&
                      match.fixedCandidate?.url == candidateURL && MatchProtocol.calls == calls,
                      "Local adaptation changes only regions without HTTP or replacing the fixed style")
            try check(match.fixedPreview != nil && match.preview?.image.dataProvider?.data != match.fixedPreview?.image.dataProvider?.data,
                      "Nonzero toning produces a visible pixel difference")
            let validURL = match.candidate?.url
            match.updateRegions(.standard)
            match.cancelGeneration()
            try check(match.regions == regions && match.candidate?.url == validURL && match.canApply,
                      "Cancelled adaptation restores controls to the last validated candidate")
            let validPreview = match.preview?.image.dataProvider?.data
            let validFixed = match.fixedPreview?.image.dataProvider?.data
            let fixedURL = match.fixedCandidate!.url
            let hiddenURL = fixedURL.appendingPathExtension("unavailable")
            try FileManager.default.moveItem(at: fixedURL, to: hiddenURL)
            var failedRegions = regions; failedRegions.shadowStart = 0.15
            match.updateRegions(failedRegions)
            do { try await ready(match); throw Failure.failed("Missing comparison CUBE must fail") }
            catch { try check(match.error != nil && !match.isPreviewing, "Local preview failure is surfaced") }
            try check(match.candidate?.url == validURL && match.preview?.image.dataProvider?.data == validPreview &&
                      match.fixedPreview?.image.dataProvider?.data == validFixed && !match.canApply && !match.canExport,
                      "Failed adaptation preserves both previous frames and blocks stale apply/export")
            try FileManager.default.moveItem(at: hiddenURL, to: fixedURL)
            match.updateRegions(regions)
            try await ready(match)
            try check(match.canApply && match.canExport, "Retry after local failure restores a valid candidate")
            match.updateStrength(0.8)
            try await ready(match)
            let fixedSettings = { var s = match.snapshot.state.settings.aiBaseline; s.strength = 0.8; return s }()
            let fixedFrame = try await worker.render(file: source, settings: fixedSettings, look: match.fixedCandidate!.url)
            try check(match.previewStrength == 0.8 && match.candidate?.regions == regions && MatchProtocol.calls == calls &&
                      match.fixedPreview?.image.dataProvider?.data == fixedFrame.image.dataProvider?.data,
                      "Fixed and adapted comparisons use the same rendered strength")
            if ProcessInfo.processInfo.environment["RAWLAB_AI_UI"] == "1" {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "RawLab AI Local Fixture"
                window.contentView = NSHostingView(rootView: AIColorMatchView(model: match, settings: AISettings()))
                window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
                print("UI READY: local HTTP fixture; no network uploads")
                while window.isVisible { try await Task.sleep(nanoseconds: 200_000_000) }
                return
            }
            let applied = await match.apply()
            try check(applied, "Candidate confirmation commits the frozen edit")
            try check(model.selectedFilm?.isAI == true && model.settings.strength == 0.8 && model.canRestoreAI,
                      "Confirmed candidate is installed, selected and can be restored")
            try check(model.exportLongEdge == 1234, "AI application preserves main's export size setting")
            let installed = try String(contentsOf: model.selectedFilm!.url, encoding: .utf8)
            try check(installed.contains("\"shadowEnd\":0.45"), "Applying installs the manual-region look, not the fixed comparison")
            try await ready(model)
            let restored = try EditPersistence(directory: folder.url.appendingPathComponent("edits")).state(for: source)
            try check(restored?.filmID == model.selectedFilmID && restored?.settings.strength == 0.8,
                      "AI application persists the managed look and settings")
            try model.restoreAIEdit()
            try check(model.settings == original.state.settings && model.selectedFilmID == original.state.filmID && !model.canRestoreAI,
                      "Restore returns to the complete pre-AI edit")
            try await ready(model)
            let stale = try model.freezeAIEdit()
            model.settings.exposure += 0.2
            do {
                try await model.applyAILook(look.url, name: recipe.name, strength: 1, snapshot: stale)
                throw Failure.failed("Stale result must not apply")
            } catch is RenderError {}
            try check(model.settings.exposure == stale.state.settings.exposure+0.2 && model.selectedFilmID == stale.state.filmID,
                      "A stale candidate never replaces newer manual edits")
        }
    }


    @MainActor private static func ready(_ model: EditorModel) async throws {
        for _ in 0..<3000 {
            if !model.busy {
                if let error = model.error { throw Failure.failed(error) }
                if model.result != nil { return }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.failed("Exact preview timed out")
    }

    @MainActor private static func ready(_ model: AIColorMatchModel) async throws {
        for _ in 0..<3000 {
            if !model.isBusy && !model.isPreviewing {
                if let error = model.error { throw Failure.failed(error) }
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.failed("AI candidate timed out")
    }
}
