import AppKit
import SwiftUI

enum HDRLookAssetStore {
    static func installHDRSilver() throws -> HDRLookSettings { fatalError("unused in rendition reset test") }
    static func install(_ url: URL) throws -> HDRLookSettings { fatalError("unused in rendition reset test") }
}

enum HDRCameraProfileAssetStore {
    static func url(for profile: HDRCameraProfile) throws -> URL { fatalError("unused in rendition reset test") }
    static func install(_ url: URL) throws -> HDRCameraProfile { fatalError("unused in rendition reset test") }
}

@MainActor private final class RenditionResetHostModel: ObservableObject {
    @Published var settings = HDRRenditionSettings()
    var writes = 0

    var binding: Binding<HDRRenditionSettings> {
        Binding(get: { self.settings }, set: { self.writes += 1; self.settings = $0 })
    }

    var controls: HDRRenditionControls {
        HDRRenditionControls(settings: binding, onEditingChanged: { _ in }, onCancelled: {})
    }
}

private struct FullControlsProbeView: View {
    @ObservedObject var model: RenditionResetHostModel
    var body: some View {
        model.controls.fixedSize()
    }
}

@main struct HDRRenditionResetTests {
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

    enum Failure: Error, CustomStringConvertible {
        case assertion(String)
        var description: String {
            switch self { case .assertion(let message): return message }
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        print("PASS: \(message)")
    }

    @MainActor static func settle<V: View>(_ host: NSHostingView<V>) async throws {
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func buttons(in view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }

    @MainActor static func requireResetButton(in view: NSView) throws -> NSButton {
        let candidates = buttons(in: view)
        guard candidates.count == 1, let button = candidates.first else {
            throw Failure.assertion("Expected a single materialized reset NSButton in HDRRenditionControls, found \(candidates.count)")
        }
        return button
    }

    @MainActor static func run() async throws {
        let model = RenditionResetHostModel()
        let host = NSHostingView(rootView: FullControlsProbeView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)

        // 1. 默认状态：表示模型携带 hdr.rendition.reset 与本地化「重置」文案，默认态禁用
        let initial = model.controls.resetPresentation
        try check(initial.identifier == "hdr.rendition.reset",
                  "Reset control uses accessibilityIdentifier hdr.rendition.reset")
        try check(initial.title == L10n.text("重置"),
                  "Reset control reuses existing localized title key")
        try check(!initial.isEnabled,
                  "Reset presentation is disabled when rendition settings are default")

        // 2. 无 AX 环境下真实 NSHostingView 视图树断言：物化 NSButton 尺寸非空、默认禁用且点击无副作用
        let defaultButton = try requireResetButton(in: host)
        try check(!defaultButton.isHidden && defaultButton.frame.width > 12 && defaultButton.frame.height > 10 &&
                  host.fittingSize.width > defaultButton.frame.width,
                  "Materialized reset NSButton has non-zero layout bounds (\(defaultButton.frame.size)) inside header (\(host.fittingSize))")
        try check(!defaultButton.isEnabled,
                  "Materialized reset NSButton is disabled when rendition settings are default")
        defaultButton.performClick(nil)
        try check(model.writes == 0,
                  "Disabled reset NSButton ignores performClick")

        // 3. 四项中任意单项改动后，表示模型与真实 NSButton 同步切换为启用态
        for (name, mutate) in [
            ("peakLimitEV", { (s: inout HDRRenditionSettings) in s.peakLimitEV = 1.5 }),
            ("sdrExposureEV", { (s: inout HDRRenditionSettings) in s.sdrExposureEV = -0.8 }),
            ("sdrContrast", { (s: inout HDRRenditionSettings) in s.sdrContrast = 12 }),
            ("sdrSaturation", { (s: inout HDRRenditionSettings) in s.sdrSaturation = -18 }),
        ] {
            var edited = HDRRenditionSettings()
            mutate(&edited)
            model.settings = edited
            try await settle(host)
            let active = model.controls.resetPresentation
            let button = try requireResetButton(in: host)
            try check(active.identifier == "hdr.rendition.reset" && active.isEnabled && button.isEnabled,
                      "Reset presentation and materialized NSButton enable when \(name) is modified")
        }

        // 4. 四项同时改动后穿透真实 NSButton.performClick(nil)：走通 onReset -> reset() -> 共享绑定单次写回并回到禁用态
        var combined = HDRRenditionSettings()
        combined.peakLimitEV = 2.4
        combined.sdrExposureEV = -1.2
        combined.sdrContrast = 35
        combined.sdrSaturation = -25
        model.settings = combined
        model.writes = 0
        try await settle(host)
        let activeButton = try requireResetButton(in: host)
        try check(model.controls.resetPresentation.isEnabled && activeButton.isEnabled,
                  "Materialized reset NSButton is enabled when all four rendition fields are modified")

        activeButton.performClick(nil)
        try await settle(host)
        try check(model.settings == HDRRenditionSettings() && model.settings.isDefault,
                  "performClick on reset NSButton restores all four HDR rendition fields to default")
        try check(model.writes == 1,
                  "performClick on reset NSButton writes once through shared binding for a single undo entry")
        let afterResetButton = try requireResetButton(in: host)
        try check(!model.controls.resetPresentation.isEnabled && !afterResetButton.isEnabled,
                  "Materialized reset NSButton returns to disabled state after reset")
    }
}
