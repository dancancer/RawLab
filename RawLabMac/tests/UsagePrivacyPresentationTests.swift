import AppKit
import SwiftUI

@main struct UsagePrivacyPresentationTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "rawlab-usage-ui-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = UpdateChecker(defaults: defaults, currentVersion: "0.5.0", fetch: { throw URLError(.notConnectedToInternet) })
        let view = NSHostingView(rootView: AboutView(currentVersion: updates.currentVersion))
        let size = view.fittingSize
        guard size.width >= 440, size.height > 300, size.height < 850 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if CommandLine.arguments.count > 1 {
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        guard !UsageAnalytics.shared.isAvailable else { throw CocoaError(.featureUnsupported) }
        guard !window.isVisible else { throw CocoaError(.validationMissingMandatoryProperty) }
        print("PASS: native privacy surface \(Int(size.width))x\(Int(size.height)), unavailable by default")
    }
}
