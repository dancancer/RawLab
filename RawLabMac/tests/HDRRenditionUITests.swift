import AppKit
import SwiftUI
import ApplicationServices

enum HDRLookAssetStore {
    static func installHDRSilver() throws -> HDRLookSettings { fatalError("unused in rendition UI test") }
    static func install(_ url: URL) throws -> HDRLookSettings { fatalError("unused in rendition UI test") }
}

enum HDRCameraProfileAssetStore {
    static func url(for profile: HDRCameraProfile) throws -> URL { fatalError("unused in rendition UI test") }
    static func install(_ url: URL) throws -> HDRCameraProfile { fatalError("unused in rendition UI test") }
}

@MainActor private final class RenditionTestModel: ObservableObject {
    @Published var settings = HDRRenditionSettings()
    var writes = 0

    var binding: Binding<HDRRenditionSettings> {
        Binding(get: { self.settings }, set: { self.writes += 1; self.settings = $0 })
    }
}

private struct RenditionHostView: View {
    @ObservedObject var model: RenditionTestModel
    var body: some View {
        HDRRenditionControls(settings: model.binding, onEditingChanged: { _ in }, onCancelled: {})
            .padding(20)
            .frame(width: 360)
    }
}

@main struct HDRRenditionUITests {
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

    enum Failure: Error { case assertion(String) }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
        print("PASS: \(message)")
    }

    @MainActor static func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    @MainActor static func findElement(_ element: AXUIElement, role: String? = nil, identifier: String? = nil, depth: Int = 0) -> AXUIElement? {
        guard depth < 32 else { return nil }
        let matchesRole = role == nil || axAttribute(element, kAXRoleAttribute as CFString) as? String == role
        let matchesID = identifier == nil || axAttribute(element, kAXIdentifierAttribute as CFString) as? String == identifier
        if matchesRole && matchesID { return element }
        for child in axAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            if let found = findElement(child, role: role, identifier: identifier, depth: depth + 1) { return found }
        }
        return nil
    }

    @MainActor static func perform(_ element: AXUIElement, _ action: CFString) throws {
        guard AXUIElementPerformAction(element, action) == .success else {
            throw Failure.assertion("Accessibility action \(action) failed")
        }
    }

    @MainActor static func run() async throws {
        // 无辅助功能授权的进程（无头 CLI、未批准的终端）里 AXUIElementCopyAttributeValue
        // 返回 kAXErrorAPIDisabled，读不到任何控件。这里明确跳过而不是报缺陷；
        // CI 的自托管家 runner 有授权，AX 断言照常执行。
        guard AXIsProcessTrusted() else {
            // CI 必须真的执行这些断言：设置了 RAWLAB_REQUIRE_AX 却未授权时判失败，而不是静默跳过。
            if !(ProcessInfo.processInfo.environment["RAWLAB_REQUIRE_AX"] ?? "").isEmpty {
                throw Failure.assertion("RAWLAB_REQUIRE_AX is set but accessibility is not granted; the AX checks cannot run")
            }
            print("SKIP: accessibility is not trusted here; run from an approved terminal to exercise the AX checks")
            return
        }
        let model = RenditionTestModel()
        let host = NSHostingView(rootView: RenditionHostView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))

        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let resetButton = findElement(appElement, role: kAXButtonRole as String, identifier: "hdr.rendition.reset") else {
            throw Failure.assertion("Missing hdr.rendition.reset button")
        }
        let resetLabel = (axAttribute(resetButton, kAXDescriptionAttribute as CFString) as? String)
            ?? (axAttribute(resetButton, kAXTitleAttribute as CFString) as? String)
        try check(resetLabel == L10n.text("重置"), "Reset button reuses existing localized title")
        try check((axAttribute(resetButton, kAXEnabledAttribute as CFString) as? Bool) == false,
                  "Reset button is disabled when rendition settings are default")

        for mutate in [
            { (s: inout HDRRenditionSettings) in s.peakLimitEV = 1.5 },
            { (s: inout HDRRenditionSettings) in s.sdrExposureEV = -0.8 },
            { (s: inout HDRRenditionSettings) in s.sdrContrast = 12 },
            { (s: inout HDRRenditionSettings) in s.sdrSaturation = -18 },
        ] {
            var edited = HDRRenditionSettings()
            mutate(&edited)
            model.settings = edited
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            guard let button = findElement(appElement, role: kAXButtonRole as String, identifier: "hdr.rendition.reset") else {
                throw Failure.assertion("Missing hdr.rendition.reset button after edit")
            }
            try check((axAttribute(button, kAXEnabledAttribute as CFString) as? Bool) == true,
                      "Reset button enables when an individual rendition field is modified")
        }

        if let disclosure = findElement(appElement, role: "AXDisclosureTriangle") {
            try perform(disclosure, kAXPressAction as CFString)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        try check(findElement(appElement, role: kAXSliderRole as String, identifier: "hdr.rendition.peakLimit") != nil,
                  "Disclosure group expands and exposes rendition sliders")

        var combined = HDRRenditionSettings()
        combined.peakLimitEV = 2.4
        combined.sdrExposureEV = -1.2
        combined.sdrContrast = 35
        combined.sdrSaturation = -25
        model.settings = combined
        model.writes = 0
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        guard let activeReset = findElement(appElement, role: kAXButtonRole as String, identifier: "hdr.rendition.reset") else {
            throw Failure.assertion("Missing active hdr.rendition.reset button")
        }
        try check((axAttribute(activeReset, kAXEnabledAttribute as CFString) as? Bool) == true,
                  "Reset button is enabled when all four rendition fields are non-default")
        try perform(activeReset, kAXPressAction as CFString)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))

        try check(model.settings == HDRRenditionSettings() && model.settings.isDefault,
                  "Reset button restores all four rendition fields to default")
        try check(model.writes == 1,
                  "Reset button writes once through shared binding for a single undo entry")
        guard let disabledReset = findElement(appElement, role: kAXButtonRole as String, identifier: "hdr.rendition.reset") else {
            throw Failure.assertion("Missing hdr.rendition.reset button after reset")
        }
        try check((axAttribute(disabledReset, kAXEnabledAttribute as CFString) as? Bool) == false,
                  "Reset button returns to disabled after resetting to default")
        for sliderID in ["peakLimit", "sdrExposure", "sdrContrast", "sdrSaturation"] {
            try check(findElement(appElement, role: kAXSliderRole as String, identifier: "hdr.rendition.\(sliderID)") != nil,
                      "Borderless header reset preserves expanded slider hdr.rendition.\(sliderID)")
        }
    }
}
