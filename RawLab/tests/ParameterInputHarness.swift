import SwiftUI
import UIKit

private final class ParameterInputState: ObservableObject {
    @Published var settings: HSLSettings = {
        let object: [String: Any] = ["hue": [0.5] + Array(repeating: 0.0, count: 7),
                                    "saturation": Array(repeating: 0.0, count: 8), "lightness": Array(repeating: 0.0, count: 8)]
        return try! JSONDecoder().decode(HSLSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }()
    @Published var channel = 0
    @Published var writes = 0
    @Published var exposure = -4.0
    @Published var strength = 0.29
    @Published var fine = false
    @Published var source = UUID()
    @Published var sourceChanged = false
}

private struct ParameterInputHost: View {
    @StateObject private var state = ParameterInputState()

    var body: some View {
        #if PARAMETER_INPUT_CONTEXT
        content
            .environment(\.adjustmentFine, state.fine)
            .environment(\.adjustmentInputContext, context)
        #else
        content
        #endif
    }

    #if PARAMETER_INPUT_CONTEXT
    private var context: AdjustmentInputContext {
        let source = state.source, channel = state.channel
        return AdjustmentInputContext(id: "\(source).\(channel)", isCurrent: {
            state.source == source && state.channel == channel
        })
    }
    #endif

    private var mixer: some View {
        let binding = Binding(get: { state.settings }, set: { state.settings = $0; state.writes += 1 })
        #if PARAMETER_INPUT_CONTEXT
        return IOSHSLMixer(settings: binding, onEditingChanged: { _ in }, channel: $state.channel)
        #else
        return IOSHSLMixer(settings: binding, onEditingChanged: { _ in }, channel: $state.channel,
                           onResetChannel: { state.settings.reset(channel: state.channel) }, onResetAll: { state.settings.reset() })
        #endif
    }

    private var content: some View {
        VStack(spacing: 4) {
            HStack {
                Text(String(state.writes)).accessibilityIdentifier("fixture.writes")
                Text(String(state.settings.value(.hue, channel: 0))).accessibilityIdentifier("fixture.originalHue")
                Text(String(state.sourceChanged)).accessibilityIdentifier("fixture.sourceChanged")
                Toggle("Fine", isOn: $state.fine).fixedSize().accessibilityIdentifier("fixture.fine")
            }
            Button("Change source with same values after ten seconds") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { state.source = UUID(); state.sourceChanged = true }
            }.accessibilityIdentifier("fixture.changeSourceSoon")
            ScrollView {
                if ProcessInfo.processInfo.arguments.contains("-Endpoint") {
                    AdjustmentRuler(value: $state.exposure, scale: AdjustmentScale(range: -4...4, step: 0.05),
                                    defaultValue: 0, title: "Exposure", formatter: { String($0) }, identifier: "fixture.endpoint",
                                    fine: false, haptics: false, reduceMotion: true, onEditingChanged: { _ in })
                        .frame(height: 76).padding(.horizontal, 16)
                } else {
                    ScrollView {
                        mixer
                    }
                    .frame(height: 192).accessibilityIdentifier("fixture.parameters")
                    AdjustmentControl(title: "Exposure", value: $state.exposure, range: -4...4, step: 0.05,
                                      defaultValue: 0, unit: "EV", formatter: { String(format: "%+.2f", $0) }, identifier: "fixture.exposure")
                    #if PARAMETER_INPUT_CONTEXT
                    AdjustmentControl(title: "Strength", value: Binding(get: { state.strength }, set: { state.strength = $0; state.writes += 1 }),
                                      range: 0...2, step: 0.01, defaultValue: 1, unit: "%",
                                      formatter: { String(format: "%.0f", $0 * 100) }, displayScale: 100, identifier: "fixture.strength")
                    #endif
                }
            }
        }
    }
}

final class ParameterInputAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Parameter Input Tests", sessionRole: session.role)
        configuration.delegateClass = ParameterInputSceneDelegate.self
        return configuration
    }
}
final class ParameterInputSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ParameterInputHost())
        window.makeKeyAndVisible()
        self.window = window
    }
}
@main enum ParameterInputHarness {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ParameterInputAppDelegate.self))
    }
}
