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
        let initialX: Double
        let initialY: Double
        let initiallyFullyVisible: Bool
        let reachableByScrolling: Bool
    }

    private struct SnapshotEvidence: Codable {
        let file: String
        let language: String
        let width: Int
        let height: Int
        let sampledColorCount: Int
        let fields: [FieldEvidence]
        let scrollScreenshots: [String]
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
        expectedFields: Int, output: URL, renderModel: EditorModel? = nil, textSize: DynamicTypeSize = .large
    ) async throws -> SnapshotEvidence {
        let host = NSHostingView(rootView: view.dynamicTypeSize(textSize).environment(\.locale, Locale(identifier: language.rawValue))
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
        if let renderModel { try await waitForRender(renderModel) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.failed("\(name): view bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let backingSize = window.convertToBacking(host.bounds).size
        guard bitmap.pixelsWide == Int(backingSize.width), bitmap.pixelsHigh == Int(backingSize.height),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.failed("\(name): invalid bitmap dimensions \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), expected backing size \(backingSize), or PNG encoding")
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

        let nativeFields = fields(in: host)
        guard nativeFields.count == expectedFields else {
            throw RenderError.failed("\(name): expected \(expectedFields) numeric fields; found \(nativeFields.count)")
        }
        var fieldEvidence: [FieldEvidence] = []
        var scrollScreenshots: [String] = []
        let windowFrame = window.frame
        for field in nativeFields {
            let initialBounds = field.convert(field.bounds, to: host)
            let initiallyFullyVisible = host.bounds.contains(initialBounds) && field.visibleRect.contains(field.bounds)
            if !initiallyFullyVisible && textSize.isAccessibilitySize {
                field.scrollToVisible(field.bounds)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                host.layoutSubtreeIfNeeded()
                let reachedFile = "\(name)-reached-\(field.accessibilityIdentifier())-\(language.rawValue).png"
                guard let reached = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.failed("Missing reachability bitmap") }
                host.cacheDisplay(in: host.bounds, to: reached)
                guard let reachedPNG = reached.representation(using: .png, properties: [:]) else { throw RenderError.failed("Missing reachability PNG") }
                try reachedPNG.write(to: output.appendingPathComponent(reachedFile))
                scrollScreenshots.append(reachedFile)
            }
            let bounds = field.convert(field.bounds, to: host)
            let reachable = host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(bounds) && field.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(field.bounds)
            guard window.frame == windowFrame else { throw RenderError.failed("\(name): scrolling changed the window frame") }
            let matchesDeclaredFrame = field.bounds.width >= 71.5 && field.bounds.height >= 25.5
            guard matchesDeclaredFrame, (field.font?.pointSize ?? 0) >= 13,
                  reachable,
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
                matchesDeclaredFrame: matchesDeclaredFrame, initialX: Double(initialBounds.minX), initialY: Double(initialBounds.minY),
                initiallyFullyVisible: initiallyFullyVisible, reachableByScrolling: reachable))
        }

        let file = "\(name)-\(language.rawValue).png"
        try png.write(to: output.appendingPathComponent(file))
        print("PASS: native view snapshot \(file), \(Int(size.width))×\(Int(size.height)), \(nativeFields.count) fields")
        return SnapshotEvidence(file: file, language: language.rawValue,
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh, sampledColorCount: sampledColors.count, fields: fieldEvidence, scrollScreenshots: scrollScreenshots)
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
        if ProcessInfo.processInfo.environment["RAWLAB_SNAPSHOT_EMPTY_ONLY"] == "1" {
            guard let identifier = ProcessInfo.processInfo.environment["RAWLAB_SNAPSHOT_LANGUAGE"],
                  let language = AppLanguage(rawValue: identifier), language != .system,
                  let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let localization = Bundle(path: path) else { throw RenderError.failed("Pass a supported empty-state snapshot language") }
            UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: identifier, "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
            let openTitle = localization.localizedString(forKey: "打开 RAW…", value: "missing", table: nil)
            guard openTitle != "missing", L10n.text("打开 RAW…") == openTitle else {
                throw RenderError.failed("Missing localized Open RAW entry: \(identifier)")
            }
            var snapshots: [SnapshotEvidence] = []
            for (name, size) in [("empty-minimum", NSSize(width: 950, height: 620)),
                                 ("empty-wide", NSSize(width: 1440, height: 900))] {
                snapshots.append(try await snapshot(EditorView(model: model), name: name, language: language,
                    size: size, expectedFields: 0, output: output))
            }
            guard model.file == nil, model.result == nil, !model.busy, !model.exporting else {
                throw RenderError.failed("Empty-state snapshots changed the editor state")
            }
            let report = Report(method: "Native NSHostingView.cacheDisplay of an unshown test-owned window; no screen capture or input automation",
                fixture: "No photo opened", renderedWidth: 0, renderedHeight: 0,
                limitations: ["Open RAW label is checked against the selected localization bundle and visually inspected in the snapshots.",
                    "Native file-panel interaction remains pending Mac unlock; its model.openPanel binding and Command-O entry are unchanged."], snapshots: snapshots)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
            print("PASS: 2 empty-state snapshots, localized Open RAW entry: \(openTitle); no photo opened")
            return
        }
        model.open(fixture)
        try await waitForRender(model)
        model.selectAdjustmentTool(.exposure)
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
        if ProcessInfo.processInfo.environment["RAWLAB_PARAMETER_MATRIX"] == "1" {
            var snapshots: [SnapshotEvidence] = []
            for language in languages {
                UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: language.rawValue, "photoFolders": [String]()], forName: UserDefaults.argumentDomain)
                for (tool, fieldCount) in [(EditorAdjustmentTool.exposure, 1), (.hsl, 3), (.whiteBalance, 2), (.geometry, 1)] {
                    model.selectAdjustmentTool(tool)
                    try await waitForRender(model)
                    for (fontName, fontSize) in [("normal", DynamicTypeSize.large), ("large", .accessibility3)] {
                        for (sizeName, size) in [("minimum", NSSize(width: 950, height: 620)), ("wide", NSSize(width: 1440, height: 900))] {
                            snapshots.append(try await snapshot(EditorView(model: model),
                                name: "parameter-\(tool.rawValue)-\(fontName)-\(sizeName)", language: language,
                                size: size, expectedFields: fieldCount, output: output, renderModel: model, textSize: fontSize))
                        }
                    }
                    if model.geometryDraft != nil { model.cancelGeometryDraft(); try await waitForRender(model) }
                }
            }
            let report = Report(method: "Actual EditorView rendered in test-owned native windows", fixture: fixture.lastPathComponent,
                renderedWidth: frame.image.width, renderedHeight: frame.image.height,
                limitations: ["Initial and reached rectangles, unshrunk font, exact numeric text fit, scroll reachability, stable window frame and nonblank pixels are checked. Initial and reached screenshots are separate.",
                    "Screenshots do not prove pointer, focus, scrolling, reset or VoiceOver interaction."], snapshots: snapshots)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
            print("PASS: \(snapshots.count) parameter input matrix snapshots")
            return
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
                    size: size, expectedFields: 1, output: output, renderModel: model))
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
            guard model.beginGeometryDraft() else { throw RenderError.failed("Could not begin geometry draft") }
            model.updateGeometryDraft { geometry in
                geometry.cropX = 0.08; geometry.cropY = 0.12
                geometry.cropWidth = 0.72; geometry.cropHeight = 0.68
                geometry.straightenDegrees = -1.2
                geometry.perspectiveHorizontal = 0.3; geometry.perspectiveVertical = -0.2
            }
            try await waitForRender(model)
            snapshots.append(try await snapshot(GeometryControls(model: model)
                .frame(width: 650, height: 180).background(Color(nsColor: .windowBackgroundColor)),
                name: "crop-workspace-650", language: language, size: NSSize(width: 650, height: 180),
                expectedFields: 1, output: output))
            snapshots.append(try await snapshot(GeometryControls(model: model, showsPreciseCrop: true)
                .frame(width: 650, height: 310).background(Color(nsColor: .windowBackgroundColor)),
                name: "crop-precise-workspace-650", language: language, size: NSSize(width: 650, height: 310),
                expectedFields: 5, output: output))
            for (name, size) in [("geometry-editor-minimum", NSSize(width: 950, height: 620)),
                                 ("geometry-editor-wide", NSSize(width: 1440, height: 900))] {
                snapshots.append(try await snapshot(EditorView(model: model), name: name, language: language,
                    size: size, expectedFields: 1, output: output, renderModel: model))
            }
            _ = model.selectGeometryDraftTab(.perspective)
            snapshots.append(try await snapshot(MacGeometryWorkspace(model: model)
                .frame(width: 650, height: 260).background(Color(nsColor: .windowBackgroundColor)),
                name: "perspective-draft-workspace-650", language: language, size: NSSize(width: 650, height: 260),
                expectedFields: 2, output: output, renderModel: model))
            _ = model.selectGeometryDraftTab(.lens)
            snapshots.append(try await snapshot(MacGeometryWorkspace(model: model)
                .frame(width: 650, height: 290).background(Color(nsColor: .windowBackgroundColor)),
                name: "lens-draft-workspace-650", language: language, size: NSSize(width: 650, height: 290),
                expectedFields: 0, output: output, renderModel: model))
            model.requestLeavingGeometryDraft {}
            snapshots.append(try await snapshot(MacGeometryDeparturePrompt(model: model)
                .frame(width: 540, height: 290).background(Color(nsColor: .windowBackgroundColor)),
                name: "draft-departure", language: language, size: NSSize(width: 540, height: 290),
                expectedFields: 0, output: output))
            model.resolveGeometryDraftDeparture(.stay)
            model.cancelGeometryDraft()
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
                          "Minimum 72×26 native field geometry, unshrunk font, numeric text fit, direct locale lookup, field containment, and nonblank bitmap are strict automated checks; label wrapping requires visual inspection.",
                          "Actual mouse, keyboard, scroll-wheel, focus traversal, and VoiceOver verification remain pending while the Mac is locked.",
                          "These view snapshots do not establish that the complete native/core test gate has passed."], snapshots: snapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
        print("PASS: \(snapshots.count) native view snapshots; original RAW size and modification time unchanged")
    }
}
