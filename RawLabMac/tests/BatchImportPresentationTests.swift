import AppKit
import SwiftUI

@main
struct BatchImportPresentationTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("batch-ui-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        UserDefaults.standard.setVolatileDomain(["photoFolders": []], forName: UserDefaults.argumentDomain)
        let model = EditorModel(lookDirectory: root.appendingPathComponent("library"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let files = try (1...18).map { index -> URL in
            let path = root.appendingPathComponent("Batch-FLog2C-long-unsupported-look-\(index).cube")
            try "invalid".write(to: path, atomically: true, encoding: .utf8)
            return path
        }
        model.importLooks(files)
        for _ in 0..<100 {
            if !model.lookLibraryBusy && window.attachedSheet != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard model.lookImportReport?.contains(files.last!.lastPathComponent) == true else {
            throw RenderError.failed("Batch report lost a failed filename")
        }
        let report = model.lookImportReport
        for (name, size) in [("compact", NSSize(width: 950, height: 620)), ("wide", NSSize(width: 1320, height: 850))] {
            window.setContentSize(size)
            model.lookImportReport = report
            try await Task.sleep(nanoseconds: 600_000_000)
            guard let sheet = window.attachedSheet,
                  sheet.frame.width <= size.width, sheet.frame.height <= size.height else {
                throw RenderError.failed("Import result sheet is missing or exceeds the editor")
            }
            let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("mac-batch-\(name).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(sheet.windowNumber), output.path]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { throw RenderError.failed("Window screenshot failed") }
            print("PASS batch result sheet fits \(name): \(Int(sheet.frame.width))x\(Int(sheet.frame.height))")
            model.lookImportReport = nil
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}
