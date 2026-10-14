import AppKit
import SwiftUI

private struct InteractionFailure: Error, CustomStringConvertible { let description: String }

@main @MainActor struct GeometryInteractionTests {
    private static var checks = 0
    private static var interactionModel: EditorModel?

    static func main() {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let mode = CommandLine.arguments.contains("--probe") ? "probe" :
            (CommandLine.arguments.contains("--layouts-only") ? "layouts" : "confirm")
        let log = output.appendingPathComponent("native-events-\(mode).log")
        freopen(log.path, "w", stdout)
        dup2(STDOUT_FILENO, STDERR_FILENO)
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        UserDefaults.standard.setVolatileDomain([L10n.preferenceKey: "en"], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                try await run()
                try "PASS\n".write(to: output.appendingPathComponent("result-\(mode).txt"), atomically: true, encoding: .utf8)
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                try? "FAIL: \(error)\n".write(to: output.appendingPathComponent("result-\(mode).txt"), atomically: true, encoding: .utf8)
                exit(1)
            }
        }
        app.run()
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        guard condition else { throw InteractionFailure(description: message) }
        print("CHECK: \(message)")
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private static func waitForRender(_ model: EditorModel) async throws {
        try await settle()
        for _ in 0..<1200 {
            if !model.busy && model.result != nil { return }
            if let error = model.error { throw InteractionFailure(description: error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw InteractionFailure(description: "Render did not finish")
    }

    private static func elements(in object: Any) -> [NSAccessibilityProtocol] {
        var found: [NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard let element = value as? NSAccessibilityProtocol else { return }
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            found.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child) }
        }
        visit(object)
        return found
    }

    private static func element(_ identifier: String, in host: NSView) throws -> NSAccessibilityProtocol {
        guard let result = elements(in: host).first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw InteractionFailure(description: "Accessibility element missing: \(identifier)")
        }
        return result
    }

    private static func press(_ identifier: String, in host: NSView) async throws {
        if let control = elements(in: host).first(where: { $0.accessibilityIdentifier() == identifier }) {
            try check(control.accessibilityPerformPress(), "Native accessibility press: \(identifier)")
        } else if identifier == "tool.geometry" {
            let targets = views(in: host).filter {
                String(describing: type(of: $0)) == "_FocusRingView" && abs($0.bounds.width - 72) < 1 && abs($0.bounds.height - 70) < 1
            }
            guard let target = targets.max(by: { host.convert($0.bounds, from: $0).midX < host.convert($1.bounds, from: $1).midX }) else {
                throw InteractionFailure(description: "Visible geometry tool hit region is missing")
            }
            let rect = host.convert(target.bounds, from: target)
            try postMouse(at: CGPoint(x: rect.midX, y: rect.midY), in: host, by: .zero, drag: false)
            print("NATIVE_CLICK: visible final dock tool at \(rect)")
        } else if identifier == "geometry.aspectSwap" {
            let header = try headerTargets(in: host)
            let left = header.map(\.minX).min()!
            let bottom = header.map(\.maxY).max()!
            var targets: [CGRect] = []
            for view in views(in: host) where String(describing: type(of: view)) == "_FocusRingView" {
                let rect = host.convert(view.bounds, from: view)
                let small = rect.width >= 18 && rect.width <= 45 && rect.height >= 18 && rect.height <= 30
                let inRow = rect.minY > bottom && rect.minY < bottom + 45 && rect.minX > left + 170
                if small && inRow { targets.append(rect) }
            }
            targets.sort { $0.minX < $1.minX }
            guard let rect = targets.first else { throw InteractionFailure(description: "Native aspect swap hit region is missing") }
            try postMouse(at: CGPoint(x: rect.midX, y: rect.midY), in: host, by: .zero, drag: false)
            print("NATIVE_CLICK: aspect swap at \(rect)")
        } else {
            let targets = try headerTargets(in: host).sorted { $0.midX > $1.midX }
            let index = identifier == "geometry.apply" ? 0 : (identifier == "geometry.cancel" ? 1 : 2)
            guard targets.count > index else { throw InteractionFailure(description: "Native action not found: \(identifier)") }
            try postMouse(at: CGPoint(x: targets[index].midX, y: targets[index].midY), in: host, by: .zero, drag: false)
            print("NATIVE_CLICK: \(identifier) at \(targets[index])")
        }
        try await settle()
    }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private static func headerTargets(in host: NSView) throws -> [CGRect] {
        let toolBottom = views(in: host).filter { String(describing: type(of: $0)) == "_FocusRingView" && abs($0.bounds.height - 70) < 1 }
            .map { host.convert($0.bounds, from: $0).maxY }.max() ?? 675
        var all: [CGRect] = []
        for view in views(in: host) where String(describing: type(of: view)) == "_FocusRingView" || view is NSButton {
            let rect = host.convert(view.bounds, from: view)
            let inRow = rect.minY > toolBottom && rect.minY < toolBottom + 70
            let sized = rect.width >= 14 && rect.width <= 200 && rect.height >= 18 && rect.height <= 30
            if inRow && sized { all.append(rect) }
        }
        guard let top = all.map(\.minY).min() else { throw InteractionFailure(description: "Native geometry action hit regions are missing") }
        var unique: [CGRect] = []
        for rect in all.filter({ abs($0.minY - top) < 4 }) {
            if !unique.contains(where: { abs($0.midX - rect.midX) < 2 && abs($0.midY - rect.midY) < 2 }) { unique.append(rect) }
        }
        return unique
    }

