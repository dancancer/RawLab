import CryptoKit
import SwiftUI
import UIKit

// MARK: - Real ContentView source/restoration regression (test app only)

@MainActor
final class GeometrySourceProbe {
    static let shared = GeometrySourceProbe()
    var started = false
    var viewportEdges: [Int] = []
    struct PreviewReceipt {
        let source: UUID
        let settings: RawSettings
        let quality: RawEditorViewModel.PreviewQuality
        let longEdge: Int
        let resize: Bool
    }
    var previewRequests: [RawSettings] = []
    var previewReceipts: [PreviewReceipt] = []
    var isViewportResizeRequest = false

    func recordPreview(_ settings: RawSettings, request: RawEditorViewModel.PreviewRequest, source: UUID) {
        previewRequests.append(settings)
        previewReceipts.append(PreviewReceipt(source: source, settings: settings, quality: request.quality,
                                             longEdge: request.longEdge, resize: isViewportResizeRequest))
    }
    var saveAttempts: [PhotoEditState] = []
    var saveReceipts: [[String: Any]] = []
    var checks: [String: Bool] = [:]
    var details: [String: String] = [:]
    var editorState: (() -> [String: Any])?
    var replaceParameterSource: (() -> Void)?
    var done = false
    var layoutFrames: [String: [Double]] = [:]
    var layoutPolicy: [String: Any] = [:]
    var groupRects: [String: [Double]] = [:]
    var groupTextRects: [String: [Double]] = [:]

    func check(_ name: String, _ passed: Bool) {
        checks[name] = passed
        print("GEOMETRY_SOURCE \(passed ? "PASS" : "FAIL") \(name)")
    }

    private var nativeSwitches: [[Double]] {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return [] }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(window).compactMap { view in
            guard view is UISwitch else { return nil }
            let frame = view.convert(view.bounds, to: window)
            return [frame.minX, frame.minY, frame.width, frame.height]
        }
    }

    var json: String {
        let value: [String: Any] = ["editorState": editorState?() ?? [:], "saveAttemptCount": saveAttempts.count, "done": done, "checks": checks, "details": details,
                                  "saveReceipts": saveReceipts, "nativeSwitches": nativeSwitches, "viewportEdges": viewportEdges, "layoutFrames": layoutFrames, "layoutPolicy": layoutPolicy, "groupRects": groupRects, "groupTextRects": groupTextRects,
                                  "previewReceipts": previewReceipts.map { receipt -> [String: Any] in
                                      let settings = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt.settings))
                                      return ["source": receipt.source.uuidString, "settings": settings,
                                              "quality": String(describing: receipt.quality), "longEdge": receipt.longEdge,
                                              "resize": receipt.resize]
                                  }]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data, as: UTF8.self)
    }

    func finish() {
        done = true
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("geometry-source.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        print("GEOMETRY_SOURCE RESULT \(json)")
    }
}

