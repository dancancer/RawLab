import AppKit
import SwiftUI

/// Renders only views owned by this process. No screen capture, input synthesis,
/// activation, or interaction with another application is used.
@main
struct CompactControlsPresentationTests {
    private struct FieldEvidence: Codable {
        let identifier: String
        let text: String
        let fontSize: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let matchesDeclaredFrame: Bool
    }

    private struct SnapshotEvidence: Codable {
        let file: String
        let language: String
        let width: Int
        let height: Int
        let sampledColorCount: Int
        let fields: [FieldEvidence]
    }

    private struct Report: Codable {
        let method: String
        let fixture: String
        let renderedWidth: Int
        let renderedHeight: Int
        let limitations: [String]
        let snapshots: [SnapshotEvidence]
    }

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func waitForRender(_ model: EditorModel) async throws {
        // Allow the model's debounce to enqueue the requested render.
        try await Task.sleep(for: .milliseconds(350))
        for _ in 0..<1200 {
            if let error = model.error { throw RenderError.failed(error) }
            if !model.busy, model.result != nil, model.neutral != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RenderError.failed("Fixture render timed out")
    }

    @MainActor private static func fields(in view: NSView) -> [NumericTextField] {
        (view as? NumericTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    @MainActor private static func snapshot<V: View>(
        _ view: V, name: String, language: AppLanguage, size: NSSize,
        expectedFields: Int, output: URL
    ) async throws -> SnapshotEvidence {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: language.rawValue))
            .preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        // An unshown test-owned window supplies native control context. It is never
        // ordered front, activated, or read from the screen.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let nativeFields = fields(in: host)
        guard nativeFields.count == expectedFields else {
            throw RenderError.failed("\(name): expected \(expectedFields) numeric fields; found \(nativeFields.count)")
        }
        var fieldEvidence: [FieldEvidence] = []
        for field in nativeFields {
            let bounds = field.convert(field.bounds, to: host)
            let matchesDeclaredFrame = abs(field.bounds.width - 72) < 0.5 && abs(field.bounds.height - 26) < 0.5
            guard matchesDeclaredFrame, field.font?.pointSize == 13,
                  host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                  !field.isHiddenOrHasHiddenAncestor else {
                throw RenderError.failed("\(name): invalid numeric field geometry \(bounds)")
            }
            let textWidth = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
            guard textWidth <= field.bounds.width - 14 else {
                throw RenderError.failed("\(name): numeric text does not fit \(field.stringValue)")
            }
            fieldEvidence.append(FieldEvidence(identifier: field.accessibilityIdentifier(),
                text: field.stringValue, fontSize: Double(field.font!.pointSize),
                x: Double(bounds.minX), y: Double(bounds.minY), width: Double(bounds.width), height: Double(bounds.height),
                matchesDeclaredFrame: matchesDeclaredFrame))
        }

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.failed("\(name): view bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard bitmap.pixelsWide == Int(size.width), bitmap.pixelsHigh == Int(size.height),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.failed("\(name): invalid bitmap dimensions or PNG encoding")
        }
        var sampledColors: Set<String> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 9) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 9) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                sampledColors.insert("\(Int(color.redComponent * 31)),\(Int(color.greenComponent * 31)),\(Int(color.blueComponent * 31))")
            }
        }
        guard sampledColors.count >= 16 else {
            throw RenderError.failed("\(name): view snapshot appears blank (\(sampledColors.count) sampled colors)")
        }
        let file = "\(name)-\(language.rawValue).png"
        try png.write(to: output.appendingPathComponent(file))
        print("PASS: native view snapshot \(file), \(Int(size.width))×\(Int(size.height)), \(nativeFields.count) fields")
        return SnapshotEvidence(file: file, language: language.rawValue,
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh, sampledColorCount: sampledColors.count, fields: fieldEvidence)
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw RenderError.failed("Pass a RAW fixture and an output directory")
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = output.appendingPathComponent("isolated-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: fixture.path)
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: "en", "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
        let model = EditorModel(lookDirectory: state.appendingPathComponent("looks"),
                                editDirectory: state.appendingPathComponent("edits"),
                                batchDirectory: state.appendingPathComponent("batch"))
        model.open(fixture)
        try await waitForRender(model)
        model.settings.exposure = 1.25
        model.settings.setEffect(.grainAmount, to: 45)
        model.settings.setEffect(.grainSize, to: 60)
        model.settings.setEffect(.grainRoughness, to: 70)
        try await waitForRender(model)
        guard let frame = model.result else { throw RenderError.failed("Missing real RAW render") }
        var hsl = HSLSettings()
        hsl.set(.hue, channel: 0, value: 19)
        hsl.set(.saturation, channel: 0, value: -14)
        hsl.set(.lightness, channel: 0, value: 22)
        let languages: [AppLanguage]
        if let identifier = ProcessInfo.processInfo.environment["RAWLAB_SNAPSHOT_LANGUAGE"] {
            guard let language = AppLanguage(rawValue: identifier), language != .system else {
                throw RenderError.failed("Invalid snapshot language: \(identifier)")
            }
            languages = [language]
        } else {
            languages = AppLanguage.allCases.filter { $0 != .system }
        }
        var snapshots: [SnapshotEvidence] = []
        for language in languages {
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language.rawValue, "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
            let missing = "\u{0}missing\u{0}"
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let localization = Bundle(path: path) else {
                throw RenderError.failed("Missing localization bundle for \(language.rawValue)")
            }
            let grainTitle = localization.localizedString(forKey: "颗粒强度", value: missing, table: nil)
            guard grainTitle != missing, L10n.text("颗粒强度") == grainTitle else {
                throw RenderError.failed("Missing localization for \(language.rawValue)")
            }
            for (name, size) in [("editor-minimum", NSSize(width: 950, height: 620)),
                                 ("editor-wide", NSSize(width: 1440, height: 900))] {
                snapshots.append(try await snapshot(EditorView(model: model), name: name, language: language,
                    size: size, expectedFields: 1, output: output))
            }
            snapshots.append(try await snapshot(MacHSLMixer(settings: .constant(hsl)).padding(16)
                .frame(width: 650, height: 220, alignment: .top).background(Color(nsColor: .windowBackgroundColor)),
                name: "hsl-workspace-650", language: language, size: NSSize(width: 650, height: 220),
                expectedFields: 3, output: output))
            snapshots.append(try await snapshot(PhotoEffectsControls(model: model, tool: .grainAmount).padding(.vertical, 12)
                .frame(width: 650, height: 200, alignment: .top).background(Color(nsColor: .windowBackgroundColor)),
                name: "grain-workspace-650", language: language, size: NSSize(width: 650, height: 200),
                expectedFields: 3, output: output))
            snapshots.append(try await snapshot(MasterRecipeDock(model: model)
                .frame(width: 650, height: 124).background(Color(nsColor: .windowBackgroundColor)),
                name: "recipes-workspace-650", language: language, size: NSSize(width: 650, height: 124),
                expectedFields: 0, output: output))
            model.settings.setGeometry(.perspectiveHorizontal, to: 0.3)
            model.settings.setGeometry(.perspectiveVertical, to: -0.2)
            try await waitForRender(model)
            snapshots.append(try await snapshot(GeometryControls(model: model)
                .frame(width: 650, height: 260).background(Color(nsColor: .windowBackgroundColor)),
                name: "geometry-workspace-650", language: language, size: NSSize(width: 650, height: 260),
                expectedFields: 2, output: output))
            model.settings.reset(.geometry)
            try await waitForRender(model)
        }
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: fixture.path)
        guard (attributesBefore[.size] as? NSNumber) == (attributesAfter[.size] as? NSNumber),
              (attributesBefore[.modificationDate] as? Date) == (attributesAfter[.modificationDate] as? Date) else {
            throw RenderError.failed("Original fixture metadata changed")
        }
        let report = Report(method: "Native NSHostingView.cacheDisplay bitmap of an unshown, test-owned window; no screen capture or input automation",
            fixture: fixture.lastPathComponent, renderedWidth: frame.image.width, renderedHeight: frame.image.height,
            limitations: ["Editor snapshots cover the actual content view; window chrome and the application toolbar are excluded.",
                          "File tree starts empty with isolated temporary preferences.",
                          "HSL and grain snapshots show the actual product components at 650 points: the workspace remaining in a 950-point window with a 300-point file tree.",
                          "72×26 native field geometry, 13-point font, numeric text fit, direct locale lookup, field containment, and nonblank bitmap are strict automated checks; label wrapping requires visual inspection.",
                          "Actual mouse, keyboard, scroll-wheel, focus traversal, and VoiceOver verification remain pending while the Mac is locked.",
                          "These view snapshots do not establish that the complete native/core test gate has passed."], snapshots: snapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
        print("PASS: \(snapshots.count) native view snapshots; original RAW size and modification time unchanged")
    }
}
