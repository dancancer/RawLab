import AppKit
import Combine
import ImageIO
import Darwin
import SwiftUI

extension MacGeometryDraftTests {
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
