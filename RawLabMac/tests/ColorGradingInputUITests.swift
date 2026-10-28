import AppKit
import SwiftUI
import ApplicationServices

@MainActor private final class GradingInputModel: ObservableObject {
    @Published var wheel = ColorGradingWheel(hue: 30, saturation: 20)
    var begins = 0
    var ends = 0
}

private struct GradingInputView: View {
    @ObservedObject var model: GradingInputModel
    var body: some View {
        VStack {
            ParameterValueField(value: Binding(get: { model.wheel.saturation }, set: { model.wheel.saturation = $0 }),
                range: 0...100, precision: .standard, title: "Saturation", unit: "%", identifier: "grading.value.saturation")
                .frame(width: 120, height: 30)
            ColorGradingWheelControl(value: $model.wheel, scope: "photo.shadows", title: "Shadows",
                prepareEditing: ParameterValueField.commitPendingInputs,
                onEditingChanged: { if $0 { model.begins += 1 } else { model.ends += 1 } })
                .frame(width: 156, height: 156)
        }.padding(20)
    }
}

@main struct ColorGradingInputUITests {
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
    @MainActor static func numericFields(_ view: NSView) -> [NumericTextField] {
        (view as? NumericTextField).map { [$0] } ?? view.subviews.flatMap(numericFields)
    }
    @MainActor static func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }
    @MainActor static func findWheel(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 32 else { return nil }
        if axAttribute(element, kAXIdentifierAttribute as CFString) as? String == "grading.wheel" { return element }
        for child in axAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
            if let wheel = findWheel(child, depth: depth + 1) { return wheel }
        }
        return nil
    }
    @MainActor static func perform(_ wheel: AXUIElement, _ action: CFString) throws {
        guard AXUIElementPerformAction(wheel, action) == .success else { throw Failure.assertion("Native accessibility action failed") }
    }
    @MainActor static func run() async throws {
        let model = GradingInputModel()
        let host = NSHostingView(rootView: GradingInputView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { ParameterValueField.cancelPendingInputs(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        guard let field = numericFields(host).first,
              let coordinator = field.delegate as? ParameterValueField.Coordinator else {
            throw Failure.assertion("Native saturation field missing")
        }
        guard let wheel = findWheel(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)) else {
            throw Failure.assertion("Native accessibility wheel missing")
        }
        func enter(_ text: String) {
            window.makeFirstResponder(field)
            field.stringValue = text; field.currentEditor()?.string = text
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        enter("-")
        try perform(wheel, kAXIncrementAction as CFString)
        try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        try check(model.wheel.saturation == 20 && coordinator.dirty && field.stringValue == "-" && model.begins == 0,
            "Accessibility increment rejects invalid input and preserves its text without starting a wheel edit")
        coordinator.cancel()
        enter("42.5")
        try perform(wheel, kAXIncrementAction as CFString)
        try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        try check(model.wheel.saturation == 43.5 && !coordinator.dirty && model.begins == 1 && model.ends == 1,
            "Accessibility increment commits valid pending input before applying one step in one wheel transaction")
        try perform(wheel, kAXDecrementAction as CFString)
        try await Task.sleep(for: .milliseconds(80))
        try check(model.wheel.saturation == 42.5 && model.begins == 2 && model.ends == 2,
            "Accessibility decrement uses the same guarded input path")
    }
}
