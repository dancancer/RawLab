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
    var editingLog: [Bool] = []

    var binding: Binding<HDRRenditionSettings> {
        Binding(get: { self.settings }, set: { self.writes += 1; self.settings = $0 })
    }

    var controls: HDRRenditionControls {
        HDRRenditionControls(settings: binding, onEditingChanged: { self.editingLog.append($0) }, onCancelled: {},
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

    @MainActor static func collectSliderTrackViews(in view: NSView) -> [NSView] {
        var nativeSliders: [NSView] = []
        var focusRings: [NSView] = []
        func visit(_ current: NSView) {
            if current is NSSlider {
                nativeSliders.append(current)
            } else if String(describing: type(of: current)).contains("FocusRingView") && current.bounds.width > 100 {
                focusRings.append(current)
            }
            for subview in current.subviews { visit(subview) }
        }
        visit(view)
        let tracks = nativeSliders.isEmpty ? focusRings : nativeSliders
        return tracks.sorted {
            $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
        }
    }

    @MainActor static func sendMouse(type: NSEvent.EventType, location: NSPoint, clickCount: Int,
                                     eventNumber: Int, timestamp: TimeInterval, to window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
            clickCount: clickCount, pressure: type == .leftMouseUp ? 0.0 : 1.0
        )!
        window.sendEvent(event)
    }

    @MainActor static func sendDoubleClick(at point: NSPoint, in window: NSWindow) async throws {
        let base = ProcessInfo.processInfo.systemUptime
        sendMouse(type: .leftMouseDown, location: point, clickCount: 1, eventNumber: 1, timestamp: base, to: window)
        sendMouse(type: .leftMouseUp, location: point, clickCount: 1, eventNumber: 2, timestamp: base + 0.01, to: window)
        try await Task.sleep(for: .milliseconds(30))
        sendMouse(type: .leftMouseDown, location: point, clickCount: 2, eventNumber: 3, timestamp: base + 0.04, to: window)
        sendMouse(type: .leftMouseUp, location: point, clickCount: 2, eventNumber: 4, timestamp: base + 0.05, to: window)
        try await Task.sleep(for: .milliseconds(50))
    }

    @MainActor static func sendDrag(from start: NSPoint, to end: NSPoint, in window: NSWindow) async throws {
        let base = ProcessInfo.processInfo.systemUptime
        sendMouse(type: .leftMouseDown, location: start, clickCount: 1, eventNumber: 10, timestamp: base, to: window)
        let mid = NSPoint(x: (start.x + end.x) / 2, y: start.y)
        sendMouse(type: .leftMouseDragged, location: mid, clickCount: 1, eventNumber: 11, timestamp: base + 0.02, to: window)
        sendMouse(type: .leftMouseDragged, location: end, clickCount: 1, eventNumber: 12, timestamp: base + 0.04, to: window)
        sendMouse(type: .leftMouseUp, location: end, clickCount: 1, eventNumber: 13, timestamp: base + 0.05, to: window)
        try await Task.sleep(for: .milliseconds(30))
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
        let trackViews = collectSliderTrackViews(in: expandedHost)
        try check(trackViews.count == 4,
                  "Expanded HDRRenditionControls materializes four slider track controls (tracks=\(trackViews.count))")
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
            print("NOTE: SwiftUI accessibility slider nodes unavailable under prohibited activation policy; verified via track views + real pointer events")
        }

        // 7. 行为回归：真实鼠标双击滑杆轨道恢复默认且吞掉单击坐标跳变；拖拽与 VoiceOver 门禁保持完整
        expandedModel.voiceOverOverride = false
        expandedModel.settings = combined
        expandedModel.writes = 0
        expandedModel.editingLog = []
        try await settle(expandedHost)
        let peakRect = trackViews[0].convert(trackViews[0].bounds, to: nil)
        let peakTrackPoint = NSPoint(x: peakRect.minX + peakRect.width * 0.75, y: peakRect.midY)
        try await sendDoubleClick(at: peakTrackPoint, in: expandedWindow)
        var afterPeakTrackReset = combined
        afterPeakTrackReset.peakLimitEV = 0
        try check(expandedModel.settings == afterPeakTrackReset,
                  "Double-clicking peakLimit slider track resets to 0 instead of jumping to clicked coordinate (actual=\(expandedModel.settings.peakLimitEV))")
        try check(expandedModel.writes == 1,
                  "Double-clicking peakLimit slider track swallows click-1 coordinate jump (writes=\(expandedModel.writes))")

        let settleMs = Int((NSEvent.doubleClickInterval * 1000).rounded(.up)) + 60
        try await Task.sleep(for: .milliseconds(settleMs))
        try check(expandedModel.settings == afterPeakTrackReset && expandedModel.writes == 1,
                  "Delayed single-click timer stays cancelled after track double-click reset")

        let exposureRect = trackViews[1].convert(trackViews[1].bounds, to: nil)
        let exposureTrackPoint = NSPoint(x: exposureRect.minX + exposureRect.width * 0.75, y: exposureRect.midY)
        expandedModel.settings = combined
        expandedModel.writes = 0
        expandedModel.editingLog = []
        try await sendDoubleClick(at: exposureTrackPoint, in: expandedWindow)
        var afterExposureTrackReset = combined
        afterExposureTrackReset.sdrExposureEV = 0
        try check(expandedModel.settings == afterExposureTrackReset && expandedModel.writes == 1,
                  "Double-clicking sdrExposure slider track resets only sdrExposureEV cleanly")

        expandedModel.settings = combined
        expandedModel.writes = 0
        expandedModel.editingLog = []
        try await sendDrag(
            from: NSPoint(x: peakRect.minX + peakRect.width * 0.15, y: peakRect.midY),
            to: NSPoint(x: peakRect.minX + peakRect.width * 0.65, y: peakRect.midY),
            in: expandedWindow
        )
        try check(expandedModel.settings.peakLimitEV > 3.0 && expandedModel.editingLog == [true, false],
                  "Dragging peakLimit slider track updates value smoothly and brackets editing state")

        expandedModel.voiceOverOverride = true
        expandedModel.settings = combined
        expandedModel.writes = 0
        try await settle(expandedHost)
        try await sendDoubleClick(at: peakTrackPoint, in: expandedWindow)
        try check(expandedModel.settings.peakLimitEV != 0,
                  "VoiceOver enabled disables double-click track reset")

        // Intentional single-click on track commits cleanly once doubleClickInterval elapses
        expandedModel.voiceOverOverride = false
        expandedModel.settings = HDRRenditionSettings()
        expandedModel.writes = 0
        expandedModel.editingLog = []
        try await settle(expandedHost)
        let singleBase = ProcessInfo.processInfo.systemUptime
        sendMouse(type: .leftMouseDown, location: peakTrackPoint, clickCount: 1, eventNumber: 20, timestamp: singleBase, to: expandedWindow)
        sendMouse(type: .leftMouseUp, location: peakTrackPoint, clickCount: 1, eventNumber: 21, timestamp: singleBase + 0.01, to: expandedWindow)
        try await Task.sleep(for: .milliseconds(settleMs))
        try check(expandedModel.settings.peakLimitEV > 3.5 && expandedModel.writes == 1 && expandedModel.editingLog == [true, false],
                  "Single-clicking peakLimit slider track seeks to clicked coordinate after doubleClickInterval")
    }
}
