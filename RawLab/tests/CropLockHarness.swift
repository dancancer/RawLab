import Foundation
import SwiftUI
import UIKit

/// A test-only publication gate. Decoding and processing still use the real VM.
/// Releasing callbacks happens on the main thread, exactly like its default delivery.
private final class CropResultCollector {
    private let lock = NSLock()
    private var held = false
    private var deliveries: [() -> Void] = []
    var queueDidChange: (() -> Void)?

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return deliveries.count
    }

    func hold() {
        lock.lock(); held = true; lock.unlock()
    }

    func append(_ delivery: @escaping () -> Void) {
        lock.lock()
        let shouldHold = held
        if shouldHold { deliveries.append(delivery) }
        lock.unlock()
        if shouldHold { DispatchQueue.main.async { self.queueDidChange?() } }
        else { DispatchQueue.main.async(execute: delivery) }
    }

    func releaseQueued() {
        precondition(Thread.isMainThread)
        lock.lock()
        held = false
        let completed = deliveries
        deliveries.removeAll()
        lock.unlock()
        completed.forEach { $0() }
        queueDidChange?()
    }
}

private final class CropHarnessState: ObservableObject {
    let model: RawEditorViewModel
    private let collector: CropResultCollector
    private let aURL: URL, bURL: URL
    private let aIdentity: PhotoIdentity, bIdentity: PhotoIdentity
    private let aGeometry: GeometrySettings, bGeometry: GeometrySettings
    private var importID: UUID?

    @Published var geometry = GeometrySettings()
    @Published private(set) var sourceImage: UIImage?
    @Published private(set) var imageSize = CGSize(width: 80, height: 60)
    @Published private(set) var queued = 0
    @Published private(set) var dragging = false
    @Published private(set) var armed = false
    @Published private(set) var gestureStarts = 0
    @Published private(set) var gestureEnds = 0
    @Published private(set) var acceptedWrites = 0
    @Published private(set) var restorations = 0

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        aURL = directory.appendingPathComponent("source-a.png")
        bURL = directory.appendingPathComponent("source-b.png")
        aIdentity = PhotoIdentity(resourceIdentifier: "crop-lock-a-\(UUID().uuidString)")
        bIdentity = PhotoIdentity(resourceIdentifier: "crop-lock-b-\(UUID().uuidString)")
        var a = RawSettings.default
        a.geometry.cropX = 0.1; a.geometry.cropY = 0.1
        a.geometry.cropWidth = 0.8; a.geometry.cropHeight = 0.8
        aGeometry = a.geometry
        var b = RawSettings.default
        b.geometry.cropX = 0.2; b.geometry.cropY = 0.15
        b.geometry.cropWidth = 0.6; b.geometry.cropHeight = 0.7
        bGeometry = b.geometry
        let persistence = try EditPersistence(directory: directory.appendingPathComponent("edits"))
        try persistence.save(aIdentity, state: PhotoEditState(settings: a))
        try persistence.save(bIdentity, state: PhotoEditState(settings: b))
        try Self.writeImage(aURL, size: CGSize(width: 80, height: 60), colors: [.systemOrange, .systemRed])
        try Self.writeImage(bURL, size: CGSize(width: 96, height: 64), colors: [.systemBlue, .systemGreen])
        let collector = CropResultCollector()
        self.collector = collector
        model = RawEditorViewModel(editPersistence: persistence, resultDelivery: { collector.append($0) })
        collector.queueDidChange = { [weak self, weak collector] in self?.queued = collector?.count ?? 0 }
        importID = model.importImage(from: .raster(aURL), identity: aIdentity) { [weak self] in
            self?.restore($0)
        }
    }

    var source: String {
        switch model.sourceDisplayName {
        case "source-a.png": return "A"
        case "source-b.png": return "B"
        default: return "none"
        }
    }

    var cropDescription: String {
        String(format: "%.6f,%.6f,%.6f,%.6f", geometry.cropX, geometry.cropY,
               geometry.cropWidth, geometry.cropHeight)
    }

    /// This wrapper mirrors the production binding's busy and source guards.
    /// XCTest never invokes it directly; only EditorCropOverlay's real gestures do.
    func cropBinding() -> Binding<GeometrySettings> {
        let revision = model.sourceRevision
        return Binding(get: { self.geometry }, set: { value in
            guard !self.model.isBusy, self.model.sourceRevision == revision else { return }
            self.geometry = value
            self.acceptedWrites += 1
        })
    }

    func editingChanged(_ active: Bool) {
        if active {
            gestureStarts += 1
            dragging = true
            if armed { beginB() }
        } else {
            gestureEnds += 1
            dragging = false
        }
    }

    func beginB() {
        guard !model.isBusy else { return }
        armed = false
        collector.hold()
        importID = model.importImage(from: .raster(bURL), identity: bIdentity) { [weak self] in
            self?.restore($0)
        }
    }

    func armImport() {
        guard !model.isBusy else { return }
        armed = true
    }

    func cancelImport() {
        model.cancelImageImport(importID)
        importID = nil
    }

    func releaseQueued() { collector.releaseQueued() }

    func resetCrop() {
        guard !model.isBusy else { return }
        geometry = source == "B" ? bGeometry : aGeometry
    }

    private func restore(_ settings: RawSettings) {
        precondition(Thread.isMainThread)
        geometry = settings.geometry
        if let url = model.sourceFile?.withReadAccess({ $0 }), let image = UIImage(contentsOfFile: url.path) {
            sourceImage = image
            imageSize = image.size
        }
        restorations += 1
    }

    private static func writeImage(_ url: URL, size: CGSize, colors: [UIColor]) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            colors[0].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            colors[1].setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        guard let data = image.pngData() else {
            throw NSError(domain: "CropLockHarness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not generate raster fixture"])
        }
        try data.write(to: url)
    }
}

