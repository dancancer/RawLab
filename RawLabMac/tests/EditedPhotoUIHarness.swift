import AppKit
import SwiftUI

// 使用真实 EditorView、保存和渲染路径；测试只提供隔离的输入和启动状态。
@main struct EditedPhotoUIHarness: App {
    @StateObject private var model: EditorModel
    private let first: URL
    init() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try! FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        first = photos.appendingPathComponent("01 Edited.png")
        let second = photos.appendingPathComponent("02 Original.png")
        for (index, file) in [first, second].enumerated() where !FileManager.default.fileExists(atPath: file.path) {
            let image = NSImage(size: NSSize(width: 640, height: 420), flipped: false) { bounds in
                NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.35, alpha: 1).setFill(); bounds.fill()
                for x in stride(from: 0, to: 640, by: 40) {
                    NSColor(calibratedRed: CGFloat(x) / 900 + 0.1, green: index == 0 ? 0.3 : 0.55, blue: 0.25, alpha: 1).setFill()
                    NSRect(x: x, y: 80, width: 35, height: 260).fill()
                }
                return true
            }
            let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            try! rep.representation(using: .png, properties: [:])!.write(to: file)
        }
        UserDefaults.standard.set([photos.path], forKey: "photoFolders")
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        let store = try! EditPersistence()
        let seeded = root.appendingPathComponent("seeded")
        if !FileManager.default.fileExists(atPath: seeded.path) {
            var edits = Adjustments(); edits.exposureMode = .sensor; edits.exposure = 1.2
            try! store.save(first, state: .init(settings: edits, filmID: ""))
            try! Data().write(to: seeded)
        }
        _model = StateObject(wrappedValue: EditorModel())
    }
    var body: some Scene {
        WindowGroup {
            EditorView(model: model).onAppear { if model.file == nil { model.open(first) } }
        }.defaultSize(width: 1380, height: 900)
    }
}
