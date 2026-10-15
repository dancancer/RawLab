import AppKit
import SwiftUI

@main enum MacCropPresentationTests {
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

    @MainActor private static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/rawlab-mac-crop-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let canvas = CGSize(width: 650, height: 420)
        let source = CGSize(width: 1200, height: 800)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.message("fixture context unavailable")
        }
        for y in 0..<800 {
            context.setFillColor(CGColor(red: 0.25 + CGFloat(y) / 2000,
                green: 0.6, blue: 0.75 - CGFloat(y) / 2500, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: 1200, height: 1))
        }
        guard let image = context.makeImage() else { throw Failure.message("fixture image unavailable") }
        let identity = ObjectIdentifier(image)
        let fit: CGFloat = 0.495
        let bounds = MacCropInteraction.imageBounds(canvasSize: canvas, renderedSize: source, factor: fit, pan: .zero)
        var settings = GeometrySettings()
        settings.cropX = 0.1; settings.cropY = 0.15; settings.cropWidth = 0.7; settings.cropHeight = 0.65
        let selection = MacCropInteraction.selectionBounds(crop: MacCropInteraction.rect(from: settings), imageBounds: bounds)
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            checks += 1
            guard condition else { throw Failure.message(message) }
        }

        var drag = MacCropDragSession(handle: .move, settings: settings, imageBounds: bounds,
            canvasSize: source, aspectRatio: nil, previewIdentity: identity)
        let first = drag.applying(translation: CGSize(width: 20, height: 10))
        try check(drag.canContinue(settings: first, imageBounds: bounds, canvasSize: source,
            aspectRatio: nil, previewIdentity: identity), "own callback preserves entry baseline")
        try check(drag.canContinue(settings: settings, imageBounds: bounds, canvasSize: source,
            aspectRatio: nil, previewIdentity: identity, allowingUnrefreshedSettings: true),
            "fast drag tolerates its own callback before SwiftUI refresh")
        drag.observeAppliedSettings()
        try check(!drag.canContinue(settings: settings, imageBounds: bounds, canvasSize: source,
            aspectRatio: nil, previewIdentity: identity, allowingUnrefreshedSettings: true),
            "acknowledged callback cannot hide an external rollback")
        let second = drag.applying(translation: CGSize(width: 30, height: 15))
        try check(abs(second.cropX - settings.cropX - 30 / bounds.width) < 1e-9,
            "successive gesture values apply total translation once")
        let anotherDrag = MacCropDragSession(handle: .move, settings: second, imageBounds: bounds,
            canvasSize: source, aspectRatio: nil, previewIdentity: identity)
        try check(anotherDrag.baseline == second, "next drag takes independent current baseline")
        try check(!drag.canContinue(settings: settings, imageBounds: bounds, canvasSize: source,
            aspectRatio: nil, previewIdentity: identity), "external settings invalidate active drag")
        try check(!drag.canContinue(settings: second, imageBounds: bounds, canvasSize: source,
            aspectRatio: 1, previewIdentity: identity), "aspect selection invalidates active drag")
        let replacement = NSObject()
        try check(!drag.canContinue(settings: second, imageBounds: bounds, canvasSize: source,
            aspectRatio: nil, previewIdentity: ObjectIdentifier(replacement)), "new preview invalidates active drag")
        try check(!drag.canContinue(settings: second, imageBounds: bounds.offsetBy(dx: 10, dy: 0), canvasSize: source,
            aspectRatio: nil, previewIdentity: identity), "pan or fit replacement invalidates active drag")
        try check(!drag.canContinue(settings: second, imageBounds: bounds, canvasSize: CGSize(width: 800, height: 1200),
            aspectRatio: nil, previewIdentity: identity), "rotated native dimensions invalidate active drag")

        for discreteEdit in ["keyboard", "accessibility"] {
          for refreshed in [false, true] {
            var pointer = MacCropPointerState()
            let entry = MacCropDragSession(handle: .move, settings: settings, imageBounds: bounds,
                canvasSize: source, aspectRatio: nil, previewIdentity: identity)
            try check(pointer.begin(entry), "\(discreteEdit): pointer drag starts")
            guard let latest = pointer.applying(translation: CGSize(width: 20, height: 10)) else {
                throw Failure.message("\(discreteEdit): pointer update missing")
            }
            if refreshed { pointer.session?.observeAppliedSettings() }
            let discreteDelta = discreteEdit == "keyboard" ?
                MacCropInteraction.keyboardTranslation(for: .move, direction: .right, fine: true, imageBounds: bounds) :
                CGSize(width: 0.01, height: 0)
            var current = pointer.discreteAdjustment(settings: refreshed ? latest : settings,
                imageBounds: bounds, canvasSize: source, aspectRatio: nil, previewIdentity: identity,
                handle: .move, translation: discreteDelta)
            try check(pointer.ignoresCurrentGesture && pointer.session == nil,
                "\(discreteEdit): production discrete adjustment interrupts active pointer")
            try check(abs(current.cropX - settings.cropX - 20 / bounds.width - discreteDelta.width) < 1e-9 &&
                abs(current.cropY - settings.cropY - 10 / bounds.height) < 1e-9,
                "\(discreteEdit): \(refreshed ? "refreshed" : "stale") view preserves latest pointer position before discrete delta")
            let afterDiscreteEdit = current
            let staleEntry = MacCropDragSession(handle: .move, settings: current, imageBounds: bounds,
                canvasSize: source, aspectRatio: nil, previewIdentity: identity)
            try check(!pointer.begin(staleEntry), "\(discreteEdit): same held gesture cannot rebuild a shifted baseline")
            if let stale = pointer.applying(translation: CGSize(width: 40, height: 20)) { current = stale }
            try check(current == afterDiscreteEdit, "\(discreteEdit): next cumulative pointer translation does not jump crop")
            try check(!pointer.finish(), "\(discreteEdit): ended interrupted gesture does not end editing a second time")
            pointer.endGesture()
            try check(pointer.begin(staleEntry), "\(discreteEdit): independent next drag starts after onEnded")
            guard let next = pointer.applying(translation: CGSize(width: 10, height: 5)) else {
                throw Failure.message("\(discreteEdit): independent pointer update missing")
            }
            try check(abs(next.cropX - afterDiscreteEdit.cropX - 10 / bounds.width) < 1e-9 &&
                abs(next.cropY - afterDiscreteEdit.cropY - 5 / bounds.height) < 1e-9,
                "\(discreteEdit): independent drag uses its own current baseline")
          }
        }

        for invalidation in ["acknowledged rollback", "external reset", "preview replacement", "bounds replacement"] {
            var pointer = MacCropPointerState()
            let entry = MacCropDragSession(handle: .move, settings: settings, imageBounds: bounds,
                canvasSize: source, aspectRatio: nil, previewIdentity: identity)
            _ = pointer.begin(entry)
            _ = pointer.applying(translation: CGSize(width: 20, height: 10))
            if invalidation == "acknowledged rollback" { pointer.session?.observeAppliedSettings() }
            let external = invalidation == "external reset" ? GeometrySettings() : settings
            let newBounds = invalidation == "bounds replacement" ? bounds.offsetBy(dx: 10, dy: 0) : bounds
            let newIdentity = invalidation == "preview replacement" ? ObjectIdentifier(replacement) : identity
            let result = pointer.discreteAdjustment(settings: external, imageBounds: newBounds, canvasSize: source,
                aspectRatio: nil, previewIdentity: newIdentity, handle: .move, translation: CGSize(width: 0.01, height: 0))
            let expectedX = min(1 - external.cropWidth, external.cropX + 0.01)
            try check(abs(result.cropX - expectedX) < 1e-9 && result.cropY == external.cropY &&
                result.cropWidth == external.cropWidth && result.cropHeight == external.cropHeight,
                "\(invalidation): production discrete edit uses external settings without reviving old pointer position")
            try check(pointer.ignoresCurrentGesture && pointer.session == nil &&
                pointer.applying(translation: CGSize(width: 40, height: 20)) == nil,
                "\(invalidation): invalidated old gesture remains blocked")
        }

        let baseline = try await snapshot(CropFixture(image: image, bounds: bounds, source: source,
            settings: nil), name: "photo-baseline", size: canvas, output: output)
        let grid = try await snapshot(CropFixture(image: image, bounds: bounds, source: source,
            settings: settings), name: "crop-handles-grid", size: canvas, output: output)
        let noGrid = try await snapshot(CropFixture(image: image, bounds: bounds, source: source,
            settings: settings, showsGrid: false), name: "crop-handles-no-grid", size: canvas, output: output)
        let staticCrop = try await snapshot(CropFixture(image: image, bounds: bounds, source: source,
            settings: settings, editable: false), name: "crop-static-preview", size: canvas, output: output)
        let outside = CGPoint(x: bounds.minX + 15, y: bounds.minY + 15)
        let inside = CGPoint(x: selection.midX + 10, y: selection.midY + 10)
        let beforeOutside = luminance(baseline, at: outside)
        let afterOutside = luminance(grid, at: outside)
        try check(afterOutside < beforeOutside * 0.65, "crop exterior is darkened")
        try check(abs(luminance(baseline, at: inside) - luminance(grid, at: inside)) < 0.03,
            "crop interior keeps image brightness")
        let gridPoint = CGPoint(x: selection.minX + selection.width / 3, y: selection.midY)
        try check(abs(luminance(grid, at: gridPoint) - luminance(noGrid, at: gridPoint)) > 0.05,
            "thirds grid toggle changes only its overlay")
        let cornerPoint = CGPoint(x: selection.minX + 10, y: selection.minY)
        try check(luminance(grid, at: cornerPoint) > luminance(staticCrop, at: cornerPoint) + 0.03,
            "static preview omits thick interactive corner marks")

        var square = settings
        square = MacCropInteraction.applying(rect: MacCropInteraction.fitting(ratio: 1, in: source,
            around: MacCropInteraction.rect(from: square)), to: square)
        _ = try await snapshot(CropFixture(image: image, bounds: bounds, source: source, settings: square,
            aspectRatio: 1), name: "crop-physical-square", size: canvas, output: output)
        let zoomBounds = MacCropInteraction.imageBounds(canvasSize: canvas, renderedSize: source,
            factor: fit * 1.6, pan: CGSize(width: 35, height: -20))
        _ = try await snapshot(CropFixture(image: image, bounds: zoomBounds, source: source,
            settings: settings), name: "crop-zoom-pan", size: canvas, output: output)
        let report: [String: Any] = ["method": "Own NSHostingView cacheDisplay in an unshown test window",
            "checks": checks, "snapshots": 6, "canvasWidth": 650, "canvasHeight": 420,
            "physicalSquare": square.cropWidth * 1200 / (square.cropHeight * 800),
            "pending": ["Real mouse, keyboard and VoiceOver acceptance after unlock"]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("report.json"))
        print("PASS \(checks) crop drag lifecycle/layout checks; 6 native snapshots at \(output.path)")
    }

    @MainActor private static func snapshot<V: View>(_ view: V, name: String, size: CGSize,
        output: URL) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure.message("\(name): bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let logicalWidth = Int(size.width), logicalHeight = Int(size.height)
        let oneX = bitmap.pixelsWide == logicalWidth && bitmap.pixelsHigh == logicalHeight
        let twoX = bitmap.pixelsWide == logicalWidth * 2 && bitmap.pixelsHigh == logicalHeight * 2
        guard (oneX || twoX), let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.message("\(name): PNG unavailable or unexpected dimensions (logical \(logicalWidth)x\(logicalHeight), backing \(bitmap.pixelsWide)x\(bitmap.pixelsHigh))")
        }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        guard let normalized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: logicalWidth, pixelsHigh: logicalHeight,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: normalized) else {
            throw Failure.message("\(name): logical-size sampling bitmap unavailable")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        bitmap.draw(in: NSRect(origin: .zero, size: size))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return normalized
    }

    private static func luminance(_ bitmap: NSBitmapImageRep, at point: CGPoint) -> CGFloat {
        guard let color = bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB) else { return -1 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    private enum Failure: Error { case message(String) }
}

private struct CropFixture: View {
    let image: CGImage
    let bounds: CGRect
    let source: CGSize
    let settings: GeometrySettings?
    var showsGrid = true
    var editable = true
    var aspectRatio: Double? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.065)
            Image(decorative: image, scale: 1).resizable()
                .frame(width: bounds.width, height: bounds.height)
                .position(x: bounds.midX, y: bounds.midY)
            if let settings {
                MacCropOverlay(settings: settings, imageBounds: bounds, canvasSize: source,
                    previewIdentity: ObjectIdentifier(image), aspectRatio: aspectRatio, showsGrid: showsGrid,
                    onChange: editable ? { _ in } : nil)
            }
        }.frame(width: 650, height: 420).clipped()
    }
}