private struct CropHarnessView: View {
    @ObservedObject var state: CropHarnessState
    @ObservedObject var model: RawEditorViewModel

    init(state: CropHarnessState) {
        self.state = state
        model = state.model
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                command("Begin B", id: "crop.harness.beginB", action: state.beginB)
                    .disabled(model.isBusy || !model.hasImage)
                command("Release queued", id: "crop.harness.release", action: state.releaseQueued)
                    .disabled(state.queued == 0)
            }
            HStack {
                command("Cancel import", id: "crop.harness.cancel", action: state.cancelImport)
                    .disabled(!model.isBusy)
                command("Reset crop", id: "crop.harness.reset", action: state.resetCrop)
                    .disabled(model.isBusy || !model.hasImage)
            }
            command("Arm import on first gesture", id: "crop.harness.arm", action: state.armImport)
                .disabled(model.isBusy || !model.hasImage)

            VStack(spacing: 3) {
                HStack {
                    status(state.source, id: "source")
                    status(String(model.isBusy), id: "busy")
                    status(String(state.queued), id: "queued")
                }
                status(state.cropDescription, id: "geometry")
                HStack {
                    status(String(state.dragging), id: "dragging")
                    status(String(state.armed), id: "armed")
                    status(String(state.gestureStarts), id: "starts")
                    status(String(state.gestureEnds), id: "ends")
                    status(String(state.acceptedWrites), id: "writes")
                    status(String(state.restorations), id: "restorations")
                }
                if let error = model.statusMessage {
                    Text(error).accessibilityIdentifier("crop.harness.error")
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 90)

            GeometryReader { geometry in
                let size = CGSize(width: min(geometry.size.width, 600), height: min(geometry.size.height, 480))
                ZStack {
                    if let image = state.sourceImage {
                        Image(uiImage: image).resizable().scaledToFit().allowsHitTesting(false)
                    }
                    if model.hasImage {
                        EditorCropOverlay(settings: state.cropBinding(), imageSize: state.imageSize,
                                          aspectRatio: nil, isEnabled: !model.isBusy,
                                          sourceRevision: model.sourceRevision,
                                          onEditingChanged: state.editingChanged)
                            .id(model.sourceRevision)
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .padding(16)
    }

    private func command(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.bordered).accessibilityIdentifier(id)
    }

    private func status(_ value: String, id: String) -> some View {
        Text(value).accessibilityIdentifier("crop.harness.\(id)")
    }
}

@main
final class CropLockAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Crop Lock Harness", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CropLockSceneDelegate.self
        return configuration
    }
}

final class CropLockSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var state: CropHarnessState?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        do {
            let state = try CropHarnessState()
            self.state = state
            window.rootViewController = UIHostingController(rootView: CropHarnessView(state: state))
        } catch {
            window.rootViewController = UIHostingController(rootView:
                Text(error.localizedDescription).accessibilityIdentifier("crop.harness.failure"))
        }
        window.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        self.window = window
    }
}
