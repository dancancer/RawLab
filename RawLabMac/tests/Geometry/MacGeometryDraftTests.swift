import AppKit
import Combine
import ImageIO
import Darwin
import SwiftUI

@main struct MacGeometryDraftTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static var checks = 0

    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }
        checks += 1
        print("PASS: \(message)")
    }

    static func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.02))) }
    }

    static func wait(_ model: EditorModel, draft: Bool = false, _ name: String) throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !model.busy && model.result != nil && (!draft || model.geometryDraftPreviewReady) { break }
            settle(0.02)
        }
        try check(!model.busy && model.result != nil && model.error == nil && (!draft || model.geometryDraftPreviewReady),
                  "\(name): matching preview completes")
    }

    static func saved(_ raw: URL, directory: URL) throws -> Adjustments {
        guard let state = try EditPersistence(directory: directory).state(for: raw) else {
            throw Failure(description: "Missing persisted edit for \(raw.lastPathComponent)")
        }
        return state.settings
    }

    static func pixels(_ image: CGImage, side: Int? = nil) -> [UInt8] {
        let width = side ?? image.width, height = side ?? image.height
        var result = [UInt8](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return result
    }

    static func delta(_ left: CGImage, _ right: CGImage, side: Int? = nil) -> Int {
        let a = pixels(left, side: side), b = pixels(right, side: side)
        precondition(a.count == b.count)
        return zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    static func physicalRatio(_ model: EditorModel) -> Double {
        let crop = model.geometryDraftSettings, canvas = model.geometryCanvasSize
        return crop.cropWidth * Double(canvas.width) / (crop.cropHeight * Double(canvas.height))
    }

    static func cropAspectBoundaryChecks(_ model: EditorModel, raw: URL, edits: URL) throws {
        let committed = model.settings
        try check(model.beginGeometryDraft(tab: .crop), "aspect-boundary draft opens")
        try wait(model, draft: true, "aspect-boundary reference")
        let reference = model.result!.image
        model.updateGeometryDraft { $0.cropX = 0.1; $0.cropY = 0.1; $0.cropWidth = 0.7123456789; $0.cropHeight = 0.6123456789 }
        let locked = model.geometryDraftSettings
        let lockedRatio = physicalRatio(model)
        model.toggleCropAspectLock()
        try check(model.cropAspectRatio == lockedRatio && model.geometryDraftSettings == locked,
                  "locking the current crop preserves full precision without refitting")
        model.setGeometryDraftParameter(.cropWidth, to: 0.5)
        try check(abs(physicalRatio(model) - lockedRatio) < 1e-9 &&
                  model.geometryDraftSettings.cropX == locked.cropX && model.geometryDraftSettings.cropY == locked.cropY,
                  "locked width links height around the unchanged top-left anchor")
        model.swapCropAspect()
        try check(abs(physicalRatio(model) - 1 / lockedRatio) < 1e-9,
                  "swapping a custom locked ratio uses the exact reciprocal")
        model.toggleCropAspectLock()
        try check(model.cropAspectRatio == nil && model.cropLockedRatio == nil && model.cropAspectPreset == .free,
                  "unlocking returns to one free-ratio authority")
        model.updateGeometryDraft { $0.cropX = 0.1; $0.cropY = 0.1; $0.cropWidth = 0.4; $0.cropHeight = 0.8 }
        model.toggleCropAspectLock()
        let bounded = model.geometryDraftSettings
        model.setGeometryDraftParameter(.cropWidth, to: 0.6)
        try check(model.geometryDraftSettings == bounded,
                  "locked numeric width rejects values whose linked height would leave the canvas")
        model.setGeometryDraftParameter(.cropWidth, to: 0.002)
        try check(abs(model.geometryDraftSettings.cropWidth - 0.002) < 1e-12 &&
                  abs(model.geometryDraftSettings.cropHeight - 0.004) < 1e-12,
                  "locked precise numeric input preserves the native numeric minimum rather than the drag minimum")
        model.toggleCropAspectLock()
        for y in [0.01, 0.84] {
            model.selectCropAspect(.free)
            model.updateGeometryDraft {
                $0.cropX = 0.06; $0.cropY = y; $0.cropWidth = 0.15; $0.cropHeight = 0.15
            }
            try check(model.geometryDraftSettings.isValid, "the off-center free crop is valid before fitting")
            model.selectCropAspect(.threeTwo)
            try check(model.cropAspectPreset == .threeTwo && !model.cropAspectSwapped,
                      "the three-two preset is selected at the crop boundary")
            try check(model.geometryDraftSettings.isValid && abs(physicalRatio(model) - 1.5) < 1e-9,
                      "the selected three-two preset actually refits the off-center crop within strict bounds")
            try check(model.geometryDraftPreviewReady && model.geometryDraftCanApply && !model.busy &&
                      model.result!.image === reference && model.settings == committed,
                      "bounded aspect fitting reuses the reference without committing the draft")
            model.swapCropAspect()
            try check(model.cropAspectSwapped && model.geometryDraftSettings.isValid &&
                      abs(physicalRatio(model) - 2.0 / 3) < 1e-9,
                      "aspect swap at the boundary keeps the reciprocal physical crop ratio valid")
            model.swapCropAspect()
            try check(!model.cropAspectSwapped && model.geometryDraftSettings.isValid &&
                      abs(physicalRatio(model) - 1.5) < 1e-9,
                      "swapping back retains a valid crop matching the selected preset")
        }
        let fitted = model.geometryDraftSettings
        try check(model.applyGeometryDraft() && model.settings.geometrySettings == fitted &&
                  saved(raw, directory: edits).geometrySettings == fitted,
                  "Apply persists the fitted boundary crop rather than the preceding free crop")
        try wait(model, "aspect-boundary Apply")
        model.settings = committed
        try check(model.saveEdits(), "aspect-boundary checks restore their private committed baseline")
        try wait(model, "aspect-boundary cleanup")
    }

    static func cropApplyPublicationChecks(_ model: EditorModel) throws {
        if !model.geometryDraftHasChanges { model.updateGeometryDraft { $0.cropWidth = 0.9 } }
        try check(model.geometryDraftCanApply, "crop publication starts with an applicable draft")
        model.setGeometryCropInteracting(true)
        var observed: [Bool] = []
        let observer = model.objectWillChange.sink { observed.append(model.geometryDraftCanApply) }
        defer { observer.cancel() }
        model.setGeometryCropInteracting(false)
        try check(observed.last == true,
                  "crop release leaves synchronous Apply observers with the committed interaction state")
        observed.removeAll()
        model.setGeometryCropInteracting(true)
        try check(observed.last == false,
                  "crop start leaves synchronous Apply observers with the committed interaction state")
        model.setGeometryCropInteracting(false)
    }

    static func cropInputRoutingChecks(_ model: EditorModel) throws {
        try check(model.geometryDraft == nil && model.geometryDraftTab == .crop && !model.geometryCropInputEnabled,
                  "ordinary preview does not receive crop input callbacks from its remembered crop tab")
        try check(model.beginGeometryDraft(tab: .crop) && model.geometryCropInputEnabled && !model.geometryDraftPreviewReady,
                  "a preparing crop draft owns input before its reference image is ready")
        try wait(model, draft: true, "crop input reference")
        try check(model.geometryCropInputEnabled, "a ready crop draft retains crop input ownership")
        for tab in [MacGeometryTab.perspective, .lens] {
            try check(model.selectGeometryDraftTab(tab) && !model.geometryCropInputEnabled,
                      "\(tab) does not install crop input callbacks")
        }
        try check(model.selectGeometryDraftTab(.crop) && model.geometryCropInputEnabled,
                  "returning to the crop tab restores crop input ownership")
        model.cancelGeometryDraft()
        try check(model.geometryDraft == nil && model.geometryDraftTab == .crop && !model.geometryCropInputEnabled,
                  "Cancel releases crop input while retaining the user's remembered tab")
        try wait(model, "crop input Cancel cleanup")
        try check(model.beginGeometryDraft(tab: .crop), "crop input Apply draft opens")
        try wait(model, draft: true, "crop input Apply reference")
        model.setGeometryDraftParameter(.straightenDegrees, to: 1)
        try check(model.applyGeometryDraft() && model.geometryDraft == nil && model.pendingGeometryPresentation != nil &&
                  !model.geometryCropInputEnabled,
                  "Apply releases crop input even while exact presentation is pending")
        try wait(model, "crop input Apply cleanup")
        try check(!model.geometryCropInputEnabled, "ordinary input remains released after exact completion")
    }

    static func straightenPreviewChecks(_ model: EditorModel) throws {
        try check(model.beginGeometryDraft(tab: .crop), "straighten preview opens a crop draft")
        try wait(model, draft: true, "straighten reference canvas")
        let image = model.result!.image
        var publications = 0
        let observer = model.$result.dropFirst().sink { _ in publications += 1 }
        defer { observer.cancel() }
        for angle in [-45.0, -22.5, -3, 0, 3, 22.5, 45] {
            model.setGeometryDraftParameter(.straightenDegrees, to: angle)
            try check(model.geometryDraftPreviewReady && !model.busy && model.result!.image === image,
                      "straighten \(angle) keeps the crop canvas ready without RAW work")
        }
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<600 {
            model.setGeometryDraftParameter(.straightenDegrees, to: Double(index % 91) - 45)
        }
        print(String(format: "BENCH: 600 model-only straighten updates %.2f ms; this is not native frame latency",
                     (ProcessInfo.processInfo.systemUptime - started) * 1000))
        settle(0.3)
        try check(publications == 0 && model.result!.image === image,
                  "straighten changes enqueue no delayed replacement of the reference image")
        let appliedGeometry = model.geometryDraftSettings
        try check(model.applyGeometryDraft() && model.pendingGeometryPresentation == appliedGeometry && model.result!.image === image,
                  "Apply retains its transformed crop presentation until the exact frame arrives")
        try check(!model.canComparePreview,
                  "pending Apply does not compare an untransformed neutral frame against the transformed base")
        try wait(model, "straighten Apply exact completion")
        try check(model.pendingGeometryPresentation == nil && model.canComparePreview,
                  "the matching exact frame clears pending presentation and restores comparison")
        let entryImage = model.result!.image
        try check(model.beginGeometryDraft(tab: .crop), "straighten Cancel opens another draft")
        try wait(model, draft: true, "straighten Cancel reference")
        model.setGeometryDraftParameter(.straightenDegrees, to: -30)
        model.cancelGeometryDraft()
        try check(model.result!.image === entryImage && model.pendingGeometryPresentation == nil,
                  "Cancel immediately restores the entry image without an unrotated flash")
        try wait(model, "straighten preview cleanup")
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure(description: "Could not create preview evidence")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "preview evidence writes to the isolated output directory")
    }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let originals = output.appendingPathComponent("raw-copies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let a = originals.appendingPathComponent("a.dng"), b = originals.appendingPathComponent("b.dng")
        for copy in [a, b] {
            try FileManager.default.copyItem(at: source, to: copy)
        }
        let original = try Data(contentsOf: source)
        let sourceIdentity = try OriginalFileIdentity(source)
        var committed = GeometrySettings()
        committed.cropX = 0.1; committed.cropY = 0.15
        committed.cropWidth = 0.7; committed.cropHeight = 0.6
        committed.perspectiveHorizontal = 0.08
        var lens = LensCorrectionSettings()
        lens.autoCrop = false
        try valueChecks(geometry: committed, lens: lens)

        let edits = output.appendingPathComponent("edits", isDirectory: true)
        let model = EditorModel(lookDirectory: output.appendingPathComponent("looks"), editDirectory: edits,
                                batchDirectory: output.appendingPathComponent("batch"))
        model.films = []; model.selectedFilmID = ""
        model.updatePreviewLongEdge(240)
        model.open(a)
        try wait(model, "initial real DNG")
        if let focus = ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"],
           ["native-close", "native-terminate", "native-departure"].contains(focus) {
            runNativeInputDepartureChecks(model, mode: focus)
            return
        }
        if ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"] == "workspace-reset" {
            try workspaceResetChecks(model, raw: a, edits: edits)
            print("PASS: \(checks) focused workspace reset checks")
            return
        }
        if ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"] == "crop-aspect-boundary" {
            try cropAspectBoundaryChecks(model, raw: a, edits: edits)
            print("PASS: \(checks) focused crop aspect boundary checks")
            return
        }
        if ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"] == "crop-input-routing" {
            try cropInputRoutingChecks(model)
            print("PASS: \(checks) focused crop input routing checks")
            return
        }
        if ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"] == "straighten-preview" {
            try straightenPreviewChecks(model)
            print("PASS: \(checks) focused straighten preview checks")
            return
        }
        if ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"] == "precise-crop-collapse" {
            runPreciseCropChecks(model)
            return
        }
        if ProcessInfo.processInfo.environment["RAWLAB_GEOMETRY_DRAFT_FOCUS"] == "crop-apply-publication" {
            try check(model.beginGeometryDraft(tab: .crop), "publication regression opens a crop draft")
            try wait(model, draft: true, "publication regression canvas")
            try cropApplyPublicationChecks(model)
            return
        }
        try workspaceResetChecks(model, raw: a, edits: edits)
        try cropAspectBoundaryChecks(model, raw: a, edits: edits)
        try cropInputRoutingChecks(model)
        try straightenPreviewChecks(model)
        try windowCloseChecks(model)
        model.settings.geometry = committed
        model.settings.lensCorrection = lens
        model.settings.exposure = 0.35
        try check(model.saveEdits(), "committed geometry, lens and color baseline saves")
        try wait(model, "committed baseline")
        let baselineSettings = model.settings
        let committedWidth = model.result!.nativeWidth!
        let registry = edits.appendingPathComponent("edits.json")
        let baselineRecord = try Data(contentsOf: registry)
        try check(model.prepareBatch(), "a batch window can be prepared before draft editing")

        try check(model.beginGeometryDraft(tab: .crop), "crop opens a transaction from the committed settings")
        try check(!model.geometryDraftPreviewReady && !model.geometryDraftCanApply && !model.applyGeometryDraft(),
                  "Apply is blocked until a matching draft canvas exists")
        try wait(model, draft: true, "uncropped draft")
        try check(model.result!.nativeWidth! > committedWidth && model.geometryDraft!.originalGeometry == committed &&
                  model.geometryDraft!.originalLens == lens, "draft removes crop for its canvas and retains both original snapshots")
        let canvas = model.result!.image
        var becameBusy = false
        let busyObserver = model.$busy.dropFirst().sink { becameBusy = becameBusy || $0 }
        model.setGeometryCropInteracting(true)
        try check(!model.geometryDraftCanApply && !model.busy, "crop pointer interaction blocks Apply without RAW work")
        for index in 0..<24 {
            model.updateGeometryDraft { $0.cropX = 0.12 + Double(index) * 0.001; $0.cropWidth = 0.5 }
            try check(!model.busy && model.result!.image === canvas, "crop update \(index + 1) reuses the existing frame")
        }
        model.setGeometryCropInteracting(false)
        settle(0.55)
        try check(!becameBusy && model.result!.image === canvas && model.geometryDraftCanApply,
                  "twenty-four crop changes and gesture completion enqueue no observable RAW work")
        busyObserver.cancel()
        try cropApplyPublicationChecks(model)
        model.setInteracting(true)
        settle(0.2)
        try check(model.busy && model.result!.image === canvas,
                  "numeric focus blocks Apply through interaction state and reuses the draft canvas")
        model.setInteracting(false)
        settle(0.2)
        try check(!model.busy && model.geometryDraftPreviewReady && model.result!.image === canvas,
                  "ending unchanged numeric focus schedules no draft render")
        try check(model.settings == baselineSettings && model.saveEdits() &&
                  saved(a, directory: edits) == baselineSettings && Data(contentsOf: registry) == baselineRecord,
                  "draft changes neither committed settings, explicit save nor the autosave registry")
        try check(!model.canApplySettings && !model.prepareBatch() && model.batch?.sourceEditingGeometry == true,
                  "copy settings and an already-open batch window are guarded during the transaction")
        var rejectedCopy = false
        do { _ = try model.applyCurrentSettings(to: [b]) } catch { rejectedCopy = true }
        try check(rejectedCopy, "direct copy cannot bypass the draft guard")
        try batchGuard(raw: a, output: output, settings: baselineSettings)

        let selectedCrop = model.geometryDraftSettings
        try check(model.selectGeometryDraftTab(.perspective) && model.beginGeometryDraft(tab: .lens) &&
                  model.geometryDraftSettings == selectedCrop && model.geometryDraft!.originalGeometry == committed && !model.busy,
                  "crop, perspective and lens tabs share one transaction without restarting its canvas")
        model.selectCropAspect(.square)
        try check(abs(physicalRatio(model) - 1) < 1e-6, "square crop uses the native physical canvas dimensions")
        model.setGeometryDraftParameter(.cropWidth, to: 0.3)
        try check(abs(model.geometryDraftSettings.cropWidth - 0.3) < 1e-6 && abs(physicalRatio(model) - 1) < 1e-6,
                  "precise crop width retains the selected square aspect")
        model.selectCropAspect(.threeTwo)
        try check(abs(physicalRatio(model) - 1.5) < 1e-6, "three-to-two preset uses physical dimensions")
        model.swapCropAspect()
        try check(model.cropAspectSwapped && abs(physicalRatio(model) - 2.0 / 3) < 1e-6,
                  "aspect swap fits the reciprocal physical ratio")
        model.selectCropAspect(.square)
        model.updateGeometryDraft {
            $0.quarterTurns = 1; $0.flipVertical = true
            $0.perspectiveHorizontal = 0.22; $0.perspectiveVertical = -0.18
        }
        try check(model.busy && !model.geometryDraftPreviewReady && !model.applyGeometryDraft() && model.settings == baselineSettings,
                  "nonzero transforms invalidate the prior canvas and rapid Apply preserves committed settings")
        try wait(model, draft: true, "rotation and H/V perspective draft")
        try check(abs(physicalRatio(model) - 1) < 1e-6 && model.geometryDraftCanApply,
                  "matching rotated canvas refits the physical square before enabling Apply")
        try check(delta(model.result!.image, canvas, side: 128) > 8,
                  "draft rotation and nonzero H/V perspective change actual DNG pixels")
        let direct = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF).render(a, settings: model.geometryPreviewSettings, lut: nil, edge: 240, viewportPreview: true)!
        try check(direct.nativeWidth == model.result!.nativeWidth && direct.nativeHeight == model.result!.nativeHeight &&
                  delta(direct.image, model.result!.image) <= 2, "fresh processor and reused editor session agree on the transformed draft")
        try write(model.result!.image, to: output.appendingPathComponent("transformed-draft-preview.png"))
        let geometryBeforeLens = model.geometryDraftSettings
        model.updateLensDraft { $0.distortion = true; $0.tca = true }
        try check(!model.geometryDraftPreviewReady && model.settings.lensSettings == lens &&
                  model.geometryDraftSettings == geometryBeforeLens, "lens draft is isolated from committed lens and geometry values")
        try wait(model, draft: true, "lens draft")
        let lensDraft = model.lensDraftSettings
        model.resetLensDraft()
        try check(model.lensDraftSettings == LensCorrectionSettings() && model.geometryDraftSettings == geometryBeforeLens &&
                  model.settings == baselineSettings, "lens reset changes only its draft")
        try wait(model, draft: true, "lens draft reset")
        model.updateLensDraft { $0 = lensDraft }
        try wait(model, draft: true, "restored lens draft")
        let appliedGeometry = model.geometryDraftSettings
        let fullDraftWidth = model.result!.nativeWidth!
        try check(model.applyGeometryDraft() && model.geometryDraft == nil && model.settings.geometrySettings == appliedGeometry &&
                  model.settings.lensSettings == lensDraft && saved(a, directory: edits) == model.settings,
                  "Apply atomically commits and saves the geometry and lens transaction")
        try wait(model, "applied crop")
        try check(model.result!.nativeWidth! < fullDraftWidth && model.settings.exposure == 0.35 &&
                  model.batch?.sourceEditingGeometry == false, "Apply renders the crop, preserves color and unlocks the batch")
        try check(model.batch?.job.settings == baselineSettings,
                  "the existing batch retains its frozen committed settings across a later draft Apply")

        try cancelChecks(model, raw: a, edits: edits)
        try inputCancellationChecks(model)
        try invalidAndDepartureChecks(model, raw: a, edits: edits)
        try fileSwitchChecks(model, a: a, b: b, edits: edits)
        try saveFailureChecks(model, a: a, b: b, edits: edits, output: output)
        try failedApplyCancellationChecks(model, a: a, b: b, edits: edits, output: output)
        try preexistingReadErrorChecks(raw: a, output: output)
        try check(try OriginalFileIdentity(source) == sourceIdentity && Data(contentsOf: source) == original &&
                  Data(contentsOf: a) == original && Data(contentsOf: b) == original, "all draft operations leave the original and copied RAW bytes unchanged")
        runPreciseCropChecks(model)
    }

}