    private static func exposeGeometryTool(in host: NSView) async throws {
        for scroll in views(in: host).compactMap({ $0 as? NSScrollView }) {
            if let document = scroll.documentView, document.bounds.width > scroll.contentView.bounds.width + 200,
               scroll.frame.height < 130 {
                scroll.contentView.scroll(to: CGPoint(x: document.bounds.width - scroll.contentView.bounds.width, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        try await settle()
    }

    private static func drag(_ identifier: String, by delta: CGSize, in host: NSView, window: NSWindow) async throws {
        guard let model = interactionModel, let frame = model.result,
              let canvas = views(in: host).first(where: { String(describing: type(of: $0)) == "_PlatformDraggingDestinationView" }) else {
            throw InteractionFailure(description: "Actual editor canvas is missing")
        }
        let bounds = host.convert(canvas.bounds, from: canvas)
        let fit = min((bounds.width - 24) / CGFloat(frame.image.width), (bounds.height - 24) / CGFloat(frame.image.height))
        let image = CGRect(x: bounds.midX - CGFloat(frame.image.width) * fit / 2,
                           y: bounds.midY - CGFloat(frame.image.height) * fit / 2,
                           width: CGFloat(frame.image.width) * fit, height: CGFloat(frame.image.height) * fit)
        let crop = model.geometryDraft
        let rect = CGRect(x: image.minX + crop.cropX * image.width, y: image.minY + crop.cropY * image.height,
                          width: crop.cropWidth * image.width, height: crop.cropHeight * image.height)
        let point: CGPoint
        switch identifier {
        case "geometry.crop.topLeft": point = CGPoint(x: rect.minX + 22, y: rect.minY + 22)
        case "geometry.crop.bottomRight": point = CGPoint(x: rect.maxX - 22, y: rect.maxY - 22)
        default: point = CGPoint(x: rect.midX, y: rect.midY)
        }
        if identifier == "geometry.crop.move" {
            let expected = CropInteraction.dragging(CropInteraction.rect(from: crop), handle: .move,
                translation: CGSize(width: delta.width / image.width, height: -delta.height / image.height),
                canvasSize: model.geometryCanvasSize, ratio: model.geometryAspectRatio)
            try check(expected != CropInteraction.rect(from: crop), "Interior gesture target is legal and changes before boundary clamping")
            print("EXPECTED_MOVE: \(CropInteraction.rect(from: crop)) -> \(expected)")
        }
        try check(bounds.width > 0 && bounds.height > 0, "Gesture target uses the actual native canvas: \(identifier)")
        try postMouse(at: point, in: host, by: delta, drag: true)
        try await settle()
        print("GESTURE: \(identifier) at host \(point) by \(delta); canvas \(bounds)")
    }

    private static func postMouse(at point: CGPoint, in host: NSView, by delta: CGSize, drag: Bool) throws {
        guard let window = host.window else { throw InteractionFailure(description: "Mouse target window is missing") }
        let start = host.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let steps = drag ? 9 : 1
        for index in 0...steps {
            let type: NSEvent.EventType = index == 0 ? .leftMouseDown : (index == steps ? .leftMouseUp : .leftMouseDragged)
            let fraction = drag ? CGFloat(min(8, max(0, index))) / 8 : 0
            let point = CGPoint(x: start.x + delta.width * fraction, y: start.y + delta.height * fraction)
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: timestamp + Double(index) / 60, windowNumber: window.windowNumber, context: nil,
                eventNumber: index + 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw InteractionFailure(description: "Could not create mouse event")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func chooseAspect(_ title: String, in host: NSView) async throws {
        let candidates = views(in: host).compactMap { $0 as? NSPopUpButton }
        guard let picker = candidates.first(where: { $0.itemTitles.contains(title) }) else {
            throw InteractionFailure(description: "Native crop ratio popup is missing")
        }
        try check(picker.itemTitles.contains(title), "Native ratio menu contains \(title)")
        picker.selectItem(withTitle: title)
        if let menu = picker.menu, let index = picker.itemTitles.firstIndex(of: title) {
            menu.performActionForItem(at: index)
            print("NATIVE_MENU_ACTION: \(title)")
        } else { throw InteractionFailure(description: "Native ratio menu item is missing") }
        try await settle()
    }

    private static func capture(_ name: String, host: NSView, window: NSWindow, output: URL) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw InteractionFailure(description: "Could not allocate actual window content capture")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let path = output.appendingPathComponent("\(name)-content.png")
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw InteractionFailure(description: "Could not encode window content")
        }
        try data.write(to: path)
        print("CAPTURE: NSHostingView actual window content \(path.path)")
        let screen = Process()
        screen.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let screenPath = output.appendingPathComponent("\(name)-window.png")
        screen.arguments = ["-x", "-l", String(window.windowNumber), screenPath.path]
        try screen.run(); screen.waitUntilExit()
        print("WINDOW_CAPTURE: status \(screen.terminationStatus), \(screenPath.path)")
    }

    private static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-geometry-native-\(UUID())")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let model = EditorModel(lookDirectory: state.appendingPathComponent("looks"),
            editDirectory: state.appendingPathComponent("edits"), batchDirectory: state.appendingPathComponent("batch"))
        model.films = []; model.selectedFilmID = ""
        interactionModel = model
        let host = NSHostingView(rootView: EditorView(model: model).environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "RawLab Geometry Native Interaction"
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        model.open(URL(fileURLWithPath: CommandLine.arguments[1]))
        try await waitForRender(model)
        try await exposeGeometryTool(in: host)
        try capture("00-editor-initial", host: host, window: window, output: output)
        let viewTree = views(in: host).map { view in
            "\(String(describing: type(of: view))) | \(view.accessibilityIdentifier()) | \(view.accessibilityLabel() ?? "-") | \(host.convert(view.bounds, from: view))"
        }.joined(separator: "\n")
        try viewTree.write(to: output.appendingPathComponent("native-views.txt"), atomically: true, encoding: .utf8)
        let tree = elements(in: host).map {
            "\($0.accessibilityIdentifier() ?? "-") | \($0.accessibilityLabel() ?? "-") | \($0.accessibilityFrame())"
        }.joined(separator: "\n")
        try tree.write(to: output.appendingPathComponent("accessibility-before.txt"), atomically: true, encoding: .utf8)
        try await press("tool.geometry", in: host)
        try await waitForRender(model)
        try check(model.geometryPreviewReady, "Actual geometry tool enters a ready draft session")
        try capture("01-crop-before", host: host, window: window, output: output)
        let committed = model.settings.geometrySettings
        let frame = model.result!.image
        let layoutsOnly = CommandLine.arguments.contains("--layouts-only")
        if !layoutsOnly {
        let before = model.geometryDraft
        try await drag("geometry.crop.topLeft", by: CGSize(width: 45, height: -35), in: host, window: window)
        try capture("02-crop-first-drag", host: host, window: window, output: output)
        try check(model.geometryDraft != before, "Corner mouse drag changes the actual SwiftUI crop binding")
        if CommandLine.arguments.contains("--probe") {
            print("PASS: Pre-fix corner gesture works")
            return
        }
        let first = model.geometryDraft
        try await drag("geometry.crop.topLeft", by: CGSize(width: 25, height: -20), in: host, window: window)
        try check(model.geometryDraft != first, "A second corner gesture resets its baseline and changes the crop")
        let second = model.geometryDraft
        try await drag("geometry.crop.bottomRight", by: CGSize(width: -35, height: 25), in: host, window: window)
        try check(model.geometryDraft != second, "An opposite corner also accepts a mouse gesture")
        let cornerSelection = model.geometryDraft
        try await drag("geometry.crop.move", by: CGSize(width: 14, height: -9), in: host, window: window)
        let firstMove = model.geometryDraft
        try check(firstMove != cornerSelection && firstMove.cropWidth == cornerSelection.cropWidth &&
                  firstMove.cropHeight == cornerSelection.cropHeight, "Interior mouse drag moves the selection without resizing")
        try await drag("geometry.crop.move", by: CGSize(width: -8, height: 5), in: host, window: window)
        try check(model.geometryDraft != firstMove, "A repeated interior gesture uses a fresh baseline")
        try check(!model.busy && model.result!.image === frame && model.settings.geometrySettings == committed,
                  "Mouse crop gestures preserve the rendered frame and committed geometry")
        }
        for (name, size) in [("wide", CGSize(width: 1200, height: 800)), ("minimum", CGSize(width: 950, height: 620))] {
            window.setContentSize(size)
            try await waitForRender(model)
            try await exposeGeometryTool(in: host)
            try capture("layout-crop-\(name)", host: host, window: window, output: output)
            let targets = try headerTargets(in: host)
            guard let mode = targets.min(by: { $0.minX < $1.minX }) else { throw InteractionFailure(description: "Geometry mode control is missing") }
            guard let canvas = views(in: host).first(where: { String(describing: type(of: $0)) == "_PlatformDraggingDestinationView" }) else {
                throw InteractionFailure(description: "Actual layout canvas is missing")
            }
            let bounds = host.convert(canvas.bounds, from: canvas)
            let controlLeft = bounds.midX - min(760, bounds.width - 32) / 2
            try postMouse(at: CGPoint(x: controlLeft + 120, y: mode.midY), in: host, by: .zero, drag: false)
            try await settle()
            let fields = views(in: host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            try check(fields.count == 3, "Correction shows its three numeric fields at \(name) size")
            try capture("layout-correction-\(name)", host: host, window: window, output: output)
            let sliders: [CGRect] = views(in: host).filter { String(describing: type(of: $0)) == "_FocusRingView" }
                .map { host.convert($0.bounds, from: $0) }.filter { $0.width > 200 && $0.height <= 24 && $0.minY > mode.maxY }
                .sorted { $0.minY < $1.minY }
            try check(sliders.count == 3, "Correction shows three native slider hit regions at \(name) size")
            if !layoutsOnly, name == "wide", let slider = sliders.first {
                try postMouse(at: CGPoint(x: slider.midX, y: slider.midY), in: host, by: CGSize(width: 38, height: 0), drag: true)
                try await settle()
                try check(model.geometryDraft.straightenDegrees != 0, "A continuous correction thumb gesture finishes after leaving zero")
                try await waitForRender(model)
                model.setGeometryDraft(.straightenDegrees, to: 0)
                try await waitForRender(model)
            }
            try postMouse(at: CGPoint(x: controlLeft + 40, y: mode.midY), in: host, by: .zero, drag: false)
            try await settle()
        }
        if layoutsOnly {
            print("PASS: Actual EditorView layout captures at both sizes; synthetic crop gesture checks were skipped")
            return
        }
        window.setContentSize(CGSize(width: 1200, height: 800)); try await waitForRender(model)
        try await chooseAspect("1:1", in: host)
        try check(model.geometryAspectPreset == .square && abs(model.geometryDraft.cropWidth * Double(model.geometryCanvasSize.width) /
            (model.geometryDraft.cropHeight * Double(model.geometryCanvasSize.height)) - 1) < 0.00001, "Square ratio changes through the native menu")
        try await chooseAspect("16:9", in: host)
        try check(model.geometryAspectPreset == .sixteenNine, "A second native ratio switch updates the draft")
        try await press("geometry.aspectSwap", in: host)
        try check(model.geometryAspectSwapped, "Portrait ratio swaps through the real button")
        try capture("03-ratio-portrait", host: host, window: window, output: output)
        let applied = model.geometryDraft
        try await press("geometry.apply", in: host)
        try await waitForRender(model)
        try check(!model.isEditingGeometry && model.settings.geometrySettings == applied, "Apply button commits the actual draft")
        try capture("04-applied", host: host, window: window, output: output)
        try await press("tool.geometry", in: host); try await waitForRender(model)
        try await drag("geometry.crop.topLeft", by: CGSize(width: 20, height: -15), in: host, window: window)
        try check(model.geometryDraft != applied, "Cancel scenario contains an actual pending mouse edit")
        try await press("geometry.cancel", in: host); try await waitForRender(model)
        try check(!model.isEditingGeometry && model.settings.geometrySettings == applied, "Cancel button restores the committed geometry")
        try capture("05-cancelled", host: host, window: window, output: output)
        try await press("tool.geometry", in: host); try await waitForRender(model)
        try await press("geometry.reset", in: host)
        try check(model.geometryDraft.isIdentity && model.settings.geometrySettings == applied, "Reset button clears only the actual draft")
        try capture("06-reset-draft", host: host, window: window, output: output)
        try await press("geometry.apply", in: host); try await waitForRender(model)
        try check(model.settings.geometrySettings.isIdentity, "Apply after reset commits full geometry")
        try capture("07-reset-applied", host: host, window: window, output: output)
        print("PASS: \(checks) actual EditorView native interaction checks; NSEvent mouse sequences plus Cocoa accessibility/control actions")
    }
}
