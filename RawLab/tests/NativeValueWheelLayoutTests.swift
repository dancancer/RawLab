import RawLabKit
import SwiftUI
import UIKit

// MARK: - Rendered layer & UIKit frame inspection inside a hosted NativeValueWheel

private struct LayoutSnapshot {
    let hostView: UIView
    let size: CGSize
    let safeInsets: UIEdgeInsets
    let picker: UIPickerView
    let pickerFrame: CGRect
    let pickerLabels: [(String, CGRect)]
    let scrollViewFrame: CGRect?
    let cancelFrame: CGRect
    let applyFrame: CGRect
    let contextFrames: [CGRect]
    let defaultFrame: CGRect?
    let headerBottom: CGFloat
    let contentBottom: CGFloat
}

private enum WheelLayoutInspector {
    static func findPickerView(in root: UIView) -> UIPickerView? {
        if let picker = root as? UIPickerView { return picker }
        for subview in root.subviews {
            if let found = findPickerView(in: subview) { return found }
        }
        return nil
    }

    static func findContentScrollView(in root: UIView) -> UIScrollView? {
        if root is UIPickerView { return nil }
        if let scroll = root as? UIScrollView { return scroll }
        for subview in root.subviews {
            if let found = findContentScrollView(in: subview) { return found }
        }
        return nil
    }

    static func visiblePickerLabels(in picker: UIPickerView, hostView: UIView) -> [(String, CGRect)] {
        var labels: [(String, CGRect)] = []
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                let frame = label.convert(label.bounds, to: hostView)
                if !frame.isEmpty && frame.width > 0 && frame.height > 0 {
                    labels.append((text, frame))
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(picker)
        return labels
    }

    static func collectDrawingLayers(in rootLayer: CALayer, hostLayer: CALayer,
                                     excluding excludedLayers: [CALayer],
                                     scrollLayer: CALayer?,
                                     insideScroll: Bool = false) -> [(frame: CGRect, inScroll: Bool)] {
        if excludedLayers.contains(where: { $0 === rootLayer }) {
            return []
        }
        let nowInScroll = insideScroll || (scrollLayer != nil && rootLayer === scrollLayer)
        let typeName = String(describing: type(of: rootLayer))
        if typeName.contains("DrawingLayer") {
            let frame = rootLayer.convert(rootLayer.bounds, to: hostLayer)
            if frame.width > 1, frame.height > 1, frame.minX.isFinite, frame.minY.isFinite {
                return [(frame, nowInScroll)]
            }
            return []
        }
        var results: [(CGRect, Bool)] = []
        for sublayer in rootLayer.sublayers ?? [] {
            results.append(contentsOf: collectDrawingLayers(
                in: sublayer, hostLayer: hostLayer, excluding: excludedLayers,
                scrollLayer: scrollLayer, insideScroll: nowInScroll
            ))
        }
        return results
    }
}

// MARK: - Verification Suite

private final class WheelLayoutProbe {
    private var checks = 0
    private var failures: [String] = []

    private func assertTrue(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures.append("FAIL: \(message)")
        }
    }

    private func assertNear(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat, _ message: String) {
        checks += 1
        if abs(actual - expected) > tolerance {
            failures.append(String(format: "FAIL: %@ (actual=%.2f, expected=%.2f, tol=%.2f)",
                                   message, actual, expected, tolerance))
        }
    }

