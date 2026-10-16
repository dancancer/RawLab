import AppKit
import SwiftUI

/// This subset target uses a model stub only to typecheck the production
/// adapter. Snapshots render immutable workspace/catalog fixtures directly.
final class EditorModel: ObservableObject {
    @Published var lensDraftSettings = LensCorrectionSettings()
    var lensDraftPreviewIsCurrent = true
    var result: RenderedImage?
    func updateLensDraft(_ edit: (inout LensCorrectionSettings) -> Void) { edit(&lensDraftSettings) }
}

@main
struct MacLensDraftPresentationTests {
    private static let candidates = [
        LensCandidate(id: "gm", maker: "Sony", model: "FE 24–70mm F2.8 GM", hasDistortion: true, hasTCA: true, isMatch: true),
        LensCandidate(id: "gm2", maker: "Sony", model: "FE 24–70mm F2.8 GM II", hasDistortion: true, hasTCA: true, isMatch: false),
        LensCandidate(id: "za", maker: "Sony", model: "Vario-Tessar T* FE 24–70mm F4 ZA OSS", hasDistortion: true, hasTCA: false, isMatch: false)
    ]

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor private static func snapshot<V: View>(_ view: V, name: String, size: NSSize,
                                                     language: AppLanguage, output: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language.rawValue))
            .preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.failed("Cannot create lens fixture bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard bitmap.pixelsWide == Int(size.width), bitmap.pixelsHigh == Int(size.height),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.failed("\(name): expected \(Int(size.width))×\(Int(size.height)), bitmap \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), host \(host.bounds)")
        }
        let filename = "\(name)-\(language.rawValue).png"
        try data.write(to: output.appendingPathComponent(filename))
        print("PASS: lens view fixture \(filename), \(Int(size.width))×\(Int(size.height))")
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 2,
              let identifier = ProcessInfo.processInfo.environment["RAWLAB_SNAPSHOT_LANGUAGE"],
              let language = AppLanguage(rawValue: identifier), language != .system else {
            throw RenderError.failed("Pass fixture output and a supported snapshot language")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language.rawValue], forName: UserDefaults.argumentDomain)
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let localized = Bundle(path: path),
              localized.localizedString(forKey: "使用此镜头", value: "missing", table: nil) != "missing" else {
            throw RenderError.failed("Missing direct lens fixture localization")
        }
        let info = LensInfo(state: SONY2FUJI_LENS_OFF, detectedLens: "FE 24–70mm F2.8 GM", selectedLens: "",
                            focalLength: 35, appliedDistortion: false, appliedTCA: false, cropScale: 1, candidates: candidates)
        let settings = LensCorrectionSettings()
        for width in [650, 980] {
            try await snapshot(LensDraftWorkspace(settings: settings, info: info, previewIsCurrent: true,
                update: { _ in }, choose: {}).padding(.vertical, 12).background(Color(nsColor: .windowBackgroundColor)),
                name: "lens-default-\(width)", size: NSSize(width: width, height: width == 650 ? 260 : 190),
                language: language, output: output)
        }
        var manual = settings
        manual.mode = .manual
        manual.profileID = "za"
        manual.distortion = true
        manual.tca = true
        let partial = LensInfo(state: SONY2FUJI_LENS_MATCHED, detectedLens: info.detectedLens,
                               selectedLens: candidates[2].model, focalLength: 35,
                               appliedDistortion: true, appliedTCA: false, cropScale: 1.1, candidates: candidates)
        try await snapshot(LensDraftWorkspace(settings: manual, info: partial, previewIsCurrent: true,
            update: { _ in }, choose: {}).padding(.vertical, 12).background(Color(nsColor: .windowBackgroundColor)),
            name: "lens-partial-650", size: NSSize(width: 650, height: 260), language: language, output: output)
        try await snapshot(LensProfileChooser(candidates: candidates, settings: settings, cancel: {}, use: { _ in }),
            name: "lens-chooser", size: NSSize(width: 540, height: 440), language: language, output: output)
        let report: [String: Any] = ["method": "NSHostingView.cacheDisplay on test-owned, unshown windows",
            "fixture": "Synthetic catalog and report; no RAW file or saved edit was read or modified",
            "language": language.rawValue, "snapshots": 4,
            "limitations": ["No screen capture, activation, or input synthesis", "Real keyboard, pointer, and VoiceOver behavior awaits unlock"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
    }
}
