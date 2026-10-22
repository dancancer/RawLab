import Foundation

@main struct MacViewingTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) {
        guard condition() else { print("FAIL: \(text)"); exit(1) }
        count += 1; print("PASS: \(text)")
    }
    static func main() throws {
        var view = MacViewingState()
        check(!view.enabled && view.preferredMode == .sideBySide && view.split == 0.5 && view.margins, "comparison starts disabled with side-by-side, midpoint and margins")
        view.select(.wipe); view.close(); view.toggle()
        check(view.enabled && view.preferredMode == .wipe, "closing and reopening restores the preferred comparison mode")
        view.hold(true, allowed: true)
        check(!view.holdingBefore, "persistent comparison excludes temporary before")
        view.close(); view.hold(true, allowed: true)
        check(view.holdingBefore, "hold is a temporary override without changing preferred wipe")
        view.hold(true, allowed: false)
        check(!view.holdingBefore && view.preferredMode == .wipe, "draft or missing reference clears temporary before")
        view.setSplit(-4); check(view.split == 0, "split clamps to photo left edge")
        view.setSplit(3); check(view.split == 1, "split clamps to photo right edge")
        view.setSplit(.nan); check(view.split == 1, "nonfinite split is ignored")
        view.moveSplit(-0.01); check(view.split == 0.99, "split keyboard or accessibility step is normalized")
        view.hold(true, allowed: true); view.sourceChanged()
        check(!view.holdingBefore && !view.enabled && view.preferredMode == .wipe && view.split == 0.5, "source change clears temporary state and old split but retains mode preference")
        check(MacViewingState.horizontalPanes(in: CGSize(width: 800, height: 400)), "wide photo area selects left and right panes")
        check(!MacViewingState.horizontalPanes(in: CGSize(width: 400, height: 800)), "tall photo area selects upper and lower panes")

        var viewport = PhotoViewport()
        viewport.moveFocus(from: CGPoint(x: 0.5, y: 0.5), translation: CGSize(width: -120, height: 80), displayed: CGSize(width: 800, height: 600))
        let large = viewport.pan(displayed: CGSize(width: 800, height: 600))
        let small = viewport.pan(displayed: CGSize(width: 400, height: 300))
        check(abs(large.width + 120) < 0.001 && abs(large.height - 80) < 0.001, "drag updates one photo-coordinate focal point")
        check(abs(small.width / large.width - 0.5) < 0.001 && abs(small.height / large.height - 0.5) < 0.001, "pane resize reprojects pan instead of sharing screen offset")
        let focused = viewport.focus
        viewport.zoom(by: 2)
        check(viewport.focus == focused, "zoom preserves the common photo focal point")
        let source = CGSize(width: 6000, height: 4000), canvas = CGSize(width: 424, height: 624)
        check(viewport.previewLongEdge(canvas: canvas, displayScale: 2, source: source, margin: 0) >= viewport.previewLongEdge(canvas: canvas, displayScale: 2, source: source), "removing margin changes only viewport demand and keeps a complete fit")
        viewport.fit(); check(viewport.focus == CGPoint(x: 0.5, y: 0.5), "fit resets photo focus")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-reference-key-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("source.dng"); try Data([1]).write(to: file)
        let identity = MacReferenceSource(file, raster: false)
        let settings = Adjustments(), base = MacNeutralReferenceKey(source: identity, settings: settings, edge: 800)
        var color = settings; color.exposure = 2; color.temperature = 7777; color.setHSL(.hue, channel: 0, value: 12.3)
        check(base == MacNeutralReferenceKey(source: identity, settings: color, edge: 800), "neutral key excludes user exposure, WB and HSL")
        var lens = settings; lens.lensCorrection = LensCorrectionSettings()
        lens.lensCorrection?.distortion = true
        let lensKey = MacNeutralReferenceKey(source: identity, settings: lens, edge: 800)
        check(base.usesOriginal && !lensKey.usesOriginal && base != lensKey, "lens-only edit cannot reuse uncorrected original reference")
        var geometry = settings; geometry.geometry = GeometrySettings(); geometry.geometry?.quarterTurns = 1
        check(base != MacNeutralReferenceKey(source: identity, settings: geometry, edge: 800), "committed geometry participates in reference identity")
        var legacy = settings; legacy.processing = .legacy
        check(base != MacNeutralReferenceKey(source: identity, settings: legacy, edge: 800), "processing identity participates in reference identity")
        check(base.canServe(MacNeutralReferenceKey(source: identity, settings: settings, edge: 1600), fullResolution: true), "immutable full-native reference satisfies a larger pane without rerender")
        check(!base.canServe(MacNeutralReferenceKey(source: identity, settings: settings, edge: 1600), fullResolution: false), "a bounded reference cannot satisfy a different pane demand")
        check(base != MacNeutralReferenceKey(source: identity, settings: settings, edge: 1600), "requested pane demand participates in reference identity")
        check(base != MacNeutralReferenceKey(source: MacReferenceSource(file, raster: true), settings: settings, edge: 800), "input kind participates in reference identity")
        try Data([1,2]).write(to: file)
        check(identity != MacReferenceSource(file, raster: false), "same path rewritten source invalidates neutral identity")
        print("PASS: \(count) Mac viewing checks")
    }
}
