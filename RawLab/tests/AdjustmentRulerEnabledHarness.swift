import SwiftUI
import UIKit

// MARK: - Host the production ruler under the editor's disabled contract

private final class RulerState: ObservableObject {
    @Published var locked = false
    @Published var value = 10.0
    @Published var editing = false
    @Published var editingAtLock = false
    @Published var lockedWrites = -1
    @Published var lockedValue = -1.0
    var writes = 0

    var binding: Binding<Double> {
        Binding(get: { self.value }, set: { self.writes += 1; self.value = $0 })
    }

    func lock() {
        editingAtLock = editing
        locked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.lockedWrites = self.writes
            self.lockedValue = self.value
        }
    }
}

private struct RulerHost: View {
    @ObservedObject var state: RulerState

    var body: some View {
        VStack {
            VStack {
                AdjustmentRuler(value: state.binding, scale: AdjustmentScale(range: 0...20, step: 1),
                                defaultValue: 0, title: "Exposure", formatter: { String($0) },
                                identifier: "ruler.enabled.regression", fine: false, haptics: false,
                                reduceMotion: true, onEditingChanged: { state.editing = $0 })
                    .frame(width: 300, height: 80)
            }
            .disabled(state.locked)
            Text(String(state.value)).accessibilityIdentifier("ruler.value")
            Text(String(state.writes)).accessibilityIdentifier("ruler.writes")
            Text(String(state.locked)).accessibilityIdentifier("ruler.locked")
            Text(String(state.editing)).accessibilityIdentifier("ruler.editing")
            Text(String(state.editingAtLock)).accessibilityIdentifier("ruler.editingAtLock")
            Text(String(state.lockedWrites)).accessibilityIdentifier("ruler.lockedWrites")
            Text(String(state.lockedValue)).accessibilityIdentifier("ruler.lockedValue")
            Button("Lock") { state.lock() }.accessibilityIdentifier("ruler.lock")
            Button("Unlock") { state.locked = false }.accessibilityIdentifier("ruler.unlock")
            Button("Lock after one second") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { state.lock() }
            }.accessibilityIdentifier("ruler.lockSoon")
        }
    }
}

// MARK: - Method-level observations, separate from real XCTest event delivery

private final class RulerProbe {
    private func ruler(in view: UIView) -> AdjustmentRulerView? {
        if let ruler = view as? AdjustmentRulerView { return ruler }
        return view.subviews.lazy.compactMap { self.ruler(in: $0) }.first
    }

    @MainActor
    func run(state: RulerState, window: UIWindow) async {
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard let ruler = ruler(in: window), let commands = ruler.keyCommands,
              let right = commands.first(where: { $0.input == UIKeyCommand.inputRightArrow }),
              let left = commands.first(where: { $0.input == UIKeyCommand.inputLeftArrow }),
              let rightAction = right.action, let leftAction = left.action else { exit(2) }
        var observations: [String: Any] = [:]
        observations["enabledFocusAcquired"] = ruler.becomeFirstResponder() && ruler.isFirstResponder
        observations["enabledRightSendAction"] = UIApplication.shared.sendAction(rightAction, to: nil, from: right, for: nil)
        observations["enabledRightValue"] = state.value
        _ = UIApplication.shared.sendAction(leftAction, to: nil, from: left, for: nil)
        state.lock()
        try? await Task.sleep(nanoseconds: 180_000_000)
        observations["sameHostedRulerAfterDisable"] = self.ruler(in: window) === ruler
        observations["disabledFirstResponder"] = ruler.isFirstResponder
        observations["disabledUserInteractionEnabled"] = ruler.isUserInteractionEnabled
        observations["disabledCanBecomeFirstResponder"] = ruler.canBecomeFirstResponder
        let writes = state.writes
        observations["disabledRightSendAction"] = UIApplication.shared.sendAction(rightAction, to: nil, from: right, for: nil)
        observations["disabledRightWritesDelta"] = state.writes - writes
        observations["disabledLeftSendAction"] = UIApplication.shared.sendAction(leftAction, to: nil, from: left, for: nil)
        observations["disabledKeysWritesDelta"] = state.writes - writes
        ruler.accessibilityIncrement()
        observations["directDisabledAXIncrementValue"] = state.value
        observations["directDisabledAXIncrementWritesDelta"] = state.writes - writes
        ruler.accessibilityDecrement()
        observations["directDisabledAXDecrementValue"] = state.value
        observations["directDisabledAXCallbacksWritesDelta"] = state.writes - writes
        observations["system"] = UIDevice.current.systemVersion
        let data = try! JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["RAWLAB_RULER_RESULT"] {
            try! data.write(to: URL(fileURLWithPath: path))
        }
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
        exit(0)
    }
}

// MARK: - Standalone UIKit lifecycle, separate from the product app

final class RulerEnabledAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Ruler Enabled Tests", sessionRole: session.role)
        configuration.delegateClass = RulerEnabledSceneDelegate.self
        return configuration
    }
}

final class RulerEnabledSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let state = RulerState()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RulerHost(state: state))
        window.makeKeyAndVisible()
        self.window = window
        guard ProcessInfo.processInfo.environment["RAWLAB_RULER_UI_MODE"] != "1" else { return }
        Task { await RulerProbe().run(state: state, window: window) }
    }
}

@main
enum AdjustmentRulerEnabledHarness {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                          NSStringFromClass(RulerEnabledAppDelegate.self))
    }
}
