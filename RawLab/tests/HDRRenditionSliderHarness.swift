import SwiftUI
import UIKit

enum ProRAWSource {
    static let maxSupportedDecodeVersion = 2
    static func validatedDecodeVersion(_ version: Int?) throws -> Int { version ?? 2 }
}

enum HDRLookAssetStore {
    static func install(_ url: URL) throws -> HDRLookSettings { HDRLookSettings() }
    static func installHDRSilver() throws -> HDRLookSettings { HDRLookSettings() }
}

enum HDRCameraProfileAssetStore {
    static func install(_ url: URL) throws -> HDRCameraProfile { throw CocoaError(.fileNoSuchFile) }
    static func url(for profile: HDRCameraProfile) throws -> URL { throw CocoaError(.fileNoSuchFile) }
}

private func makeProbeSettings(peak: Double) -> HDRRenditionSettings {
    var value = HDRRenditionSettings()
    value.peakLimitEV = peak
    value.sdrExposureEV = 0.7
    value.sdrContrast = 0.3
    value.sdrSaturation = 0.2
    return value
}

private func sliders(in view: UIView) -> [UISlider] {
    var result: [UISlider] = []
    if let slider = view as? UISlider { result.append(slider) }
    for subview in view.subviews {
        result.append(contentsOf: sliders(in: subview))
    }
    return result
}

@MainActor
private final class SliderHarnessState: ObservableObject {
    weak var window: UIWindow?
    @Published var settings = makeProbeSettings(peak: 2.5)
    @Published var writes = 0
    @Published var editingLog: [Int] = []
    @Published var cancelledCount = 0
    @Published var voiceOverOverride = false
    @Published var controlsDisabled = false
    @Published var controlsVisible = true

    func configureFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        let initial = env["PROBE_INITIAL_PEAK"].flatMap(Double.init) ?? 2.5
        settings = makeProbeSettings(peak: initial)
        voiceOverOverride = env["PROBE_VO"] == "1"
        controlsDisabled = env["PROBE_DISABLED"] == "1"
        controlsVisible = true
        writes = 0
        editingLog = []
        cancelledCount = 0
    }
}

private struct SliderHarnessRoot: View {
    @ObservedObject var state: SliderHarnessState

    var statusText: String {
        let ed = state.editingLog.map(String.init).joined(separator: ",")
        return String(
            format: "peak=%.1f writes=%d editing=%@ cancelled=%d",
            state.settings.peakLimitEV,
            state.writes,
            ed,
            state.cancelledCount
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("HDR Rendition Slider Harness") {
                    if state.controlsVisible {
                        HDRRenditionControls(
                            settings: Binding(
                                get: { state.settings },
                                set: { state.writes += 1; state.settings = $0 }
                            ),
                            onEditingChanged: { state.editingLog.append($0 ? 1 : 0) },
                            onCancelled: { state.cancelledCount += 1 },
                            initiallyExpanded: true,
                            voiceOverOverride: state.voiceOverOverride
                        )
                        .disabled(state.controlsDisabled)
                    }
                    Text(statusText).accessibilityIdentifier("probe.status")
                    Button("SendValueChanged") {
                        guard let window = state.window,
                              let slider = sliders(in: window).first(where: { $0.accessibilityIdentifier == "hdr.rendition.peakLimit" }) else { return }
                        slider.setValue(3.4, animated: false)
                        slider.sendActions(for: .valueChanged)
                    }
                    .accessibilityIdentifier("probe.valueChanged")
                }
            }
        }
    }
}

private final class SliderMethodProbe {
    private var failures: [String] = []
    private var passes: [String] = []

