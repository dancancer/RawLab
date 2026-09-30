import AppKit
import SwiftUI

private final class BrowserSelection: ObservableObject {
    @Published var url: URL?
}

private struct BrowserHarness: View {
    let library: PhotoLibrary
    @ObservedObject var selection: BrowserSelection
    var body: some View {
        FileBrowser(library: library, selected: selection.url) { selection.url = $0 }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor struct FileBrowserTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(description: message) }
    }

    static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    static func waitForScrollLayout(_ scroll: NSScrollView) async throws {
        var previous = (scroll.documentView!.frame.height, scroll.contentView.bounds.origin.y)
        var stableSamples = 0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let current = (scroll.documentView!.frame.height, scroll.contentView.bounds.origin.y)
            stableSamples = current == previous ? stableSamples + 1 : 0
            if stableSamples == 10 { return }
            previous = current
        }
        throw TestFailure(description: "Scroll layout did not settle before selecting a photo")
    }

    static func waitForFolder(_ folder: PhotoFolder) async throws {
        for _ in 0..<100 {
            if !folder.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(!folder.loading && folder.error == nil, "Folder failed to load: \(folder.url.path)")
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    static func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        }
    }

    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fixture: URL?
        if let source = ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"] {
            let copy = directory.appendingPathComponent("fixture.rawdata")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
            fixture = copy
        }
        var directories: [URL] = []
        for folder in 0..<3 {
            let child = directory.appendingPathComponent("folder-\(folder)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            directories.append(child)
            for index in 0..<1001 {
                let photo = child.appendingPathComponent(String(format: "photo-%04d.ARW", index))
                if let fixture {
                    try FileManager.default.linkItem(at: fixture, to: photo)
                } else {
                    try Data().write(to: photo)
                }
            }
        }
        try await verifyBrowser(directories: [directories[0]], width: 200, nested: false)
        try await verifyBrowser(directories: directories, width: 240, nested: false)
        try await verifyBrowser(directories: [directory], width: 300, nested: true)
    }

    static func verifyBrowser(directories: [URL], width: CGFloat, nested: Bool) async throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(["photoFolders": directories.map(\.path)], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let library = PhotoLibrary()
        let selection = BrowserSelection()
        let host = NSHostingView(rootView: BrowserHarness(library: library, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // 挂载后加载目录，同时验证异步目录更新会传到列表。
        for root in library.roots {
            root.toggle()
            try await waitForFolder(root)
            if nested {
                for child in root.folders {
                    child.toggle()
                    try await waitForFolder(child)
                }
            }
        }
        try await settle()
        let rows = FileBrowserRow.rows(in: library.roots)
        try check(Set(rows.map(\.id)).count == rows.count, "Browser rows must have unique IDs")
        let oddRows = rows.filter {
            if case .photos(_, nil) = $0.content { return true }
            return false
        }
        try check(oddRows.count == (nested ? 3 : directories.count), "Odd photo counts must leave the final right column empty")
        if nested {
            let child = library.roots[0].folders[0]
            var changes = 0
            let subscription = library.objectWillChange.sink { changes += 1 }
            defer { subscription.cancel() }
            child.toggle()
            try await settle()
            try check(changes > 0, "Nested folder changes must reach the library")
            try check(FileBrowserRow.rows(in: library.roots).count == rows.count - 501,
                      "Collapsing a child removes only its photo rows")
            child.toggle()
            try await settle()
            try check(FileBrowserRow.rows(in: library.roots).map(\.id) == rows.map(\.id),
                      "Reopening a child restores the same row IDs")
            let overlapping = FileBrowserRow.rows(in: library.roots + [child])
            try check(Set(overlapping.map(\.id)).count == overlapping.count,
                      "A folder also added as a root must have distinct row IDs")
        }
        guard let scroll = scrollView(in: host) else { throw TestFailure(description: "Missing browser scroll view") }
        for fraction in [0.1, 0.4, 0.7, 0.9] {
            let offset = (scroll.documentView!.frame.height - scroll.contentView.bounds.height) * fraction
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            // 慢速运行时先等布局稳定，再记录选中前的位置；不放宽选中后的断言。
            try await waitForScrollLayout(scroll)
            let before = scroll.contentView.bounds.origin.y
            let height = scroll.documentView!.frame.height
            let scrollPosition = before / (height - scroll.contentView.bounds.height)
            let previous = selection.url
            var clickedPoint = NSPoint.zero
            // 避开行间空隙；仍通过真实按钮事件选中照片，不直接赋值选择状态。
            for y in stride(from: 250.0, through: 350.0, by: 20) {
                clickedPoint = scroll.convert(NSPoint(x: 60, y: y), to: nil)
                click(clickedPoint, in: window)
                try await settle()
                if selection.url != previous { break }
            }
            try check(selection.url != nil && selection.url != previous, "Click did not select a new photo")
            let clicked = selection.url
            click(clickedPoint, in: window)
            try await settle()
            try check(selection.url == clicked, "Photo under pointer changed after selection: \(clicked!.lastPathComponent) -> \(selection.url!.lastPathComponent)")
            let after = scroll.contentView.bounds.origin.y
            let newPosition = after / (scroll.documentView!.frame.height - scroll.contentView.bounds.height)
            try check(abs(newPosition - scrollPosition) < 0.001,
                      "Selecting a photo moved scrollbar position: \(scrollPosition) -> \(newPosition)")
            try check(abs(after - before) < 1, "Selecting a photo moved the browser by \(after - before) points")
            try check(scrollView(in: host) === scroll, "Selection replaced the browser scroll view")
        }
        if let path = ProcessInfo.processInfo.environment["RAWLAB_BROWSER_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        print("PASS: Stable photo selection at width \(Int(width)), roots \(directories.count), nested \(nested)")
    }
}
