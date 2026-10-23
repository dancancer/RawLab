import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class ViewingEditorProbe {
    static let shared = ViewingEditorProbe()
    var started = false
    var failNextSave = false
    var failIdentity: String?
    var transferTarget: PhotoIdentity?
    var externalEdit: (() -> Void)?
    var resizing = false
    var saves: [[String: Any]] = []
    var previews: [[String: Any]] = []
    var readEditor: (() -> [String: Any])?
    var clearReference: (() -> Void)?
    var clearStatistics: (() -> Void)?
    var histogramTransitions: [[String: Any]] = []
    var histogramDrawing: [String: [Int]] = [:]

    func histogramInfo(_ histogram: Sony2FujiProcessor.RGBHistogram?) -> [String: Any] {
        guard let histogram else { return [:] }
        let bytes = try! JSONEncoder().encode(histogram.counts)
        return ["size": [histogram.width, histogram.height], "peak": histogram.peak,
                "hash": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "sums": (0..<3).map { channel in
                    histogram.counts[(channel * 256)..<((channel + 1) * 256)].reduce(UInt64(0)) { $0 + UInt64($1) }
                }]
    }

    func recordHistogram(_ histogram: Sony2FujiProcessor.RGBHistogram?, showingBefore: Bool) {
        var sample = histogramInfo(histogram)
        sample["before"] = showingBefore
        histogramTransitions.append(sample)
    }

    func sampleHistogramDrawing() {
        var counts = [UInt32](repeating: 0, count: 768)
        for (bin, mask, count) in [(10, 1, 4), (20, 2, 4), (30, 4, 4),
                                   (40, 3, 2), (50, 5, 2), (60, 6, 2), (70, 7, 2)] {
            for channel in 0..<3 where mask & (1 << channel) != 0 { counts[channel * 256 + bin] = UInt32(count) }
        }
        let histogram = Sony2FujiProcessor.RGBHistogram(width: 10, height: 1, counts: counts)!
        let renderer = ImageRenderer(content: HistogramView(histogram: histogram).frame(width: 1024, height: 80).background(.black))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return }
        var bytes = [UInt8](repeating: 0, count: 1024 * 80 * 4)
        bytes.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: 1024, height: 80, bitsPerComponent: 8,
                bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 80))
        }
        for bin in [10, 20, 30, 40, 50, 60, 70] {
            let offset = (76 * 1024 + bin * 4 + 2) * 4
            histogramDrawing[String(bin)] = bytes[offset..<(offset + 4)].map(Int.init)
        }
    }

    func settingsText(_ settings: RawSettings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(settings), encoding: .utf8)!
    }
    func recordPreview(_ request: RawEditorViewModel.PreviewRequest, source: UUID) {
        previews.append(["source": source.uuidString, "exposure": request.settings.exposure,
                         "crop": request.settings.geometry.cropWidth,
                         "settings": settingsText(request.settings),
                         "quality": String(describing: request.quality), "edge": request.longEdge, "resize": resizing])
    }
    func recordSave(_ state: PhotoEditState?, identity: PhotoIdentity) throws {
        let failed = failNextSave || failIdentity == identity.key
        saves.append(["identity": identity.key, "exposure": state?.settings.exposure as Any? ?? NSNull(),
                      "crop": state?.settings.geometry.cropWidth as Any? ?? NSNull(),
                      "settings": state.map { settingsText($0.settings) } ?? "null", "failed": failed])
        if failed { failNextSave = false; failIdentity = nil; throw CocoaError(.fileWriteNoPermission) }
    }
    func snapshot(window: UIWindow?) -> [String: Any] {
        var value = readEditor?() ?? [:]
        value["preferredContentSizeCategory"] = UIApplication.shared.preferredContentSizeCategory.rawValue
        value["saves"] = saves
        value["previews"] = previews
        value["failNextSave"] = failNextSave
        value["histogramTransitions"] = histogramTransitions
        value["histogramDrawing"] = histogramDrawing
        func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
        func rect(_ frame: CGRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height] }
        if let window {
            let views = all(window)
            value["nativePhotoRects"] = views.compactMap { view -> [Double]? in
                guard let scroll = view as? PhotoScrollView, !scroll.isHidden else { return nil }
                return rect(scroll.imageView.convert(scroll.imageView.bounds, to: window))
            }
            value["nativeSwitchRects"] = views.compactMap { view -> [Double]? in
                guard view is UISwitch else { return nil }
                return rect(view.convert(view.bounds, to: window))
            }
            value["comparisonLabelMetrics"] = views.compactMap { view -> [String: Any]? in
                guard let label = view as? UILabel, !label.isHidden,
                      ["editor.compare.before", "editor.compare.after"].contains(label.accessibilityIdentifier ?? "") else { return nil }
                let font = label.font!
                return ["id": label.accessibilityIdentifier!, "text": label.text ?? "",
                        "rect": rect(label.convert(label.bounds, to: window)), "pointSize": font.pointSize,
                        "fullTextWidth": (label.text ?? "").size(withAttributes: [.font: font]).width,
                        "lineHeight": font.lineHeight]
            }
            value["nativeSplitRects"] = views.filter { $0.accessibilityIdentifier == "editor.compare.split" && !$0.isHidden }.map { rect($0.convert($0.bounds, to: window)) }
        }
        return value
    }
}

