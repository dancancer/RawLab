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
        let direct = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF).render(a, settings: model.geometryPreviewSettings, lut: nil, edge: 240)!
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
        try invalidAndDepartureChecks(model, raw: a, edits: edits)
        try fileSwitchChecks(model, a: a, b: b, edits: edits)
        try saveFailureChecks(model, a: a, b: b, edits: edits, output: output)
        try failedApplyCancellationChecks(model, a: a, b: b, edits: edits, output: output)
        try preexistingReadErrorChecks(raw: a, output: output)
        try check(try OriginalFileIdentity(source) == sourceIdentity && Data(contentsOf: source) == original &&
                  Data(contentsOf: a) == original && Data(contentsOf: b) == original, "all draft operations leave the original and copied RAW bytes unchanged")
        runPreciseCropChecks(model)
    }

    @MainActor static func runPreciseCropChecks(_ model: EditorModel) {
        Task { @MainActor in
            do {
                try await preciseCropCollapseChecks(model)
                print("PASS: \(checks) macOS geometry/lens draft transaction checks")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func preciseCropCollapseChecks(_ model: EditorModel) async throws {
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        func nativeFields(_ view: NSView) -> [NumericTextField] {
            (view as? NumericTextField).map { [$0] } ?? view.subviews.flatMap(nativeFields)
        }
        for text in ["80", "invalid"] {
            try check(model.beginGeometryDraft(tab: .crop), "precise-collapse draft opens")
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline && (model.busy || !model.geometryDraftPreviewReady) {
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(!model.busy && model.geometryDraftPreviewReady, "precise-collapse matching preview completes")
            model.updateGeometryDraft { $0.cropX = 0; $0.cropWidth = 1 }
            let host = NSHostingView(rootView: GeometryControls(model: model, showsPreciseCrop: true))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 740, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close(); model.cancelGeometryDraft() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            try check(NSApp.keyWindow === window, "the test-owned offscreen window owns native input")
            guard let field = nativeFields(host).first(where: { $0.accessibilityIdentifier() == "geometry.value.cropWidth" }) else {
                throw Failure(description: "precise crop width native field is missing")
            }
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else {
                throw Failure(description: "precise crop field has no native field editor")
            }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(50))
            try check(model.busy, "uncommitted native typing owns the scheduler interaction")
            try check(model.geometryDraftSettings.cropWidth == 1, "typing has not yet committed the crop width")
            guard let firstField = nativeFields(host).first(where: { $0.accessibilityIdentifier() == "geometry.value.cropX" }) else {
                throw Failure(description: "precise crop first row is missing")
            }
            // The disclosure is 32 points above the first precise row in this fixed-size host.
            let row = firstField.convert(firstField.bounds, to: host)
            let point = host.convert(NSPoint(x: 19, y: row.midY + (host.isFlipped ? -32 : 32)), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
            try await Task.sleep(for: .milliseconds(200))
            if text == "80" {
                try check(!nativeFields(host).contains { $0.accessibilityIdentifier() == "geometry.value.cropWidth" },
                          "the hosted disclosure really collapsed its precise controls")
            }
            try check(!model.busy, "collapsing precise crop ends native numeric interaction")
            if text == "80" {
                try check(abs(model.geometryDraftSettings.cropWidth - 0.8) < 1e-9 && model.geometryDraftCanApply,
                          "collapse commits the legal crop width before removing its editor")
                try check(!nativeFields(host).contains { $0.accessibilityIdentifier() == "geometry.value.cropWidth" },
                          "legal collapse removes precise controls after the commit")
            } else {
                try check(model.invalidGeometryDraftInputs.contains("geometry.value.cropWidth") && !model.geometryDraftCanApply,
                          "collapse never accepts an invalid crop draft")
                try check(nativeFields(host).contains { $0 === field } && field.stringValue == text,
                          "an invalid precise draft remains visible for correction")
            }
        }
    }

    final class WindowDelegateProbe: NSObject, NSWindowDelegate {
        var closeChecks = 0
        var endedSheets = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { closeChecks += 1; return true }
        func windowDidEndSheet(_ notification: Notification) { endedSheets += 1 }
    }

    static func windowCloseChecks(_ model: EditorModel) throws {
        _ = NSApplication.shared
        for choice in [MacGeometryDeparture.discard, .apply, .stay] {
            try check(model.beginGeometryDraft(tab: .crop), "window-close draft opens")
            try wait(model, draft: true, "window-close draft")
            model.updateGeometryDraft { $0.cropX += 0.02; $0.cropWidth -= 0.04 }
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 200),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let proxy = MacGeometryWindowGuard.CloseDelegate(model: model)
            let previous = WindowDelegateProbe()
            proxy.previous = previous
            window.delegate = proxy
            window.orderFront(nil)
            defer { window.delegate = nil; window.close() }
            window.performClose(nil)
            try check(model.geometryDraftDeparturePending && window.isVisible,
                      "native close waits for the draft choice")
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            settle(0.1)
            model.resolveGeometryDraftDeparture(choice)
            try check(window.isVisible && window.attachedSheet === sheet,
                      "draft resolution does not close a window with its sheet attached")
            window.endSheet(sheet)
            settle(0.5)
            try check(window.isVisible == (choice == .stay),
                      "native close completes after sheet dismissal except for Stay (\(choice))")
            try check(previous.endedSheets == 1 && previous.closeChecks == (choice == .stay ? 0 : 1),
                      "the previous window delegate receives each applicable callback once")
            if choice == .stay {
                window.beginSheet(sheet)
                window.endSheet(sheet)
                settle(0.5)
                try check(window.isVisible && previous.endedSheets == 2 && previous.closeChecks == 0,
                          "an unrelated sheet after Stay never retries the old close request")
            }
            model.cancelGeometryDraft()
            try wait(model, "window-close cleanup")
        }
    }

    static func valueChecks(geometry: GeometrySettings, lens: LensCorrectionSettings) throws {
        var draft = MacGeometryDraft(geometry: geometry, lens: lens)
        try check(!draft.hasChanges && draft.originalGeometry == geometry && draft.originalLens == lens,
                  "draft snapshots geometry and lens originals")
        try check(draft.previewGeometry.cropX == 0 && draft.previewGeometry.cropY == 0 && draft.previewGeometry.cropWidth == 1 &&
                  draft.previewGeometry.cropHeight == 1 && draft.previewGeometry.straightenDegrees == 0 &&
                  draft.previewGeometry.perspectiveHorizontal == geometry.perspectiveHorizontal,
                  "draft preview removes crop and UI straightening while retaining other native transforms")
        draft.geometry.cropWidth = 0.5; draft.lens.distortion = true
        try check(draft.hasChanges && draft.originalGeometry == geometry && draft.originalLens == lens,
                  "draft geometry and lens changes retain immutable original snapshots")
    }

    static func batchGuard(raw: URL, output: URL, settings: Adjustments) throws {
        var job = BatchExportJob(source: raw, settings: settings, look: nil, lookName: "Neutral")
        var item = try BatchExportItem(url: raw)
        item.selected = true; job.items = [item]
        job.outputDirectory = output.appendingPathComponent("batch-output", isDirectory: true)
        let batch = BatchExportModel(job: job, journal: BatchJournal(directory: output.appendingPathComponent("guard-batch")))
        try check(batch.canRun, "a configured batch otherwise satisfies every run prerequisite")
        batch.sourceEditingGeometry = true
        batch.start()
        try check(!batch.canRun && !batch.running && !batch.job.started,
                  "sourceEditingGeometry independently prevents a valid batch from starting")
    }

    static func cancelChecks(_ model: EditorModel, raw: URL, edits: URL) throws {
        let committed = model.settings, image = model.result!.image
        let width = model.result!.nativeWidth, height = model.result!.nativeHeight
        let record = try Data(contentsOf: edits.appendingPathComponent("edits.json"))
        try check(model.beginGeometryDraft(tab: .perspective), "a new draft begins from the applied transaction")
        try wait(model, draft: true, "cancel test draft")
        model.updateGeometryDraft { $0.quarterTurns = 2; $0.perspectiveHorizontal = -0.4; $0.perspectiveVertical = 0.3 }
        settle(0.17) // Allow the exact-pass debounce to start pending native work before cancel.
        var publishedSizes: [CGSize] = []
        let observer = model.$result.dropFirst().sink { frame in
            if let frame { publishedSizes.append(CGSize(width: frame.nativeWidth!, height: frame.nativeHeight!)) }
        }
        model.cancelGeometryDraft()
        try wait(model, "cancelled pending or in-flight draft")
        settle(0.3)
        try check(model.geometryDraft == nil && model.settings == committed && model.result!.nativeWidth == width &&
                  model.result!.nativeHeight == height && delta(model.result!.image, image) <= 2,
                  "cancel and later draft completions restore committed geometry and pixels")
        try check(!publishedSizes.isEmpty && publishedSizes.allSatisfy { $0 == CGSize(width: width!, height: height!) } &&
                  Data(contentsOf: edits.appendingPathComponent("edits.json")) == record,
                  "no stale draft canvas publishes after cancel and cancel writes no edit record")
        observer.cancel()
    }

    static func invalidAndDepartureChecks(_ model: EditorModel, raw: URL, edits: URL) throws {
        let record = try Data(contentsOf: edits.appendingPathComponent("edits.json"))
        let committed = model.settings
        try check(model.beginGeometryDraft(tab: .crop), "invalid-input transaction opens")
        try wait(model, draft: true, "invalid-input draft")
        let valid = model.geometryDraft
        model.updateGeometryDraft { $0.perspectiveHorizontal = .nan }
        try check(model.geometryDraft == valid, "invalid geometry mutation leaves the entire valid draft unchanged")
        model.setGeometryDraftInputValidity(identifier: "geometry.value.cropWidth", isValid: false)
        try check(model.geometryDraftHasChanges && !model.geometryDraftCanApply && !model.applyGeometryDraft() &&
                  !model.selectGeometryDraftTab(.lens) && model.settings == committed,
                  "invalid text blocks Apply and tab switching without changing committed or draft numeric values")
        var leaves = 0, stays = 0, ignored = 0
        model.requestLeavingGeometryDraft({ leaves += 1 }, onStay: { stays += 1 })
        model.requestLeavingGeometryDraft({ ignored += 1 })
        model.resolveGeometryDraftDeparture(.apply)
        try check(model.geometryDraftDeparturePending && leaves == 0 && ignored == 0,
                  "invalid Apply preserves the pending departure and never runs a replacement action")
        model.resolveGeometryDraftDeparture(.stay); model.resolveGeometryDraftDeparture(.stay)
        try check(stays == 1 && leaves == 0 && !model.geometryDraftDeparturePending && model.geometryDraft != nil &&
                  !model.invalidGeometryDraftInputs.isEmpty, "Stay runs once and preserves an invalid draft for correction")
        model.setGeometryDraftInputValidity(identifier: "geometry.value.cropWidth", isValid: true)
        try check(model.geometryDraftCanApply && model.selectGeometryDraftTab(.lens),
                  "correcting invalid text restores Apply and tab switching without restarting the transaction")
        model.setGeometryDraftInputValidity(identifier: "geometry.value.cropWidth", isValid: false)
        model.requestLeavingGeometryDraft({ leaves += 1 })
        model.resolveGeometryDraftDeparture(.discard); model.resolveGeometryDraftDeparture(.discard)
        try wait(model, "invalid draft discarded")
        try check(leaves == 1 && model.geometryDraft == nil && model.invalidGeometryDraftInputs.isEmpty &&
                  Data(contentsOf: edits.appendingPathComponent("edits.json")) == record,
                  "Discard works with invalid text, runs once and does not save")

        try check(model.beginGeometryDraft(tab: .crop), "Apply-departure transaction opens")
        try wait(model, draft: true, "Apply-departure draft")
        model.setGeometryDraftParameter(.cropWidth, to: model.geometryDraftSettings.cropWidth * 0.9)
        let selected = model.geometryDraftSettings
        model.requestLeavingGeometryDraft({ leaves += 1 })
        model.resolveGeometryDraftDeparture(.apply); model.resolveGeometryDraftDeparture(.apply)
        try check(leaves == 2 && model.geometryDraft == nil && saved(raw, directory: edits).geometrySettings == selected,
                  "Apply departure saves the draft and invokes its pending action exactly once")
        try wait(model, "Apply departure committed")
        try check(model.beginGeometryDraft(tab: .lens), "unchanged departure transaction opens")
        try wait(model, draft: true, "unchanged departure draft")
        model.requestLeavingGeometryDraft({ leaves += 1 })
        try check(leaves == 3 && model.geometryDraft == nil && !model.geometryDraftDeparturePending,
                  "unchanged draft departs immediately without a confirmation")
        try wait(model, "unchanged draft departure")
    }

    static func fileSwitchChecks(_ model: EditorModel, a: URL, b: URL, edits: URL) throws {
        let committed = model.settings
        try check(model.beginGeometryDraft(tab: .crop), "file browser protection transaction opens")
        try wait(model, draft: true, "file browser draft")
        model.setGeometryDraftParameter(.cropWidth, to: model.geometryDraftSettings.cropWidth * 0.85)
        let draft = model.geometryDraft
        model.open(a)
        try check(model.file == a && model.geometryDraft == draft && !model.geometryDraftDeparturePending,
                  "clicking the already-open photo preserves its draft without a departure prompt")
        // FileBrowser passes its open callback directly to EditorModel.open.
        model.open(b)
        try check(model.file == a && model.geometryDraft == draft && model.geometryDraftDeparturePending,
                  "file browser open protects a changed draft instead of discarding it automatically")
        model.resolveGeometryDraftDeparture(.stay)
        try check(model.file == a && model.geometryDraft == draft && !model.geometryDraftDeparturePending,
                  "Stay cancels the photo switch and retains the source draft")
        model.open(b)
        model.resolveGeometryDraftDeparture(.discard)
        try wait(model, "discarded draft photo switch")
        try check(model.file == b && model.geometryDraft == nil && model.batch?.sourceEditingGeometry == false &&
                  saved(a, directory: edits) == committed, "Discard opens the target and leaves the source committed record unchanged")
        model.open(a)
        try wait(model, "source reopened")
        try check(model.settings == committed, "reopening the source restores committed geometry and lens rather than the discarded draft")
    }

    static func saveFailureChecks(_ model: EditorModel, a: URL, b: URL, edits: URL, output: URL) throws {
        let committed = model.settings
        try check(model.beginGeometryDraft(tab: .crop), "failed-save transaction opens while storage is healthy")
        try wait(model, draft: true, "failed-save draft")
        model.setGeometryDraftParameter(.cropWidth, to: model.geometryDraftSettings.cropWidth * 0.8)
        let draft = model.geometryDraft
        let selected = model.geometryDraftSettings
        let backup = output.appendingPathComponent("edit-store-backup", isDirectory: true)
        try FileManager.default.moveItem(at: edits, to: backup)
        try Data("blocked edit store".utf8).write(to: edits)
        defer {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.removeItem(at: edits)
                try? FileManager.default.moveItem(at: backup, to: edits)
            }
        }
        try check(!model.applyGeometryDraft() && model.saveError != nil && model.settings == committed &&
                  model.geometryDraft == draft && model.file == a, "failed Apply keeps committed settings, draft and source photo intact")
        var switches = 0
        let observer = model.$file.dropFirst().sink { if $0 == b { switches += 1 } }
        model.open(b)
        model.resolveGeometryDraftDeparture(.apply)
        try check(model.geometryDraftDeparturePending && model.geometryDraft == draft && model.settings == committed &&
                  model.file == a && switches == 0, "failed Apply-and-leave keeps its pending photo switch without exiting the session")
        try FileManager.default.removeItem(at: edits)
        try FileManager.default.moveItem(at: backup, to: edits)
        model.resolveGeometryDraftDeparture(.apply); model.resolveGeometryDraftDeparture(.apply)
        try wait(model, "repaired edit-store Apply-and-leave retry")
        try check(model.file == b && switches == 1 && model.geometryDraft == nil && !model.geometryDraftDeparturePending &&
                  saved(a, directory: edits).geometrySettings == selected && model.saveError == nil,
                  "repair and retry save the same draft and execute the original photo switch exactly once")
        observer.cancel()
        model.open(a)
        try wait(model, "retried edit reopened")
        try check(model.settings.geometrySettings == selected, "the retried draft survives reopening from disk")
        try check(model.beginGeometryDraft(tab: .lens), "geometry reset transaction opens")
        try wait(model, draft: true, "geometry reset draft")
        let lens = model.lensDraftSettings
        model.resetGeometryDraft()
        try check(model.geometryDraftSettings.isIdentity && model.lensDraftSettings == lens &&
                  model.settings.geometrySettings == selected, "geometry reset preserves the lens draft and changes no committed settings")
        try wait(model, draft: true, "geometry draft reset")
        try check(model.applyGeometryDraft() && saved(a, directory: edits).geometrySettings.isIdentity &&
                  saved(a, directory: edits).lensSettings == lens, "applying geometry reset persists identity and the independent lens draft")
        try wait(model, "geometry reset committed")
    }

    static func withBlockedEditStore(_ edits: URL, output: URL, action: (URL) throws -> Void) throws {
        let backup = output.appendingPathComponent("blocked-edit-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: edits, to: backup)
        defer {
            try? FileManager.default.removeItem(at: edits)
            try? FileManager.default.moveItem(at: backup, to: edits)
        }
        try Data("blocked edit store".utf8).write(to: edits)
        try action(backup)
    }

    static func failedApplyCancellationChecks(_ model: EditorModel, a: URL, b: URL, edits: URL, output: URL) throws {
        let committed = model.settings
        let record = try Data(contentsOf: edits.appendingPathComponent("edits.json"))
        try check(model.file == a && model.saveError == nil, "failed-Apply cancellation starts from a healthy saved source")
        try check(model.beginGeometryDraft(tab: .crop), "failed-Apply Cancel transaction opens")
        try wait(model, draft: true, "failed-Apply Cancel draft")
        model.setGeometryDraftParameter(.cropWidth, to: 0.8)
        let cancelDraft = model.geometryDraft
        try withBlockedEditStore(edits, output: output) { backup in
            try check(!model.applyGeometryDraft() && model.saveError != nil && model.geometryDraft == cancelDraft &&
                      model.settings == committed && model.file == a, "failed Apply retains the source transaction before Cancel")
            model.cancelGeometryDraft()
            try wait(model, "failed Apply then Cancel")
            try check(model.geometryDraft == nil && model.settings == committed && model.file == a && model.saveError == nil &&
                      !model.geometryDraftDeparturePending, "Cancel restores the entry error state and committed source after failed Apply")
            try check(model.saveEdits() && model.saveError == nil && Data(contentsOf: backup.appendingPathComponent("edits.json")) == record,
                      "dirty-false save after Cancel has no stale error and the committed disk record is unchanged")
        }
        try check(saved(a, directory: edits) == committed && Data(contentsOf: edits.appendingPathComponent("edits.json")) == record,
                  "restoring storage after Cancel reveals the unchanged committed edit")

        let target = try EditPersistence(directory: edits).state(for: b)?.settings ?? Adjustments()
        try check(model.beginGeometryDraft(tab: .crop), "failed pending Apply then Discard transaction opens")
        try wait(model, draft: true, "failed pending Apply then Discard draft")
        model.setGeometryDraftParameter(.cropWidth, to: 0.75)
        let discardDraft = model.geometryDraft
        var departures = 0
        try withBlockedEditStore(edits, output: output) { backup in
            model.requestLeavingGeometryDraft({ departures += 1; model.open(b) })
            model.resolveGeometryDraftDeparture(.apply)
            try check(model.geometryDraftDeparturePending && departures == 0 && model.saveError != nil &&
                      model.geometryDraft == discardDraft && model.settings == committed && model.file == a,
                      "failed pending Apply keeps the draft, source and deferred photo switch")
            model.resolveGeometryDraftDeparture(.discard)
            model.resolveGeometryDraftDeparture(.discard)
            try wait(model, "failed pending Apply then Discard")
            try check(departures == 1 && model.file == b && model.geometryDraft == nil && !model.geometryDraftDeparturePending &&
                      model.saveError == nil && model.settings.geometrySettings == target.geometrySettings &&
                      model.settings.lensSettings == target.lensSettings && model.settings.exposure == target.exposure,
                      "Discard clears only the draft-save error and opens the target with its own settings exactly once")
            try check(Data(contentsOf: backup.appendingPathComponent("edits.json")) == record,
                      "failed Apply then Discard leaves the complete edit registry unchanged")
        }
        model.open(a)
        try wait(model, "discarded failed Apply source reopened")
        try check(model.settings == committed && model.saveError == nil && saved(a, directory: edits) == committed &&
                  Data(contentsOf: edits.appendingPathComponent("edits.json")) == record,
                  "the source reopens with its unchanged committed settings and no discarded failure message")
    }

    static func preexistingReadErrorChecks(raw: URL, output: URL) throws {
        let directory = output.appendingPathComponent("unreadable-edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = directory.appendingPathComponent("edits.json")
        let corruptRecord = Data("unreadable edit registry".utf8)
        try corruptRecord.write(to: registry)
        let model = EditorModel(lookDirectory: output.appendingPathComponent("read-error-looks"), editDirectory: directory,
                                batchDirectory: output.appendingPathComponent("read-error-batch"))
        model.films = []; model.selectedFilmID = ""
        model.updatePreviewLongEdge(240)
        guard let entryError = model.saveError else { throw Failure(description: "missing preexisting registry read error") }
        model.open(raw)
        try wait(model, "preexisting read-error source")
        let committed = model.settings
        try check(model.saveError == entryError && model.beginGeometryDraft(tab: .crop),
                  "a dirty-false source enters a draft while retaining its preexisting registry read error")
        try wait(model, draft: true, "preexisting read-error draft")
        model.setGeometryDraftParameter(.cropWidth, to: 0.8)
        try check(!model.applyGeometryDraft() && model.saveError != nil && model.saveError != entryError,
                  "failed draft Apply reports its failure separately from the preexisting read error")
        model.cancelGeometryDraft()
        try wait(model, "preexisting read-error draft cancelled")
        try check(model.saveError == entryError && model.settings == committed && model.file == raw && model.geometryDraft == nil &&
                  Data(contentsOf: registry) == corruptRecord, "Cancel restores the exact preexisting read error rather than clearing unrelated feedback")
    }
}