    private func check(_ condition: Bool, _ message: String) {
        if condition {
            passes.append(message)
            print("PASS: \(message)")
        } else {
            failures.append(message)
            print("FAIL: \(message)")
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor
    func run(state: SliderHarnessState, window: UIWindow) async {
        await settle()
        guard let peakSlider = sliders(in: window).first(where: { $0.accessibilityIdentifier == "hdr.rendition.peakLimit" }) else {
            finish(exitCode: 2, note: "Missing hdr.rendition.peakLimit UISlider")
            return
        }

        // 1. VoiceOver 开启时 .adjustable（accessibilityIncrement）必须成对闭合 editingLog，保留重置无障碍动作有效且关闭面板不回滚
        state.voiceOverOverride = true
        state.controlsDisabled = false
        state.controlsVisible = true
        state.settings = makeProbeSettings(peak: 2.4)
        state.writes = 0
        state.editingLog = []
        state.cancelledCount = 0
        await settle()

        peakSlider.accessibilityIncrement()
        await settle()
        let afterIncPeak = state.settings.peakLimitEV
        check(afterIncPeak > 2.4 && state.editingLog == [1, 0],
              "VoiceOver accessibilityIncrement updates value and closes editing state (peak=\(afterIncPeak), editing=\(state.editingLog))")

        state.editingLog = []
        peakSlider.accessibilityDecrement()
        await settle()
        check(abs(state.settings.peakLimitEV - 2.4) < 0.001 && state.editingLog == [1, 0],
              "VoiceOver accessibilityDecrement restores previous step and closes editing state (peak=\(state.settings.peakLimitEV), editing=\(state.editingLog))")

        let resetAction = peakSlider.accessibilityCustomActions?.first(where: { $0.name == L10n.text("重置") })
        let resetHandled = resetAction?.actionHandler?(resetAction!) ?? false
        await settle()
        check(resetHandled && state.settings.peakLimitEV == 0 && abs(Double(peakSlider.value) - 0) < 0.001,
              "Reset accessibilityCustomAction succeeds after VoiceOver increment and syncs UISlider value (handled=\(resetHandled), model=\(state.settings.peakLimitEV), slider=\(peakSlider.value))")

        state.editingLog = []
        state.cancelledCount = 0
        state.settings = makeProbeSettings(peak: 2.4)
        await settle()
        peakSlider.accessibilityIncrement()
        await settle()
        let preservedAfterInc = state.settings.peakLimitEV
        state.controlsVisible = false
        await settle()
        check(state.cancelledCount == 0 && abs(state.settings.peakLimitEV - preservedAfterInc) < 0.001,
              "Closing HDRRenditionControls after VoiceOver adjustment does not trigger onCancelled rollback (cancelled=\(state.cancelledCount), peak=\(state.settings.peakLimitEV))")

        // 2. VoiceOver 关闭与开启下的非触控 .valueChanged（如 _accessibilityBumpValue: / 切换控制 / 编程调值）必须闭合编辑态、放行重置动作、且不被吞掉
        state.controlsVisible = true
        await settle()
        guard let remountedPeak = sliders(in: window).first(where: { $0.accessibilityIdentifier == "hdr.rendition.peakLimit" }) else {
            finish(exitCode: 2, note: "Missing remounted hdr.rendition.peakLimit UISlider")
            return
        }

        state.voiceOverOverride = true
        state.settings = makeProbeSettings(peak: 2.0)
        state.editingLog = []
        state.cancelledCount = 0
        await settle()
        remountedPeak.setValue(3.4, animated: false)
        remountedPeak.sendActions(for: .valueChanged)
        await settle()
        check(abs(state.settings.peakLimitEV - 3.4) < 0.001 && state.editingLog == [1, 0],
              "VoiceOver non-touch .valueChanged closes editing state cleanly (peak=\(state.settings.peakLimitEV), editing=\(state.editingLog))")

        let postBumpReset = remountedPeak.accessibilityCustomActions?.first(where: { $0.name == L10n.text("重置") })
        let postBumpHandled = postBumpReset?.actionHandler?(postBumpReset!) ?? false
        await settle()
        check(postBumpHandled && state.settings.peakLimitEV == 0 && abs(Double(remountedPeak.value) - 0) < 0.001,
              "Reset accessibilityCustomAction succeeds immediately after VoiceOver non-touch .valueChanged (handled=\(postBumpHandled), model=\(state.settings.peakLimitEV), slider=\(remountedPeak.value))")

        state.settings = makeProbeSettings(peak: 2.0)
        await settle()
        remountedPeak.setValue(3.4, animated: false)
        remountedPeak.sendActions(for: .valueChanged)
        await settle()
        state.controlsVisible = false
        await settle()
        check(state.cancelledCount == 0,
              "Closing panel after VoiceOver non-touch .valueChanged does not emit onCancelled (cancelled=\(state.cancelledCount))")

        state.controlsVisible = true
        await settle()
        guard let thirdPeak = sliders(in: window).first(where: { $0.accessibilityIdentifier == "hdr.rendition.peakLimit" }) else {
            finish(exitCode: 2, note: "Missing third hdr.rendition.peakLimit UISlider")
            return
        }
        state.voiceOverOverride = false
        state.settings = makeProbeSettings(peak: 2.0)
        state.editingLog = []
        await settle()
        thirdPeak.setValue(4.2, animated: false)
        thirdPeak.sendActions(for: .valueChanged)
        await settle()
        check(abs(state.settings.peakLimitEV - 4.2) < 0.001 && state.editingLog == [1, 0],
              "Non-touch .valueChanged with double-tap enabled updates value and closes editing state (peak=\(state.settings.peakLimitEV), editing=\(state.editingLog))")

        // 3. 外层 .disabled(true) 时禁用交互与 accessibilityIncrement
        state.controlsDisabled = true
        state.settings = makeProbeSettings(peak: 1.5)
        state.writes = 0
        state.editingLog = []
        await settle()
        thirdPeak.accessibilityIncrement()
        await settle()
        check(!thirdPeak.isEnabled && state.writes == 0 && state.settings.peakLimitEV == 1.5,
              "Outer .disabled(true) disables UISlider and blocks accessibilityIncrement (enabled=\(thirdPeak.isEnabled), writes=\(state.writes))")

        finish(exitCode: failures.isEmpty ? 0 : 1, note: nil)
    }

    private func finish(exitCode: Int32, note: String?) {
        if let note {
            failures.append(note)
            print("FAIL: \(note)")
        }
        let payload: [String: Any] = [
            "passes": passes,
            "failures": failures,
            "exitCode": Int(exitCode)
        ]
        if let path = ProcessInfo.processInfo.environment["RAWLAB_SLIDER_RESULT"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        fflush(stdout)
        exit(exitCode)
    }
}

final class HDRRenditionSliderAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "HDRRenditionSliderHarness", sessionRole: session.role)
        config.delegateClass = HDRRenditionSliderSceneDelegate.self
        return config
    }
}

final class HDRRenditionSliderSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let state = SliderHarnessState()
        state.configureFromEnvironment()
        let window = UIWindow(windowScene: windowScene)
        state.window = window
        window.rootViewController = UIHostingController(rootView: SliderHarnessRoot(state: state))
        window.makeKeyAndVisible()
        self.window = window
        if ProcessInfo.processInfo.environment["RAWLAB_SLIDER_UI_MODE"] != "1" {
            Task { @MainActor in
                await SliderMethodProbe().run(state: state, window: window)
            }
        }
    }
}

@main
enum HDRRenditionSliderHarness {
    static func main() {
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(HDRRenditionSliderAppDelegate.self)
        )
    }
}