private final class ViewingReceiptLabel: UILabel {
    override var accessibilityValue: String? {
        get { String(data: try! JSONSerialization.data(withJSONObject: ViewingEditorProbe.shared.snapshot(window: window), options: [.sortedKeys]), encoding: .utf8) }
        set {}
    }
}

private struct ViewingReceiptView: UIViewRepresentable {
    func makeUIView(context: Context) -> ViewingReceiptLabel {
        let label = ViewingReceiptLabel()
        label.text = "Viewing Receipt"
        label.textColor = .clear
        label.accessibilityLabel = "Viewing Receipt"
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "viewing.editor.receipt"
        return label
    }
    func updateUIView(_ view: ViewingReceiptLabel, context: Context) {}
}

extension ContentView {
    func prepareViewingReview() async {
        let probe = ViewingEditorProbe.shared
        guard !probe.started else { return }
        probe.started = true
        probe.sampleHistogramDrawing()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.failNextSave = true }
        }, "com.rawlab.s3.fail-next-save" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.clearReference?() }
        }, "com.rawlab.s3.clear-reference" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.clearStatistics?() }
        }, "com.rawlab.s4.clear-statistics" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.failIdentity = ViewingEditorProbe.shared.transferTarget?.key }
        }, "com.rawlab.iter03.fail-target" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.externalEdit?() }
        }, "com.rawlab.iter03.external-edit" as CFString, nil, .deliverImmediately)
        probe.clearReference = { viewModel.basePreviewImage = nil; viewModel.baseHistogram = nil }
        probe.clearStatistics = { viewModel.histogram = nil; viewModel.baseHistogram = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewing-editor-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { context in
            for y in 0..<6 { for x in 0..<8 {
                UIColor(hue: CGFloat(x) / 8, saturation: 0.6, brightness: CGFloat(y + 3) / 8, alpha: 1).setFill()
                context.fill(CGRect(x: x * 100, y: y * 100, width: 100, height: 100))
            } }
        }
        let url = directory.appendingPathComponent("S3-fixture.png")
        try! image.pngData()!.write(to: url)
        let identity = try! PhotoIdentity.fallback(for: url)
        let store = try! EditPersistence(directory: directory.appendingPathComponent("edits"))
        var initial = RawSettings.default
        initial.exposure = 0.5
        initial.geometry.cropWidth = 0.8
        try! store.save(identity, state: PhotoEditState(settings: initial))
        if ProcessInfo.processInfo.arguments.contains("-RawLab.adjustmentTransferUI") {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let targetURL = documents.appendingPathComponent("ITER03-target-B.png")
            let targetImage = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }
            try! targetImage.pngData()!.write(to: targetURL)
            let targetID = try! PhotoIdentity.fallback(for: targetURL)
            probe.transferTarget = targetID
            var targetSettings = RawSettings.default; targetSettings.exposure = -0.2; targetSettings.geometry.cropWidth = 0.6
            try! store.save(targetID, state: PhotoEditState(settings: targetSettings))
        }
        probe.externalEdit = {
            var external = store.state(for: identity)!.settings
            external.exposure = 1.3
            try! store.save(identity, state: PhotoEditState(settings: external))
        }
        viewModel.editPersistence = store
        viewModel.adjustmentSession = IOSAdjustmentTransferSession(store: store)
        viewModel.importImage(from: .raster(url), identity: identity, onSettingsRestored: { settings = $0 })
        probe.readEditor = {
            ["ready": viewModel.hasImage && !editorBusy && !viewModel.previewRendering && !viewModel.previewResizePending,
             "busy": editorBusy, "rendering": viewModel.previewRendering, "resize": viewModel.previewResizePending,
             "previewFailed": viewModel.previewFailed, "source": viewModel.sourceRevision.uuidString,
             "settings": probe.settingsText(settings),
             "exposure": settings.exposure, "crop": settings.geometry.cropWidth,
             "draftCrop": geometryDraft?.cropWidth ?? -1, "draftActive": isEditorDraftActive,
             "draftChanged": isEditorDraftChanged, "draftAlert": draftExitPresented,
             "pendingPhoto": pendingPhotoImport, "pendingFile": pendingFileImport,
             "photoPicker": showingPhotoImporter, "filePicker": showingFileImporter,
             "saveState": String(describing: viewModel.editSaveState),
             "historyCount": viewModel.adjustmentSession?.transactions.count ?? 0,
             "sourceStoredExposure": store.state(for: identity)?.settings.exposure as Any? ?? NSNull(),
             "sourceStoredRevision": (try? store.versionedState(for: identity).revision) ?? "",
             "targetStoredExposure": probe.transferTarget.flatMap { store.state(for: $0)?.settings.exposure } as Any? ?? NSNull(),
             "targetStoredCrop": probe.transferTarget.flatMap { store.state(for: $0)?.settings.geometry.cropWidth } as Any? ?? NSNull(),
             "targetStoredRevision": probe.transferTarget.flatMap { try? store.versionedState(for: $0).revision } ?? "",
             "failingTarget": probe.failIdentity ?? "",
             "gestureActive": viewModel.adjustmentInteraction != nil,
             "pendingSettings": viewModel.pendingSettings != nil, "modelDraftActive": viewModel.hasAdjustmentDraft,
             "failedDraftSave": viewModel.hasFailedDraftSave,
             "history": (viewModel.adjustmentSession?.transactions ?? []).map { transaction in
                 ["id": transaction.id.uuidString, "action": String(describing: transaction.action),
                  "parts": transaction.parts.map { ["identity": $0.identity.key, "state": String(describing: $0.state)] }] as [String: Any]
             },
             "clipboard": viewModel.adjustmentSession?.clipboard.map { payload in
                 (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) ?? NSNull()
             } ?? NSNull(),
             "previewOnly": photoViewing.previewOnly, "hold": photoViewing.holdingBefore,
             "compare": photoViewing.enabled, "mode": String(describing: photoViewing.preferredMode),
             "margin": photoViewing.photoMargin, "split": photoViewing.split,
             "referenceAvailable": viewModel.basePreviewImage != nil, "hslChannel": hslChannel, "infoMode": photoInfoMode.rawValue,
             "relativeScale": photoViewport.relativeScale,
             "focus": [photoViewport.focus.x, photoViewport.focus.y],
             "group": selectedGroup.rawValue, "tool": currentEditorTool.stableID,
             "fine": adjustmentFine, "expanded": adjustmentsExpanded,
             "previewSize": viewModel.previewImage.map { [$0.size.width, $0.size.height] } ?? [],
             "histogramExpanded": histogramExpanded,
             "shownHistogram": probe.histogramInfo(currentHistogram),
             "afterHistogram": probe.histogramInfo(viewModel.histogram),
             "beforeHistogram": probe.histogramInfo(viewModel.baseHistogram),
             "referenceSize": viewModel.basePreviewImage.map { [$0.size.width, $0.size.height] } ?? []]
        }
    }
}

private final class ViewingEditorDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Viewing Editor", sessionRole: session.role)
        configuration.delegateClass = ViewingEditorScene.self
        return configuration
    }
}
private final class ViewingEditorScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene)
        let host = UIHostingController(rootView: ContentView().overlay(alignment: .topLeading) { ViewingReceiptView().frame(width: 1, height: 1).allowsHitTesting(false) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
    }
}
@main enum ViewingEditorMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ViewingEditorDelegate.self)) }
}
