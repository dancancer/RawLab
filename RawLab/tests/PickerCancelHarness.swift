import CryptoKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Acquisition gate (test bundle only)

@MainActor
final class PickerCancelHarnessState {
    static let shared = PickerCancelHarnessState()
    enum Mode { case success, failure }
    var readEditor: (() -> [String: String])?
    var disappearances = 0
    private var armed: Mode?
    private var continuation: CheckedContinuation<PhotoImportSource, Error>?
    private var heldSource: PhotoImportSource?
    private var heldMode: Mode?
    private(set) var gatePhase = "idle"
    private(set) var gateURL: URL?
    private(set) var heldItem: String?
    private(set) var resumedCancelled: Bool?
    private(set) var acquisitionCount = 0
    private(set) var seedIDs: [String] = []
    private(set) var seedError: String?

    func arm(_ mode: Mode) {
        guard continuation == nil else { return }
        armed = mode
        gatePhase = "idle"
        gateURL = nil
        heldItem = nil
        resumedCancelled = nil
    }

    func acquire(_ item: PhotosPickerItem) async throws -> PhotoImportSource {
        let mode = armed
        armed = nil
        acquisitionCount += 1
        let source = try await PhotoImportFile.load(from: item)
        guard let mode else { return source }
        heldMode = mode
        heldSource = source
        gateURL = source.url
        heldItem = item.itemIdentifier
        gatePhase = "acquired"
        print("PICKER_GATE acquired item=\(item.itemIdentifier ?? "nil") path=\(source.url.path)")
        do {
            let result = try await withCheckedThrowingContinuation { continuation = $0 }
            resumedCancelled = Task.isCancelled
            print("PICKER_GATE resumed success cancelled=\(Task.isCancelled)")
            return result
        } catch {
            resumedCancelled = Task.isCancelled
            print("PICKER_GATE resumed failure cancelled=\(Task.isCancelled)")
            throw error
        }
    }

    func release() {
        guard let continuation, let source = heldSource, let mode = heldMode else { return }
        self.continuation = nil
        heldSource = nil
        heldMode = nil
        if mode == .failure {
            // The throwing test loader owns cleanup; loadSource receives no source on error.
            PhotoImportFile.release(source.url)
            gatePhase = "releasedFailure"
            continuation.resume(throwing: NSError(domain: "RawLabPickerCancelHarness", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Injected late acquisition failure"]))
        } else {
            gatePhase = "releasedSuccess"
            continuation.resume(returning: source)
        }
    }

    func armSuccess() { arm(.success) }
    func armFailure() { arm(.failure) }

    func snapshot() -> String {
        var values = readEditor?() ?? [:]
        values["seeded"] = String(seedIDs.count == 3)
        for (offset, key) in ["seedA", "seedB", "seedC"].enumerated() {
            values[key] = seedIDs.indices.contains(offset) ? seedIDs[offset] : "nil"
        }
        values["seedError"] = seedError ?? "nil"
        values["gatePhase"] = gatePhase
        values["gateURL"] = gateURL?.path ?? "nil"
        values["gateFileExists"] = String(gateURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        values["heldItem"] = heldItem ?? "nil"
        values["resumedCancelled"] = resumedCancelled.map(String.init) ?? "nil"
        values["acquisitionCount"] = String(acquisitionCount)
        values["disappearances"] = String(disappearances)
        return PickerCancelJSON.encode(values)
    }

    func seed() async {
        var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if access == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard access == .authorized || access == .limited else { seedError = "Photos authorization denied"; return }
        let saved = UserDefaults.standard.stringArray(forKey: "pickerCancel.seedIDs") ?? []
        if saved.count == 3, PHAsset.fetchAssets(withLocalIdentifiers: saved, options: nil).count == 3 {
            seedIDs = saved
            return
        }
        let images = [Self.fixture(index: 0), Self.fixture(index: 1), Self.fixture(index: 2)]
        var created: [String] = []
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for index in 0..<3 {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = Date(timeIntervalSince1970: 1_893_456_000 + Double(index) * 86_400)
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "rawlab-picker-cancel-\(["A", "B", "C"][index]).png"
                    request.addResource(with: .photo, data: images[index], options: options)
                    if let id = request.placeholderForCreatedAsset?.localIdentifier { created.append(id) }
                }
            }
            guard created.count == 3 else { seedError = "Fixture creation returned incomplete identifiers"; return }
            seedIDs = created
            UserDefaults.standard.set(created, forKey: "pickerCancel.seedIDs")
        } catch { seedError = error.localizedDescription }
    }

    private static func fixture(index: Int) -> Data {
        let size = CGSize(width: 360 + index * 60, height: 240 + index * 20)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            [UIColor.systemRed, .systemGreen, .systemBlue][index].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 25, y: 20, width: 35 + index * 35, height: 80))
        }
    }
}

