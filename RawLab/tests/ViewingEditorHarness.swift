import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class ViewingEditorProbe {
    static let shared = ViewingEditorProbe()
    var started = false
    var failNextSave = false
    var resizing = false
    var saves: [[String: Any]] = []
    var previews: [[String: Any]] = []
    var readEditor: (() -> [String: Any])?
    var clearReference: (() -> Void)?

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
    func recordSave(_ state: PhotoEditState) throws {
        saves.append(["exposure": state.settings.exposure, "crop": state.settings.geometry.cropWidth,
                      "settings": settingsText(state.settings), "failed": failNextSave])
        if failNextSave { failNextSave = false; throw CocoaError(.fileWriteNoPermission) }
    }
    func snapshot(window: UIWindow?) -> [String: Any] {
        var value = readEditor?() ?? [:]
        value["preferredContentSizeCategory"] = UIApplication.shared.preferredContentSizeCategory.rawValue
        value["saves"] = saves
        value["previews"] = previews
        value["failNextSave"] = failNextSave
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
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.failNextSave = true }
        }, "com.rawlab.s3.fail-next-save" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            Task { @MainActor in ViewingEditorProbe.shared.clearReference?() }
        }, "com.rawlab.s3.clear-reference" as CFString, nil, .deliverImmediately)
        probe.clearReference = { viewModel.basePreviewImage = nil; viewModel.baseHistogram = [] }
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
        viewModel.editPersistence = store
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
             "previewOnly": photoViewing.previewOnly, "hold": photoViewing.holdingBefore,
             "compare": photoViewing.enabled, "mode": String(describing: photoViewing.preferredMode),
             "margin": photoViewing.photoMargin, "split": photoViewing.split,
             "referenceAvailable": viewModel.basePreviewImage != nil, "hslChannel": hslChannel, "infoMode": photoInfoMode.rawValue,
             "relativeScale": photoViewport.relativeScale,
             "focus": [photoViewport.focus.x, photoViewport.focus.y],
             "group": selectedGroup.rawValue, "tool": currentEditorTool.stableID,
             "fine": adjustmentFine, "expanded": adjustmentsExpanded,
             "previewSize": viewModel.previewImage.map { [$0.size.width, $0.size.height] } ?? [],
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
