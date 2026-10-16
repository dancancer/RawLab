import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Runs the production editor with test-owned persistence and preferences.
@main
struct SinglePreviewInteractionApp: App {
    @StateObject private var model: EditorModel
    private let root: URL
    @State private var lastEvidence = ""

    init() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        self.root = root
        UserDefaults.standard.set("en", forKey: L10n.preferenceKey)
        _model = StateObject(wrappedValue: EditorModel(
            lookDirectory: root.appendingPathComponent("looks"),
            editDirectory: root.appendingPathComponent("edits"),
            batchDirectory: root.appendingPathComponent("batch")))
        NSApplication.shared.setActivationPolicy(.regular)
        do { try Self.makeRasterFixtures(in: root.appendingPathComponent("fixtures")) }
        catch { fatalError("Cannot prepare isolated fixtures: \(error)") }
    }

    var body: some Scene {
        Window("RawLab Comparison Interaction", id: "editor") {
            EditorView(model: model)
                .environment(\.locale, Locale(identifier: "en"))
                .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
                    recordEvidence()
                }
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photo", action: model.openPanel).keyboardShortcut("o")
            }
        }
    }

    private func recordEvidence() {
        let snapshot: [String: Any] = [
            "file": model.file?.path ?? "", "busy": model.busy,
            "exposure": model.settings.exposure, "contrast": model.settings.contrast,
            "result_width": model.result?.image.width ?? 0,
            "result_height": model.result?.image.height ?? 0,
            "neutral_width": model.neutral?.image.width ?? 0,
            "save_status": model.saveStatus, "error": model.error ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8), line != lastEvidence else { return }
        lastEvidence = line
        let entry = "\(Date().ISO8601Format()) \(line)\n"
        let log = root.appendingPathComponent("model-events.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        }
    }

    private static func makeRasterFixtures(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 640, height = 420
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(40 + x * 180 / width)
                pixels[index + 1] = UInt8(30 + y * 180 / height)
                pixels[index + 2] = UInt8(210 - x * 110 / width)
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RenderError.failed("Cannot construct RGB fixture")
        }
        for (name, type) in [("fixture.jpg", UTType.jpeg), ("fixture.png", UTType.png)] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw RenderError.failed("Cannot create \(name)")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RenderError.failed("Cannot encode \(name)") }
        }
    }
}
