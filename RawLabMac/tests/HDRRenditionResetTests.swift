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

private struct ResetControlProbeView: View {
    let presentation: HDRRenditionResetPresentation?
    var body: some View {
        HDRRenditionResetControl(presentation: presentation, onReset: {})
    }
}

private struct FullControlsProbeView: View {
    @ObservedObject var model: RenditionResetHostModel
    var body: some View {
        model.controls.fixedSize()
    }
}

private struct HeaderWithoutResetProbeView: View {
    var body: some View {
        DisclosureGroup {
            EmptyView()
        } label: {
            HStack {
                Text(L10n.text("HDR 输出与 SDR 底图"))
                Spacer()
            }
        }
        .fixedSize()
    }
}

@main struct HDRRenditionResetTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try run(); exit(0) }
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

    @MainActor static func requirePresentation(_ value: HDRRenditionResetPresentation?, _ message: String) throws -> HDRRenditionResetPresentation {
        guard let value else { throw Failure.assertion(message) }
        return value
    }

    @MainActor static func measure<V: View>(_ view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.invalidateIntrinsicContentSize()
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor static func run() throws {
        let model = RenditionResetHostModel()

        // 1. 默认状态：控件存在、identifier 为 hdr.rendition.reset、标题复用现有「重置」、默认态禁用
        let initial = try requirePresentation(
            model.controls.resetPresentation,
            "Missing HDRRenditionResetPresentation on HDRRenditionControls"
        )
        try check(initial.identifier == "hdr.rendition.reset",
                  "Reset control uses accessibilityIdentifier hdr.rendition.reset")
        try check(initial.title == L10n.text("重置"),
                  "Reset control reuses existing localized title key")
        try check(!initial.isEnabled,
                  "Reset control is disabled when rendition settings are default")

        // 2. 真实 SwiftUI/NSHostingView 布局尺寸断言（不依赖辅助功能权限）：撤掉按钮会直接变红
        let resetSize = measure(ResetControlProbeView(presentation: initial))
        let hiddenSize = measure(ResetControlProbeView(presentation: nil))
        try check(resetSize.width > 12 && resetSize.height > 10,
                  "Rendered HDRRenditionResetControl has non-zero layout bounds (\(resetSize))")
        try check(hiddenSize.width < 1 && hiddenSize.height < 1,
                  "Nil presentation collapses HDRRenditionResetControl layout bounds")

        let fullHeaderSize = measure(FullControlsProbeView(model: model))
        let bareHeaderSize = measure(HeaderWithoutResetProbeView())
        try check(fullHeaderSize.width >= bareHeaderSize.width + resetSize.width * 0.75,
                  "HDRRenditionControls header layout embeds reset button width (full=\(fullHeaderSize.width), bare=\(bareHeaderSize.width), reset=\(resetSize.width))")

        // 3. 四项中任意单项改动后，重置按钮切换为启用态
        for (name, mutate) in [
            ("peakLimitEV", { (s: inout HDRRenditionSettings) in s.peakLimitEV = 1.5 }),
            ("sdrExposureEV", { (s: inout HDRRenditionSettings) in s.sdrExposureEV = -0.8 }),
            ("sdrContrast", { (s: inout HDRRenditionSettings) in s.sdrContrast = 12 }),
            ("sdrSaturation", { (s: inout HDRRenditionSettings) in s.sdrSaturation = -18 }),
        ] {
            var edited = HDRRenditionSettings()
            mutate(&edited)
            model.settings = edited
            let active = try requirePresentation(
                model.controls.resetPresentation,
                "Missing reset presentation after editing \(name)"
            )
            try check(active.identifier == "hdr.rendition.reset" && active.isEnabled,
                      "Reset control enables when \(name) is modified")
        }

        // 4. 四项同时改动后触发重置：一次写回共享绑定并回到禁用态
        var combined = HDRRenditionSettings()
        combined.peakLimitEV = 2.4
        combined.sdrExposureEV = -1.2
        combined.sdrContrast = 35
        combined.sdrSaturation = -25
        model.settings = combined
        model.writes = 0
        let combinedPresentation = try requirePresentation(
            model.controls.resetPresentation,
            "Missing reset presentation when all four fields are modified"
        )
        try check(combinedPresentation.isEnabled,
                  "Reset control is enabled when all four rendition fields are modified")

        model.controls.reset()
        try check(model.settings == HDRRenditionSettings() && model.settings.isDefault,
                  "Reset action restores all four HDR rendition fields to default")
        try check(model.writes == 1,
                  "Reset action writes once through shared binding for a single undo entry")
        let afterReset = try requirePresentation(
            model.controls.resetPresentation,
            "Missing reset presentation after resetting to default"
        )
        try check(!afterReset.isEnabled,
                  "Reset control returns to disabled state after reset")
    }
}
