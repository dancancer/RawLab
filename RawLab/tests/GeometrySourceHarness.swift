import CryptoKit
import SwiftUI
import UIKit

// MARK: - Real ContentView source/restoration regression (test app only)

@MainActor
final class GeometrySourceProbe {
    static let shared = GeometrySourceProbe()
    var started = false
    var viewportEdges: [Int] = []
    var previewRequests: [RawSettings] = []
    var saveAttempts: [PhotoEditState] = []
    var checks: [String: Bool] = [:]
    var details: [String: String] = [:]
    var done = false

    func check(_ name: String, _ passed: Bool) {
        checks[name] = passed
        print("GEOMETRY_SOURCE \(passed ? "PASS" : "FAIL") \(name)")
    }

    var json: String {
        let value: [String: Any] = ["done": done, "checks": checks, "details": details,
                                  "viewportEdges": viewportEdges]
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
        do {
            try await geometryReviewWait { !editorBusy }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let persistence = try EditPersistence(directory: directory.appendingPathComponent("edits"))
            viewModel.editPersistence = persistence
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
                probe.check("\(action).ViewportAt1280", viewModel.previewLongEdge == 1280 &&
                            viewModel.requestedPreviewLongEdge == 1280 && probe.viewportEdges.last == 1280)
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
                    probe.check("\(prefix).RetryPreviewOnce", probe.previewRequests.count == beforePreviews + 1)
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
        } catch {
            probe.details["error"] = String(describing: error)
            probe.check("completedWithoutError", false)
        }
        probe.finish()
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
        try await geometryReviewWait { !viewModel.isBusy && !viewModel.previewRendering && !viewModel.previewResizePending }
        try await Task.sleep(for: .milliseconds(200))
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

    private func geometryReviewPreview() throws -> Data {
        let buffer = try viewModel.processor.processBuffer(buffer: viewModel.draftBuffer!, settings: draftPreviewSettings,
                                                          previewLongEdge: CGFloat(viewModel.previewLongEdge), lutURL: nil)
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