    @MainActor
    private func layoutCase(
        name: String,
        window: UIWindow,
        size: CGSize,
        contentSizeCategory: UIContentSizeCategory,
        compactWindowClass: Bool,
        unit: String = "%",
        help: String = "默认值：0 %；范围：-100 % 至 +100 %；步进：+1 %。"
    ) async -> LayoutSnapshot? {
        window.traitOverrides.horizontalSizeClass = compactWindowClass ? .compact : .unspecified

        let wheel = NativeValueWheel(
            title: "饱和度",
            original: 12,
            scale: AdjustmentScale(range: -100...100, step: 1),
            defaultValue: 0,
            unit: unit,
            formatter: { abs($0) < 0.5 ? "0" : String(format: "%+.0f", $0) },
            help: help,
            onCancel: {},
            onApply: { _ in }
        )

        let rootVC = UIViewController()
        rootVC.view.backgroundColor = .systemBackground
        let childHC = UIHostingController(rootView: wheel)
        childHC.safeAreaRegions = []
        childHC.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        childHC.view.translatesAutoresizingMaskIntoConstraints = true
        childHC.view.autoresizingMask = []
        childHC.view.frame = CGRect(origin: .zero, size: size)
        rootVC.addChild(childHC)
        rootVC.view.addSubview(childHC.view)
        childHC.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        for _ in 0..<8 {
            rootVC.view.setNeedsLayout()
            rootVC.view.layoutIfNeeded()
            childHC.view.setNeedsLayout()
            childHC.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        guard let picker = WheelLayoutInspector.findPickerView(in: childHC.view) else {
            assertTrue(false, "[\(name)] Missing UIPickerView in hierarchy")
            return nil
        }

        let scrollView = WheelLayoutInspector.findContentScrollView(in: childHC.view)
        let excludedLayers = childHC.view.subviews
            .filter { String(describing: type(of: $0)).contains("PlatformViewHost") }
            .map(\.layer)
        let layers = WheelLayoutInspector.collectDrawingLayers(
            in: childHC.view.layer, hostLayer: childHC.view.layer,
            excluding: excludedLayers, scrollLayer: scrollView?.layer
        )

        let sortedByY = layers.sorted { $0.frame.minY < $1.frame.minY }
        guard sortedByY.count >= 2 else {
            assertTrue(false, "[\(name)] Expected at least header drawing layers, found \(sortedByY.count)")
            return nil
        }
        let topRowY = sortedByY[0].frame.midY
        let headerPairs = sortedByY.filter { abs($0.frame.midY - topRowY) <= 12 }.sorted { $0.frame.minX < $1.frame.minX }
        guard headerPairs.count >= 2 else {
            assertTrue(false, "[\(name)] Expected 2 header button layers, found \(headerPairs.count)")
            return nil
        }

        let cancelFrame = headerPairs.first!.frame
        let applyFrame = headerPairs.last!.frame
        let effectivePickerView: UIView = {
            if let sup = picker.superview, sup !== childHC.view, sup.clipsToBounds {
                return sup
            }
            return picker
        }()
        let pickerFrame = effectivePickerView.convert(effectivePickerView.bounds, to: childHC.view)
        let scrollFrame = scrollView.map { $0.convert($0.bounds, to: childHC.view) }
        let safeInsets = UIEdgeInsets.zero
        let headerBottom = max(16 + 44, max(cancelFrame.maxY, applyFrame.maxY))
        let contentBottom = size.height - 16

        let bodyLayers = layers.filter { item in
            abs(item.frame.midY - topRowY) > 12 || item.frame.minY > headerBottom
        }

        let contextFrames: [CGRect]
        let defaultFrame: CGRect?
        if scrollFrame != nil && size.width > 480 && size.height < 400 {
            contextFrames = bodyLayers.filter(\.inScroll).map(\.frame).sorted { $0.minY < $1.minY }
            defaultFrame = bodyLayers.first { !$0.inScroll && $0.frame.minY >= pickerFrame.maxY - 2 }?.frame
        } else {
            contextFrames = bodyLayers.filter { $0.frame.midY < pickerFrame.minY }.map(\.frame).sorted { $0.minY < $1.minY }
            defaultFrame = bodyLayers.first { $0.frame.midY > pickerFrame.maxY }?.frame
        }

        let pickerLabels = WheelLayoutInspector.visiblePickerLabels(in: picker, hostView: childHC.view)
        return LayoutSnapshot(
            hostView: childHC.view,
            size: size,
            safeInsets: safeInsets,
            picker: picker,
            pickerFrame: pickerFrame,
            pickerLabels: pickerLabels,
            scrollViewFrame: scrollFrame,
            cancelFrame: cancelFrame,
            applyFrame: applyFrame,
            contextFrames: contextFrames,
            defaultFrame: defaultFrame,
            headerBottom: headerBottom,
            contentBottom: contentBottom
        )
    }

    @MainActor
    func run(window: UIWindow) async {
        // 1. Wide iPhone portrait sheet (430x850, .large Dynamic Type)
        if let s = await layoutCase(name: "iphone-430x850", window: window, size: CGSize(width: 430, height: 850),
                                    contentSizeCategory: .large, compactWindowClass: true) {
            let hostMidX = s.size.width / 2
            let headerMidX = (s.cancelFrame.minX + s.applyFrame.maxX) / 2
            assertNear(headerMidX, hostMidX, tolerance: 2.0, "[iphone-430x850] Header cancel/apply symmetric around center")
            assertTrue(s.contextFrames.count == 3, "[iphone-430x850] Expected title/draft/range layers (got \(s.contextFrames.count))")
            for (index, frame) in s.contextFrames.enumerated() {
                assertNear(frame.midX, hostMidX, tolerance: 1.5, "[iphone-430x850] Context row \(index) horizontally centered")
            }
            assertNear(s.pickerFrame.midX, hostMidX, tolerance: 1.5, "[iphone-430x850] UIPickerView horizontally centered")
            assertNear(s.pickerFrame.width, s.size.width - 32, tolerance: 2.0,
                       "[iphone-430x850] UIPickerView fills full content width (not 320pt)")
            assertTrue(s.defaultFrame != nil, "[iphone-430x850] Default button rendered below picker")
            if let defFrame = s.defaultFrame, let rangeFrame = s.contextFrames.last, let titleFrame = s.contextFrames.first {
                assertNear(defFrame.midX, hostMidX, tolerance: 1.5, "[iphone-430x850] Default button horizontally centered")
                assertTrue(s.pickerFrame.minY - rangeFrame.maxY <= 24,
                           String(format: "[iphone-430x850] Cohesive vertical spacing range->picker (gap=%.1f)",
                                  s.pickerFrame.minY - rangeFrame.maxY))
                let defTop = min(defFrame.minY, defFrame.midY - 22)
                let defBottom = max(defFrame.maxY, defFrame.midY + 22)
                assertTrue(defTop - s.pickerFrame.maxY <= 24,
                           String(format: "[iphone-430x850] Cohesive vertical spacing picker->default (gap=%.1f)",
                                  defTop - s.pickerFrame.maxY))
                let contentRegionMidY = (s.headerBottom + 8 + s.contentBottom) / 2
                let groupMinY = titleFrame.minY
                let groupMidY = (groupMinY + defBottom) / 2
                assertNear(groupMidY, contentRegionMidY, tolerance: 10.0,
                           "[iphone-430x850] Content group vertically centered below header")
            }
            assertTrue(!s.pickerLabels.isEmpty, "[iphone-430x850] UIPickerView has visible UILabel rows")
            for (text, frame) in s.pickerLabels {
                assertNear(frame.midX, hostMidX, tolerance: 2.0,
                           "[iphone-430x850] UIPickerView row '\(text)' horizontally centered")
            }
        }

        // 2. Wide-short landscape sheet (720x300, .large)
        if let s = await layoutCase(name: "landscape-720x300-large", window: window, size: CGSize(width: 720, height: 300),
                                    contentSizeCategory: .large, compactWindowClass: true) {
            let contentWidth = s.size.width - 32
            let leftColumnWidth = contentWidth * 0.44
            let rightColumnMinX = 16 + leftColumnWidth + 24
            let rightColumnMidX = (rightColumnMinX + (s.size.width - 16)) / 2
            let leftColumnMidX = 16 + leftColumnWidth / 2
            assertTrue(s.scrollViewFrame != nil, "[landscape-720x300-large] Left context uses ScrollView")
            assertTrue(s.contextFrames.count == 3, "[landscape-720x300-large] Context displays title/draft/range")
            for (index, frame) in s.contextFrames.enumerated() {
                assertNear(frame.midX, leftColumnMidX, tolerance: 2.0,
                           "[landscape-720x300-large] Context row \(index) centered in left 44% column")
                assertTrue(frame.maxX <= 16 + leftColumnWidth + 2.0,
                           "[landscape-720x300-large] Context row \(index) fits inside left 44% column")
            }
            assertTrue(s.pickerFrame.minX >= 16 + leftColumnWidth - 2.0,
                       "[landscape-720x300-large] Picker does not overlap left context")
            assertNear(s.pickerFrame.midX, rightColumnMidX, tolerance: 2.0,
                       "[landscape-720x300-large] Picker centered in right column")
            assertTrue(s.pickerFrame.maxX <= s.size.width - 16 + 2.0,
                       "[landscape-720x300-large] Picker fits within trailing padding")
            assertTrue(s.defaultFrame != nil, "[landscape-720x300-large] Default button present in right column")
            if let defFrame = s.defaultFrame, let first = s.contextFrames.first, let last = s.contextFrames.last {
                assertNear(defFrame.midX, rightColumnMidX, tolerance: 2.0,
                           "[landscape-720x300-large] Default button centered in right column")
                let contentMidY = (s.headerBottom + 8 + s.contentBottom) / 2
                let contextMidY = (first.minY + last.maxY) / 2
                assertNear(contextMidY, contentMidY, tolerance: 10.0,
                           "[landscape-720x300-large] Context column vertically centered when shorter than container")
            }
        }

        // 3. Wide-short landscape sheet at extreme AX5 (720x300, .accessibilityExtraExtraExtraLarge)
        if let s = await layoutCase(name: "landscape-720x300-ax5", window: window, size: CGSize(width: 720, height: 300),
                                    contentSizeCategory: .accessibilityExtraExtraExtraLarge,
                                    compactWindowClass: true) {
            assertTrue(!s.contextFrames.isEmpty, "[landscape-720x300-ax5] Context layers rendered")
            if let titleFrame = s.contextFrames.first {
                assertTrue(titleFrame.minY >= s.headerBottom - 1.0,
                           "[landscape-720x300-ax5] Title starts cleanly without top clipping")
            }
            assertTrue(s.pickerFrame.height >= 99.0,
                       "[landscape-720x300-ax5] Picker maintains >= 100pt height")
            assertTrue(s.pickerFrame.maxX <= s.size.width - 14.0,
                       "[landscape-720x300-ax5] Picker stays within container width")
            if let defFrame = s.defaultFrame {
                let defBottom = max(defFrame.maxY, defFrame.midY + 22)
                assertTrue(defBottom <= s.size.height + 1.0,
                           "[landscape-720x300-ax5] Default button stays inside container height")
            } else {
                assertTrue(false, "[landscape-720x300-ax5] Default button missing")
            }
        }

        // 4. iPad popover sizes (360x440 .large, 440x600 .accessibilityExtraLarge)
        for (name, size, category) in [
            ("popover-360x440-large", CGSize(width: 360, height: 440), UIContentSizeCategory.large),
            ("popover-440x600-ax3", CGSize(width: 440, height: 600), UIContentSizeCategory.accessibilityExtraLarge)
        ] {
            if let s = await layoutCase(name: name, window: window, size: size,
                                        contentSizeCategory: category, compactWindowClass: false) {
                let hostMidX = size.width / 2
                assertTrue(!s.contextFrames.isEmpty, "[\(name)] Context layers rendered")
                for (index, frame) in s.contextFrames.enumerated() {
                    assertNear(frame.midX, hostMidX, tolerance: 2.0, "[\(name)] Context row \(index) centered")
                }
                assertNear(s.pickerFrame.midX, hostMidX, tolerance: 2.0, "[\(name)] Picker centered")
                assertNear(s.pickerFrame.width, size.width - 32, tolerance: 2.0, "[\(name)] Picker fills popover width")
                assertTrue(s.defaultFrame != nil, "[\(name)] Default button present")
                if let defFrame = s.defaultFrame, let titleFrame = s.contextFrames.first {
                    let defBottom = max(defFrame.maxY, defFrame.midY + 22)
                    assertNear(defFrame.midX, hostMidX, tolerance: 2.0, "[\(name)] Default button centered")
                    assertTrue(titleFrame.minY >= s.headerBottom, "[\(name)] Content below header without overlap")
                    assertTrue(defFrame.maxY <= size.height - 14.0, "[\(name)] Default button stays inside bounds")
                    let contentRegionMidY = (s.headerBottom + 8 + s.contentBottom) / 2
                    let groupMidY = (titleFrame.minY + defBottom) / 2
                    assertNear(groupMidY, contentRegionMidY, tolerance: 12.0,
                               "[\(name)] Content group vertically centered below header")
                }
            }
        }

        // 5. Unitless parameter (empty unit & empty help): centered without trailing-space bias
        if let s = await layoutCase(name: "unitless-430x850", window: window, size: CGSize(width: 430, height: 850),
                                    contentSizeCategory: .large, compactWindowClass: true,
                                    unit: "", help: "") {
            let hostMidX = s.size.width / 2
            assertTrue(s.contextFrames.count == 3, "[unitless-430x850] Context displays title/draft/range")
            for (index, frame) in s.contextFrames.enumerated() {
                assertNear(frame.midX, hostMidX, tolerance: 1.5, "[unitless-430x850] Context row \(index) centered")
            }
            assertTrue(s.defaultFrame != nil, "[unitless-430x850] Default button present")
            if let defFrame = s.defaultFrame {
                assertNear(defFrame.midX, hostMidX, tolerance: 1.5, "[unitless-430x850] Unitless default button centered")
            }
            let accVal = s.picker.accessibilityValue ?? ""
            assertTrue(!accVal.hasSuffix(" "), "[unitless-430x850] Picker accessibilityValue has no trailing whitespace")
        }

        let passed = failures.isEmpty
        writeResult(passed: passed, checks: checks, failures: failures)
        if passed {
            print("PASS: \(checks) NativeValueWheel layout checks passed")
            fflush(stdout)
            exit(0)
        } else {
            for failure in failures {
                fputs("\(failure)\n", stderr)
            }
            fputs("FAIL: \(failures.count)/\(checks) NativeValueWheel layout checks failed\n", stderr)
            fflush(stderr)
            exit(1)
        }
    }

    private func writeResult(passed: Bool, checks: Int, failures: [String]) {
        guard let path = ProcessInfo.processInfo.environment["RAWLAB_WHEEL_RESULT"], !path.isEmpty else { return }
        let payload: [String: Any] = ["passed": passed, "checks": checks, "failures": failures]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Standalone UIKit lifecycle (plus optional screenshot showcase mode)

private struct ScreenshotSheetHost: View {
    @State private var presented = true

    var body: some View {
        Color(white: 0.12)
            .ignoresSafeArea()
            .sheet(isPresented: $presented) {
                NativeValueWheel(
                    title: "饱和度",
                    original: 12,
                    scale: AdjustmentScale(range: -100...100, step: 1),
                    defaultValue: 0,
                    unit: "%",
                    formatter: { abs($0) < 0.5 ? "0" : String(format: "%+.0f", $0) },
                    help: "默认值：0 %；范围：-100 % 至 +100 %；步进：+1 %。",
                    onCancel: {},
                    onApply: { _ in }
                )
            }
    }
}

final class WheelLayoutAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Wheel Layout Tests", sessionRole: session.role)
        configuration.delegateClass = WheelLayoutSceneDelegate.self
        return configuration
    }
}

final class WheelLayoutSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.tintColor = .systemYellow
        self.window = window

        if ProcessInfo.processInfo.environment["RAWLAB_WHEEL_SCREENSHOT_MODE"] == "1" {
            window.rootViewController = UIHostingController(rootView: ScreenshotSheetHost())
            window.makeKeyAndVisible()
            return
        }

        window.makeKeyAndVisible()
        Task { @MainActor in
            await WheelLayoutProbe().run(window: window)
        }
    }
}

@main
enum NativeValueWheelLayoutTests {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                          NSStringFromClass(WheelLayoutAppDelegate.self))
    }
}
