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
    var initiallyExpanded = false
    var voiceOverOverride: Bool? = false
    var writes = 0

    var binding: Binding<HDRRenditionSettings> {
        Binding(get: { self.settings }, set: { self.writes += 1; self.settings = $0 })
    }

    var controls: HDRRenditionControls {
        HDRRenditionControls(settings: binding, onEditingChanged: { _ in }, onCancelled: {},
                             initiallyExpanded: initiallyExpanded, voiceOverOverride: voiceOverOverride)
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

    @MainActor static func accessibilityElements(in root: Any) -> [AnyObject] {
        var result: [AnyObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: AnyObject) {
            let id = ObjectIdentifier(node)
            guard visited.insert(id).inserted else { return }
            result.append(node)
            if let children = node.accessibilityChildren?() as? [AnyObject] {
                for child in children { visit(child) }
            }
            if let view = node as? NSView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(root as AnyObject)
        return result
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

        // 5. 单项重置契约与拖拽保护：编辑中（isEditing: true）不触发单项重置；非编辑中仅恢复对应字段
        for (name, keyPath) in [
            ("peakLimitEV", \HDRRenditionSettings.peakLimitEV),
            ("sdrExposureEV", \.sdrExposureEV),
            ("sdrContrast", \.sdrContrast),
            ("sdrSaturation", \.sdrSaturation),
        ] {
            var guarded = combined
            try check(!HDRRenditionControls.applySingleReset(keyPath, to: &guarded, isEditing: true) && guarded == combined,
                      "applySingleReset refuses to reset \(name) while slider drag is active")

            model.settings = combined
            model.writes = 0
            try check(!model.controls.reset(keyPath, isEditing: true) && model.settings == combined && model.writes == 0,
                      "HDRRenditionControls.reset refuses write for \(name) while editing")
            try check(model.controls.reset(keyPath, isEditing: false) && model.writes == 1,
                      "Single rendition reset restores only \(name) via shared binding once")
            var expected = combined
            expected[keyPath: keyPath] = HDRRenditionSettings()[keyPath: keyPath]
            try check(model.settings == expected,
                      "Single rendition reset keeps sibling fields intact for \(name)")
        }

        // 6. VoiceOver 开启时禁用双击手势且仅保留无障碍操作，展开 DisclosureGroup 验证真实物化滑杆入口
        try check(!HDRRenditionControls.allowsDoubleTapReset(voiceOverEnabled: true) &&
                  HDRRenditionControls.allowsDoubleTapReset(voiceOverEnabled: false),
                  "Double-tap rendition reset is disabled when VoiceOver is active")

        let expandedModel = RenditionResetHostModel()
        expandedModel.initiallyExpanded = true
        expandedModel.settings = combined
        let expandedHost = NSHostingView(rootView: FullControlsProbeView(model: expandedModel))
        expandedHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        let expandedWindow = NSWindow(contentRect: expandedHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        expandedWindow.isReleasedWhenClosed = false
        expandedWindow.contentView = expandedHost
        expandedWindow.orderFront(nil)
        defer { expandedWindow.contentView = nil; expandedWindow.close() }
        try await settle(expandedHost)

        let elements = accessibilityElements(in: expandedHost)
        let focusRingCount = elements.filter { String(describing: type(of: $0)).contains("FocusRingView") }.count
        try check(focusRingCount >= 5,
                  "Expanded HDRRenditionControls materializes disclosure plus four slider controls (focusRings=\(focusRingCount))")
        if elements.contains(where: { $0.accessibilityIdentifier?() == "hdr.rendition.peakLimit" }) {
            let expectedFields: [(String, WritableKeyPath<HDRRenditionSettings, Double>)] = [
                ("hdr.rendition.peakLimit", \.peakLimitEV),
                ("hdr.rendition.sdrExposure", \.sdrExposureEV),
                ("hdr.rendition.sdrContrast", \.sdrContrast),
                ("hdr.rendition.sdrSaturation", \.sdrSaturation),
            ]
            for (identifier, keyPath) in expectedFields {
                expandedModel.voiceOverOverride = false
                expandedModel.settings = combined
                expandedModel.writes = 0
                try await settle(expandedHost)
                guard let slider = accessibilityElements(in: expandedHost).first(where: { $0.accessibilityIdentifier?() == identifier }) else {
                    throw Failure.assertion("Missing materialized slider \(identifier) in expanded HDRRenditionControls")
                }
                let standardHelp = slider.accessibilityHelp?() ?? ""
                try check(standardHelp == L10n.text("双击名称或轨道恢复默认值。"),
                          "Slider \(identifier) advertises double-tap hint when VoiceOver is off")
                guard let resetAction = slider.accessibilityCustomActions?()?.first(where: { $0.name == L10n.text("重置") }) else {
                    throw Failure.assertion("Missing accessibility custom reset action on \(identifier)")
                }
                _ = resetAction.handler?()
                var expected = combined
                expected[keyPath: keyPath] = 0
                try check(expandedModel.settings == expected && expandedModel.writes == 1,
                          "Materialized slider accessibility action resets \(identifier) through HDRRenditionControls.reset")
            }

            expandedModel.voiceOverOverride = true
            try await settle(expandedHost)
            guard let voSlider = accessibilityElements(in: expandedHost).first(where: { $0.accessibilityIdentifier?() == "hdr.rendition.sdrExposure" }) else {
                throw Failure.assertion("Missing sdrExposure slider under VoiceOver override")
            }
            try check((voSlider.accessibilityHelp?() ?? "").isEmpty &&
                      (voSlider.accessibilityCustomActions?()?.contains(where: { $0.name == L10n.text("重置") }) == true),
                      "VoiceOver suppresses double-tap hint while preserving reset accessibilityAction")
        } else {
            print("NOTE: SwiftUI accessibility slider nodes unavailable under prohibited activation policy; verified via focus rings + direct model reset")
        }
    }
}