enum PickerCancelJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "nil"
    }

    static func digest(_ data: Data?) -> String {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "nil"
    }
}

extension ContentView {
    func pickerCancelSnapshot() -> [String: String] {
        [
            "hasImage": String(viewModel.hasImage),
            "source": viewModel.sourceDisplayName ?? "nil",
            "sourceIdentity": viewModel.sourceIdentity?.resourceIdentifier ?? "nil",
            "sourceRevision": viewModel.sourceRevision.uuidString,
            "image": PickerCancelJSON.digest(viewModel.previewImage?.pngData()),
            "histogram": PickerCancelJSON.digest(viewModel.histogram.map {
                "\($0.width)x\($0.height):\(PickerCancelJSON.encode($0.counts))"
            }?.data(using: .utf8)),
            "settings": PickerCancelJSON.encode(settings),
            "geometryDraft": geometryDraft.map(PickerCancelJSON.encode) ?? "nil",
            "lensDraft": lensDraft.map(PickerCancelJSON.encode) ?? "nil",
            "geometrySelected": String(geometrySelected),
            "lensSelected": String(lensSelected),
            "isImporting": String(isImporting),
            "vmBusy": String(viewModel.isBusy),
            "editorBusy": String(editorBusy),
            "previewRendering": String(viewModel.previewRendering),
            "previewResizePending": String(viewModel.previewResizePending),
            "request": photoImportRequestID?.uuidString ?? "nil",
            "task": String(photoImportTask != nil),
            "selectedPhoto": selectedPhotoItem?.itemIdentifier ?? "nil",
            "status": viewModel.statusMessage ?? "nil"
        ]
    }
}

// MARK: - UIKit shell (keeps one hosting controller across disappearance)

@MainActor
final class PickerCancelProbe: UILabel {
    override var accessibilityValue: String? {
        get { PickerCancelHarnessState.shared.snapshot() }
        set { }
    }
}

@MainActor
final class PickerCancelShell: UIViewController {
    private let editor = UIHostingController(rootView: AnyView(ContentView().environment(\.locale, Locale(identifier: "en"))))
    private let navigation = UINavigationController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.setViewControllers([editor], animated: false)
        addChild(navigation)
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        let commands = UIStackView()
        commands.axis = .vertical
        commands.spacing = 4
        commands.translatesAutoresizingMaskIntoConstraints = false
        let row1 = UIStackView(arrangedSubviews: [button("Arm success", "picker.arm.success", #selector(armSuccess)),
                                                 button("Arm failure", "picker.arm.failure", #selector(armFailure))])
        let row2 = UIStackView(arrangedSubviews: [button("Leave", "picker.leave", #selector(leave)),
                                                 button("Return", "picker.return", #selector(returnToEditor)),
                                                 button("Release", "picker.release", #selector(releaseGate))])
        for row in [row1, row2] { row.axis = .horizontal; row.distribution = .fillEqually; row.spacing = 4; commands.addArrangedSubview(row) }
        let probe = PickerCancelProbe()
        probe.text = "Picker cancel test probe"
        probe.textColor = .lightGray
        probe.font = .systemFont(ofSize: 10)
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "picker.probe"
        probe.accessibilityLabel = "Picker cancel test probe"
        commands.addArrangedSubview(probe)
        view.addSubview(commands)
        NSLayoutConstraint.activate([
            navigation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navigation.view.topAnchor.constraint(equalTo: view.topAnchor),
            navigation.view.bottomAnchor.constraint(equalTo: commands.topAnchor, constant: -4),
            commands.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            commands.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            commands.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2)
        ])
        Task { await PickerCancelHarnessState.shared.seed() }
    }

    private func button(_ title: String, _ identifier: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    @objc private func armSuccess() { PickerCancelHarnessState.shared.armSuccess() }
    @objc private func armFailure() { PickerCancelHarnessState.shared.armFailure() }
    @objc private func releaseGate() { PickerCancelHarnessState.shared.release() }
    @objc private func leave() {
        guard navigation.topViewController === editor else { return }
        let away = UIViewController()
        away.view.backgroundColor = .darkGray
        let label = UILabel()
        label.text = "Editor is away"
        label.textColor = .white
        label.accessibilityIdentifier = "picker.away"
        label.translatesAutoresizingMaskIntoConstraints = false
        away.view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: away.view.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: away.view.centerYAnchor)])
        navigation.pushViewController(away, animated: false)
    }
    @objc private func returnToEditor() { navigation.popToRootViewController(animated: false) }
}

@MainActor
final class PickerCancelSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = PickerCancelShell()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@main
@MainActor
final class PickerCancelApplication: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Picker Cancel Harness", sessionRole: session.role)
        configuration.delegateClass = PickerCancelSceneDelegate.self
        return configuration
    }
}