extension ContentView {
    @MainActor
    func runGeometrySourceReview() async {
        let probe = GeometrySourceProbe.shared
        guard !probe.started else { return }
        probe.started = true
        probe.editorState = {
            ["fine": adjustmentFine, "sourceRevision": viewModel.sourceRevision.uuidString, "channel": hslChannel,
             "prepared": preparedReset != nil, "presented": resetConfirmationPresented,
             "waiting": resetWaitingForReady, "suspended": resetDraftSuspended,
             "draftExitPresented": draftExitPresented, "draftActive": isEditorDraftActive,
             "draftChanged": isEditorDraftChanged, "geometrySelected": geometrySelected,
             "freshGeometry": geometryDraft == settings.geometry,
             "tool": currentEditorTool.stableID, "busy": editorBusy,
             "rendering": viewModel.previewRendering, "resizePending": viewModel.previewResizePending,
             "settings": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))]
        }
        if ProcessInfo.processInfo.arguments.contains("-RawLab.workspaceUIOnly") {
            do {
                try await geometryReviewWait { !editorBusy }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let persistence = try EditPersistence(directory: directory.appendingPathComponent("edits"))
                viewModel.editPersistence = persistence
                viewModel.adjustmentSession = IOSAdjustmentTransferSession(store: persistence)
                let url = directory.appendingPathComponent("workspace-ui.png")
                try geometryReviewImage(url, color: .systemBlue)
                let identity = PhotoIdentity(resourceIdentifier: "workspace-ui")
                var fixture = RawSettings.default; fixture.exposure = 0.5
                if ProcessInfo.processInfo.arguments.contains("-RawLab.parameterInputUI") {
                    var full = HSLSettings(); full.set(.hue, channel: 0, value: 100)
                    fixture.hsl = full.scaled(by: 0.005)
                    let nextIdentity = PhotoIdentity(resourceIdentifier: "workspace-ui-next")
                    try persistence.save(nextIdentity, state: PhotoEditState(settings: fixture))
                    probe.replaceParameterSource = {
                        probe.details["sourceSwitch"] = "scheduled"
                        Task { @MainActor in
                            do {
                                try await geometryReviewImport(url, identity: nextIdentity)
                                probe.details["sourceSwitch"] = "completed"
                            } catch { probe.details["sourceSwitch"] = "failed: \(error)" }
                        }
                    }
                }
                try persistence.save(identity, state: PhotoEditState(settings: fixture))
                try await geometryReviewImport(url, identity: identity)
                activateEditorTool(.film)
                probe.check("uiFixture.CommittedExposure", settings.exposure == 0.5)
                probe.check("uiFixture.NoResetPresentation", preparedReset == nil && !resetConfirmationPresented && !draftExitPresented)
            } catch { probe.details["error"] = String(describing: error); probe.check("uiFixture.Completed", false) }
            probe.finish()
            return
        }
        do {
            try await geometryReviewWait { !editorBusy }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let persistence = try EditPersistence(directory: directory.appendingPathComponent("edits"))
            viewModel.editPersistence = persistence
            viewModel.adjustmentSession = IOSAdjustmentTransferSession(store: persistence)
            let aURL = directory.appendingPathComponent("A.png")
            let bURL = directory.appendingPathComponent("B.png")
            try geometryReviewImage(aURL, color: .systemRed)
            try geometryReviewImage(bURL, color: .systemBlue)
            let aID = PhotoIdentity(resourceIdentifier: "geometry-review-A")
            let bID = PhotoIdentity(resourceIdentifier: "geometry-review-B")
            var bSettings = RawSettings.default
            bSettings.exposure = 0.25
            bSettings.geometry.cropX = 0.25
            bSettings.geometry.cropY = 0.125
            bSettings.geometry.cropWidth = 0.5
            bSettings.geometry.cropHeight = 0.75
            try persistence.save(bID, state: PhotoEditState(settings: bSettings))

            for action in ["apply", "cancel", "editApply"] {
                if isEditorDraftActive { cancelEditorDraft() }
                try await geometryReviewImport(aURL, identity: aID)
                selectEditorTool(.geometry)
                try await geometryReviewSettled()
                probe.check("\(action).AUnchangedGeometry", geometrySelected && !isEditorDraftChanged)
                try await geometryReviewImport(bURL, identity: bID)
                probe.check("\(action).BSettingsRestored", settings == bSettings)
                probe.check("\(action).GeometryRemainsSelected", geometrySelected)
                probe.check("\(action).OverlayUsesBCrop", geometryDraftBinding.wrappedValue == bSettings.geometry)
                probe.check("\(action).NoDirtyDraft", !isEditorDraftChanged)
                let expectedViewport = UIDevice.current.userInterfaceIdiom == .pad ? 1280 : probe.viewportEdges.last
                probe.check("\(action).ViewportMatchesWindow", viewModel.previewLongEdge == expectedViewport &&
                            viewModel.requestedPreviewLongEdge == expectedViewport)
                let expected = try geometryReviewPreview()
                guard let actual = viewModel.previewImage?.pngData() else { throw EditorError.renderFailed }
                probe.check("\(action).UncroppedPreviewPixels", actual == expected)
                probe.check("\(action).UncroppedComparison", viewModel.basePreviewGeometry.cropWidth == 1 &&
                            viewModel.basePreviewGeometry.cropHeight == 1)
                probe.details["\(action).actualPreviewSHA256"] = geometryReviewDigest(actual)
                probe.details["\(action).expectedPreviewSHA256"] = geometryReviewDigest(expected)

                var committed = bSettings
                if action == "editApply" {
                    var edited = geometryDraftBinding.wrappedValue
                    edited.cropX = 0.125
                    geometryDraftBinding.wrappedValue = edited
                    try await geometryReviewSettled()
                    probe.check("editApply.DraftChanged", isEditorDraftChanged)
                    probe.check("editApply.DraftKeepsUncroppedPreview", viewModel.previewImage?.pngData() == (try geometryReviewPreview()))
                    committed.geometry = edited
                }
                if action == "cancel" { cancelEditorDraft() }
                else if action == "apply" {
                    let saves = probe.saveAttempts.count
                    applyEditorDraft()
                    probe.check("unchangedApply.NoSave", probe.saveAttempts.count == saves && geometrySelected)
                    cancelEditorDraft()
                } else { applyEditorDraft() }
                try await geometryReviewSettled()
                probe.check("\(action).CommittedCropCorrect", settings == committed && !isEditorDraftActive)
                probe.check("\(action).PersistedCropCorrect", persistence.state(for: bID)?.settings == committed)
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    viewModel.exportJPEG(settings: settings) { continuation.resume(with: $0) }
                }
                let raster = try viewModel.processor.loadRasterBuffer(url: viewModel.sourceFile!.withReadAccess({ $0 }), applyingOrientation: true)
                let buffer = try viewModel.processor.processBuffer(buffer: raster.buffer, settings: committed,
                                                                  previewLongEdge: nil, lutURL: nil)
                let reference = try viewModel.processor.makeJPEGData(from: buffer, sourceURL: viewModel.sourceFile!.withReadAccess({ $0 }),
                                                                   orientation: raster.orientation, quality: 0.92)
                guard let exportedPixels = UIImage(data: data)?.pngData(),
                      let referencePixels = UIImage(data: reference)?.pngData() else { throw EditorError.renderFailed }
                probe.check("\(action).ExportPixelsCorrect", exportedPixels == referencePixels)
                // Restore the fixture for the following independent transition.
                try persistence.save(bID, state: PhotoEditState(settings: bSettings))
            }

            if isEditorDraftActive { cancelEditorDraft() }
            try await geometryReviewImport(bURL, identity: bID)
            selectEditorTool(.geometry)
            try await geometryReviewSettled()
            var pairedLens = settings
            pairedLens.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, autoCrop: false)
            lensDraft = pairedLens
            try await geometryReviewSettled()
            probe.check("pairedDraft.LensChangeDetectedWithUnchangedGeometry", isEditorDraftChanged)
            probe.check("pairedDraft.ProjectsBothObjects", effectivePreviewSettings.geometry == bSettings.geometry &&
                        effectivePreviewSettings.lensCorrection == pairedLens.lensCorrection)
            let pairSaves = probe.saveAttempts.count
            guard case .prepared(let geometryReset) = prepareEditorReset(.group(.geometry)) else {
                throw NSError(domain: "GeometrySourceHarness", code: 2)
            }
            probe.check("pairedReset.Accepted", commitEditorReset(geometryReset))
            probe.check("pairedReset.KeepsCommitted", settings == bSettings)
            probe.check("pairedReset.ResetsBothDraftObjects", geometryDraft == GeometrySettings() &&
                        lensDraft?.lensSettings == LensCorrectionSettings())
            try await geometryReviewSettled()
            probe.check("pairedReset.DoesNotPersist", probe.saveAttempts.count == pairSaves)
            if case .blocked = prepareEditorReset(.all) { probe.check("pairedReset.FullResetBlocked", true) }
            else { probe.check("pairedReset.FullResetBlocked", false) }
            cancelEditorDraft()
            try await geometryReviewSettled()
            probe.check("pairedDraft.CancelKeepsCommitted", settings == bSettings && geometryDraft == nil && lensDraft == nil)

            let resetSaves = probe.saveAttempts.count
            let resetPreviews = probe.previewRequests.count
            guard case .prepared(let ordinaryReset) = prepareEditorReset(.group(.light)) else {
                throw NSError(domain: "GeometrySourceHarness", code: 3)
            }
            probe.check("ordinaryReset.Accepted", commitEditorReset(ordinaryReset))
            probe.check("ordinaryReset.UsesObserverSave", probe.saveAttempts.count == resetSaves)
            try await geometryReviewSettled()
            probe.check("ordinaryReset.OneSaveOnePreview", probe.saveAttempts.count == resetSaves + 1 &&
                        probe.previewRequests.count == resetPreviews + 1)
            probe.check("ordinaryReset.KeepsUnrelatedCrop", settings.exposure == 0 && settings.geometry == bSettings.geometry)
            let idleSaves = probe.saveAttempts.count
            let idlePreviews = probe.previewRequests.count
            if case .unchanged = prepareEditorReset(.group(.light)) { probe.check("ordinaryReset.Unchanged", true) }
            else { probe.check("ordinaryReset.Unchanged", false) }
            guard case .prepared(let cancelledReset) = prepareEditorReset(.all) else {
                throw NSError(domain: "GeometrySourceHarness", code: 4)
            }
            let originalWB = viewModel.rawWhiteBalance
            viewModel.rawWhiteBalance = .init(temperature: 5100, tint: 7, isCalibrated: true)
            probe.check("ordinaryReset.StaleContextRejected", !commitEditorReset(cancelledReset))
            viewModel.rawWhiteBalance = originalWB
            try await geometryReviewSettled()
            probe.check("ordinaryReset.UnchangedStaleCancelledHaveNoEffects", probe.saveAttempts.count == idleSaves &&
                        probe.previewRequests.count == idlePreviews)

            // Film metadata can change while every RawSettings field stays equal.
            let metadataOnlySettings = settings
            try persistence.save(bID, state: PhotoEditState(settings: metadataOnlySettings, filmID: "legacy-film"))
            try await geometryReviewImport(bURL, identity: bID)
            let metadataSaves = probe.saveAttempts.count
            guard case .prepared(let metadataReset) = prepareEditorReset(.group(.looks)) else {
                throw NSError(domain: "GeometrySourceHarness", code: 5)
            }
            probe.check("metadataOnlyReset.Accepted", commitEditorReset(metadataReset))
            try await geometryReviewSettled()
            probe.check("metadataOnlyReset.PersistedOnce", persistence.state(for: bID)?.filmID == nil &&
                        probe.saveAttempts.count == metadataSaves + 1 && settings == metadataOnlySettings)

            // A failed write must leave the real ContentView draft and navigation untouched.
            for navigation in [false, true] {
                if isEditorDraftActive { cancelEditorDraft() }
                try persistence.save(bID, state: PhotoEditState(settings: bSettings))
                try await geometryReviewImport(bURL, identity: bID)
                selectEditorTool(.geometry)
                var failedDraft = geometryDraftBinding.wrappedValue
                failedDraft.cropX = 0.125
                geometryDraftBinding.wrappedValue = failedDraft
                try await geometryReviewSettled()
                let prefix = navigation ? "failedNavigation" : "failedApply"
                let beforeApply = settings
                let beforeRecord = persistence.state(for: bID)
                let beforePreviews = probe.previewRequests.count
                let beforeSaves = probe.saveAttempts.count
                viewModel.queueSettingsSave(beforeApply)
                let blockedDirectory = persistence.directory
                let retainedDirectory = directory.appendingPathComponent("retained-edits")
                let beforeBytes = try Data(contentsOf: blockedDirectory.appendingPathComponent("edits.json"))
                try FileManager.default.moveItem(at: blockedDirectory, to: retainedDirectory)
                try Data("blocked".utf8).write(to: blockedDirectory)
                probe.details[prefix + ".beforeAttempt"] = "busy=\(editorBusy), rendering=\(viewModel.previewRendering), resizePending=\(viewModel.previewResizePending), slider=\(isAdjustingSlider), prepared=\(viewModel.prepareDraft(settings: settings, revision: settingsRevision, draft: editorDraftSnapshot) != nil), previews=\(probe.previewRequests.count)"
                if navigation {
                    selectEditorTool(.lens)
                    finishDraftNavigation(apply: true)
                } else {
                    applyEditorDraft()
                }
                probe.check("\(prefix).KeepsCommitted", settings == beforeApply)
                probe.check("\(prefix).KeepsDraft", geometryDraft == failedDraft && geometrySelected)
                probe.check("\(prefix).KeepsRecord", persistence.state(for: bID) == beforeRecord)
                probe.check("\(prefix).KeepsDiskBytes", try Data(contentsOf: retainedDirectory.appendingPathComponent("edits.json")) == beforeBytes)
                probe.check("\(prefix).NoPreview", probe.previewRequests.count == beforePreviews)
                probe.check("\(prefix).TriedCandidate", probe.saveAttempts.count == beforeSaves + 1)
                probe.check("\(prefix).KeepsDestination", pendingToolSelection == (navigation ? .lens : nil))
                if case .failed = viewModel.editSaveState { probe.check("\(prefix).ErrorVisible", true) }
                else { probe.check("\(prefix).ErrorVisible", false) }
                try FileManager.default.removeItem(at: blockedDirectory)
                try FileManager.default.moveItem(at: retainedDirectory, to: blockedDirectory)
                if isEditorDraftChanged {
                    retryEditorSave()
                    try await geometryReviewSettled()
                    probe.check("\(prefix).RetryPersistsCandidate", persistence.state(for: bID)?.settings.geometry == failedDraft)
                    let retryRequests = Array(probe.previewRequests.dropFirst(beforePreviews))
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        probe.check("\(prefix).RetryPreviewOnce", retryRequests.count == 1)
                    } else {
                        let receipts = Array(probe.previewReceipts.dropFirst(beforePreviews))
                        probe.check("\(prefix).RetryPreviewAndResizeUseCommittedSnapshot", !receipts.isEmpty &&
                                    receipts.allSatisfy { $0.source == viewModel.sourceRevision && $0.settings == settings && $0.quality == .final })
                        probe.check("\(prefix).RetryAdditionalRequestsAreViewportChanges", receipts.first?.resize == false &&
                                    receipts.dropFirst().allSatisfy { $0.resize } &&
                                    zip(receipts, receipts.dropFirst()).allSatisfy { $0.longEdge != $1.longEdge } &&
                                    receipts.last?.longEdge == viewModel.requestedPreviewLongEdge)

                    }
                    probe.check("\(prefix).RetrySavesOnce", probe.saveAttempts.count == beforeSaves + 2 && viewModel.pendingSettings == nil)
                    probe.check("\(prefix).RetryLeavesOnce", navigation ? lensSelected : (!isEditorDraftActive && selectedAdjustment == .exposure))
                    probe.check("\(prefix).ClearsDestination", pendingToolSelection == nil)
                    probe.check("\(prefix).ObserverConsumedCandidate", !viewModel.consumePersistedEditorSettings(settings))
                    if !navigation {
                        let followSaves = probe.saveAttempts.count
                        let followPreviews = probe.previewRequests.count
                        var following = settings
                        following.exposure += 0.1
                        applySettingsChange(following)
                        try await geometryReviewSettled()
                        probe.check("savedObserver.FollowingOrdinaryEditPersists", persistence.state(for: bID)?.settings == following &&
                                    probe.saveAttempts.count == followSaves + 1 && probe.previewRequests.count == followPreviews + 1)
                    }
                }
                viewModel.editSaveWork?.cancel()
                viewModel.pendingSettings = nil
            }

            for resolve in ["cancel", "revert"] {
                if isEditorDraftActive { cancelEditorDraft() }
                selectEditorTool(.geometry)
                var edited = settings.geometry
                edited.cropX = 0.2
                geometryDraftBinding.wrappedValue = edited
                try await geometryReviewSettled()
                let blocked = persistence.directory
                let retained = directory.appendingPathComponent("resolve-retained")
                try FileManager.default.moveItem(at: blocked, to: retained)
                try Data("blocked".utf8).write(to: blocked)
                selectEditorTool(.film)
                finishDraftNavigation(apply: true)
                probe.check("\(resolve)FailedDraft.HasFailure", viewModel.hasFailedDraftSave && pendingToolSelection == .film)
                try FileManager.default.removeItem(at: blocked)
                try FileManager.default.moveItem(at: retained, to: blocked)
                if resolve == "cancel" { cancelEditorDraft() }
                else {
                    geometryDraftBinding.wrappedValue = settings.geometry
                    try await geometryReviewSettled()
                    selectEditorTool(.adjustment(.exposure))
                }
                try await geometryReviewSettled()
                probe.check("\(resolve)FailedDraft.ClearsFailureAndDestination", !viewModel.hasFailedDraftSave &&
                            pendingToolSelection == nil && !isEditorDraftActive && selectedAdjustment == .exposure)
                probe.check("\(resolve)FailedDraft.AllowsNormalSaveGate", viewModel.saveCurrentSettings(settings))
            }
            try await reviewWorkspaceGroups(persistence: persistence, url: bURL, identity: bID)
        } catch {
            probe.details["error"] = String(describing: error)
            probe.check("completedWithoutError", false)
        }
        probe.finish()
    }

    @MainActor
    private func reviewWorkspaceGroups(persistence: EditPersistence, url: URL, identity: PhotoIdentity) async throws {
        let probe = GeometrySourceProbe.shared
        if isEditorDraftActive { cancelEditorDraft() }
        try await geometryReviewSettled()
        let navigationSaves = probe.saveAttempts.count
        let navigationPreviews = probe.previewRequests.count
        for group in [EditorAdjustmentGroup.looks, .light, .color, .effects, .detail] {
            if selectedGroup == group { selectEditorGroup(group) }
            selectEditorGroup(group)
            probe.check("workspace.default.\(group)", currentEditorTool == EditorAdjustmentRules.defaultTool(group) && adjustmentsExpanded)
            selectEditorGroup(group)
            probe.check("workspace.collapse.\(group)", !adjustmentsExpanded)
            selectEditorGroup(group)
        }
        try await geometryReviewSettled()
        probe.check("workspace.NavigationNoSaveOrPreview", probe.saveAttempts.count == navigationSaves && probe.previewRequests.count == navigationPreviews)
        selectEditorGroup(.color)
        selectEditorTool(.adjustment(.hsl))
        hslChannel = 6
        selectEditorGroup(.light)
        selectEditorGroup(.color)
        selectEditorTool(.adjustment(.hsl))
        probe.check("workspace.HSLChannelSurvivesRouting", hslChannel == 6)

        for apply in [false, true] {
            if isEditorDraftActive { cancelEditorDraft() }
            var fixture = RawSettings.default
            fixture.geometry.cropX = 0.1; fixture.geometry.cropWidth = 0.8
            try persistence.save(identity, state: PhotoEditState(settings: fixture))
            try await geometryReviewImport(url, identity: identity)
            activateEditorTool(.geometry)
            geometryDraftBinding.wrappedValue.cropX = 0.2
            try await geometryReviewSettled()
            let prefix = "workspace.Collapse.\(apply ? "apply" : "discard")"
            requestAdjustmentExpansion(false)
            probe.check(prefix + ".AsksDirtyDraft", draftExitPresented && adjustmentsExpanded)
            cancelDraftNavigation(); draftExitPresented = false
            probe.check(prefix + ".StayKeepsDraft", isEditorDraftChanged && adjustmentsExpanded && geometrySelected)
            requestAdjustmentExpansion(false)
            let saves = probe.saveAttempts.count
            finishDraftNavigation(apply: apply)
            try await geometryReviewSettled()
            probe.check(prefix + ".CollapsedInactive", !adjustmentsExpanded && !isEditorDraftActive && !geometrySelected && !lensSelected)
            probe.check(prefix + ".CommittedPixels", viewModel.previewImage?.pngData() == (try geometryReviewPreview(settings: settings)))
            probe.details[prefix + ".actualSHA256"] = geometryReviewDigest(viewModel.previewImage?.pngData())
            probe.details[prefix + ".viewportReferenceSHA256"] = geometryReviewDigest(try geometryReviewPreview(settings: settings))
            probe.details[prefix + ".nonViewportReferenceSHA256"] = geometryReviewDigest(try geometryReviewPreview(settings: settings, viewportPreview: false))
            probe.check(prefix + ".ExportGateReleased", !isEditorDraftActive && !editorBusy && !viewModel.previewRendering && !viewModel.previewResizePending && viewModel.isLookAvailable(for: settings))
            probe.check(prefix + ".SaveCount", probe.saveAttempts.count == saves + (apply ? 1 : 0))
            requestAdjustmentExpansion(true)
            try await geometryReviewSettled()
            probe.check(prefix + ".FreshDraftOnReopen", geometrySelected && !isEditorDraftChanged && geometryDraft == settings.geometry)
            probe.check(prefix + ".UncroppedOnReopen", viewModel.previewImage?.pngData() == (try geometryReviewPreview()))
            let unchangedSaves = probe.saveAttempts.count
            requestAdjustmentExpansion(false)
            try await geometryReviewSettled()
            probe.check(prefix + ".UnchangedCollapseInactive", !isEditorDraftActive && !adjustmentsExpanded && !geometrySelected)
            probe.check(prefix + ".UnchangedCollapseCommittedPixels", viewModel.previewImage?.pngData() == (try geometryReviewPreview(settings: settings)))
            probe.check(prefix + ".UnchangedCollapseNoSave", probe.saveAttempts.count == unchangedSaves)
            requestAdjustmentExpansion(true)
            cancelEditorDraft()
            try await geometryReviewSettled()
        }

        for version in [RawSettings.default.processing, try JSONDecoder().decode(RawSettings.self, from: Data("{}".utf8)).processing] {
            for apply in [false, true] {
                if isEditorDraftActive { cancelEditorDraft() }
                var fixture = RawSettings.default
                fixture.processing = version
                fixture.exposure = 0.5
                fixture.geometry.cropX = 0.1; fixture.geometry.cropWidth = 0.8
                try persistence.save(identity, state: PhotoEditState(settings: fixture, filmID: "detached-film"))
                try await geometryReviewImport(url, identity: identity)
                activateEditorTool(.geometry)
                geometryDraftBinding.wrappedValue.quarterTurns = 1
                try await geometryReviewSettled()
                let prefix = "workspace.All.\(version.version).\(apply ? "apply" : "discard")"
                let beforeResolutionSaves = probe.saveAttempts.count
                requestEditorReset(.all)
                probe.check(prefix + ".AsksDraftFirst", draftExitPresented && preparedReset == nil)
                cancelDraftNavigation()
                draftExitPresented = false
                probe.check(prefix + ".StayKeepsDirtyDraft", isEditorDraftChanged && resetRestoreTool == nil)
                requestEditorReset(.all)
                finishDraftNavigation(apply: apply)
                try await geometryReviewSettled()
                probe.check(prefix + ".IndependentConfirmation", resetConfirmationPresented && preparedReset != nil && resetDraftSuspended)
                let resolved = settings
                probe.check(prefix + ".ResolutionPreservesVersion", resolved.processing == version && resolved.geometry.quarterTurns == (apply ? 1 : 0))
                cancelEditorReset()
                resetConfirmationPresented = false
                try await geometryReviewSettled()
                probe.check(prefix + ".CancelKeepsResolvedState", settings == resolved && geometrySelected && !isEditorDraftChanged && geometryDraft == resolved.geometry)
                probe.check(prefix + ".CancelNoExtraSave", probe.saveAttempts.count == beforeResolutionSaves + (apply ? 1 : 0))
                probe.check(prefix + ".CancelReentersUncroppedPreview", viewModel.previewImage?.pngData() == (try geometryReviewPreview()))
                requestEditorReset(.all)
                try await geometryReviewSettled()
                confirmEditorReset()
                resetConfirmationPresented = false
                try await geometryReviewSettled()
                probe.check(prefix + ".ConfirmFreshDraft", geometrySelected && !isEditorDraftChanged && geometryDraft == settings.geometry)
                probe.check(prefix + ".ConfirmPreservesVersion", settings.processing == version && settings.exposure == 0 && settings.geometry.isIdentity && persistence.state(for: identity)?.filmID == nil)
                let noOpSaves = probe.saveAttempts.count
                let noOpPreviews = probe.previewRequests.count
                requestEditorReset(.all)
                try await geometryReviewSettled()
                probe.check(prefix + ".NeutralNoEffects", preparedReset == nil && !resetDraftSuspended && !isEditorDraftChanged && probe.saveAttempts.count == noOpSaves && probe.previewRequests.count == noOpPreviews)
                cancelEditorDraft()
            }
        }
        try await geometryReviewSettled()
        activateEditorTool(.geometry)
        geometryDraftBinding.wrappedValue.quarterTurns = 1
        var lens = settings
        lens.lensCorrection = LensCorrectionSettings(mode: .manual, profileID: "disabled-workspace-profile")
        lensDraft = lens
        try await geometryReviewSettled()
        guard case .prepared(let geometryOnly) = prepareEditorReset(.tool(.geometry)) else { throw EditorError.renderFailed }
        probe.check("workspace.GeometryToolAccepted", commitEditorReset(geometryOnly))
        probe.check("workspace.GeometryToolKeepsLens", geometryDraft?.isIdentity == true && lensDraft?.lensCorrection == lens.lensCorrection)
        if case .blocked = prepareEditorReset(.tool(.lens)) { probe.check("workspace.WrongDraftKindBlocked", true) }
        else { probe.check("workspace.WrongDraftKindBlocked", false) }
        cancelEditorDraft()
        try await geometryReviewSettled()
        var staleSettings = settings; staleSettings.exposure = 0.5
        applySettingsChange(staleSettings)
        try await geometryReviewSettled()
        guard case .prepared(let prepared) = prepareEditorReset(.tool(.adjustment(.exposure))) else { throw EditorError.renderFailed }
        var changedVersion = settings
        changedVersion.processing = settings.processing == .current ? .legacy : .current
        applySettingsChange(changedVersion)
        try await geometryReviewSettled()
        let saves = probe.saveAttempts.count
        let previews = probe.previewRequests.count
        probe.check("workspace.ProcessingChangeRejectsPrepared", !commitEditorReset(prepared))
        probe.check("workspace.StaleResetNoEffects", probe.saveAttempts.count == saves && probe.previewRequests.count == previews)
        // Leave a real imported image available for the XCTest navigation pass.
        selectEditorGroup(.looks)
        if !adjustmentsExpanded { selectEditorGroup(.looks) }
    }

    @MainActor
    private func geometryReviewImport(_ url: URL, identity: PhotoIdentity) async throws {
        _ = viewModel.saveCurrentSettings(settings)
        isImporting = true
        viewModel.importImage(from: .raster(url), identity: identity, onSettingsRestored: { settings = $0 })
        try await geometryReviewWait { !viewModel.isBusy && viewModel.sourceIdentity == identity }
        try await geometryReviewSettled()
    }

    @MainActor
    private func geometryReviewSettled() async throws {
        try await Task.sleep(for: .milliseconds(600))
        try await geometryReviewWait { !editorBusy && !viewModel.previewRendering && !viewModel.previewResizePending && !isAdjustingSlider }
        try await Task.sleep(for: .milliseconds(200))
        let probe = GeometrySourceProbe.shared
        probe.details["settled.pending.\(probe.details.count)"] = "waiting=\(resetWaitingForReady), suspended=\(resetDraftSuspended), prepared=\(preparedReset != nil), presented=\(resetConfirmationPresented)"
        // 等现有 onChange 消费 reset intent；布局也可能在等待期间发出 resize。
        // 返回后动作与这次 gate 复核在同一 MainActor 段执行，不重试动作。
        try await geometryReviewWait { !editorBusy && !viewModel.previewRendering && !viewModel.previewResizePending && !isAdjustingSlider && !resetWaitingForReady }
        probe.details["settled.\(probe.details.count)"] = "busy=\(editorBusy), rendering=\(viewModel.previewRendering), resizePending=\(viewModel.previewResizePending), previews=\(probe.previewRequests.count), edges=\(probe.viewportEdges.count)"
    }

    @MainActor
    private func geometryReviewWait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "GeometrySourceHarness", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for source/render"])
    }

    private func geometryReviewPreview(settings: RawSettings? = nil, viewportPreview: Bool = true) throws -> Data {
        let buffer = try viewModel.processor.processBuffer(buffer: viewModel.draftBuffer!, settings: settings ?? draftPreviewSettings,
                                                          previewLongEdge: CGFloat(viewModel.previewLongEdge), lutURL: nil, viewportPreview: viewportPreview)
        guard let data = viewModel.processor.makeUIImage(from: buffer, orientation: viewModel.sourceOrientation)?.pngData()
        else { throw EditorError.renderFailed }
        return data
    }

    private func geometryReviewDigest(_ data: Data?) -> String {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "nil"
    }

    private func geometryReviewImage(_ url: URL, color: UIColor) throws {
        let size = CGSize(width: 2400, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for index in 0..<8 {
                UIColor(white: CGFloat(index) / 8, alpha: 1).setFill()
                context.fill(CGRect(x: index * 300, y: 0, width: 150, height: 1600))
            }
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        try image.pngData()!.write(to: url)
    }
}

@MainActor
final class GeometryReviewLabel: UILabel {
    override var accessibilityValue: String? {
        get { GeometrySourceProbe.shared.json }
        set { }
    }
}

@MainActor
final class GeometrySourceSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ContentView().environment(\.locale, Locale(identifier: "en")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let probe = GeometryReviewLabel(frame: CGRect(x: 10, y: 30, width: 300, height: 20))
        probe.text = "Geometry source review"
        probe.textColor = .white
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "geometry.review.probe"
        host.view.addSubview(probe)
        if ProcessInfo.processInfo.arguments.contains("-RawLab.parameterInputUI") {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                DispatchQueue.main.async { GeometrySourceProbe.shared.replaceParameterSource?() }
            }, "com.rawlab.tests.parameter-inputs.next-source" as CFString, nil, .deliverImmediately)
        }
        self.window = window
    }
}

@main
@MainActor
final class GeometrySourceApplication: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Geometry Source Review", sessionRole: session.role)
        configuration.delegateClass = GeometrySourceSceneDelegate.self
        return configuration
    }
}
