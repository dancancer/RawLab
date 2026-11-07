import Foundation
import ImageIO
import UIKit

@main enum PhotoEntryTests {
    enum Failure: Error { case check(String) }

    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.check(message) }
        print("PASS: \(message)")
    }

    static func waitUntil(_ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(120)
        while !done() {
            guard Date() < deadline else { throw Failure.check("Timed out waiting for editor") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let buffer = Sony2FujiProcessor.Buffer(data: Data(repeating: 128, count: 4 * 3 * 4),
            width: 4, height: 3, stride: 16, pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .legacy)
        let source = root.appendingPathComponent("decoded-original.raw")
        try Data("original RAW without ImageIO metadata".utf8).write(to: source)
        let jpeg = try processor.makeJPEGData(from: buffer, sourceURL: source, orientation: .right,
                                             quality: 0.92, sourceIsRaw: true)
        try checkJPEG(jpeg, width: 4, height: 3, orientation: 6)
        do {
            _ = try processor.makeJPEGData(from: buffer, sourceURL: source, orientation: .up, quality: 0.92)
            throw Failure.check("Unreadable raster metadata was silently discarded")
        } catch ExportMetadata.Failure.unreadableSource {
            print("PASS: Unreadable raster metadata still reports an error")
        }
        let x3f = root.appendingPathComponent("decoded-original.x3f")
        try Data("FOVb".utf8).write(to: x3f)
        let oldJPEG = try processor.makeJPEGData(from: buffer, sourceURL: x3f, orientation: .up, quality: 0.92)
        try checkJPEG(oldJPEG, width: 4, height: 3, orientation: 1)
        try restoredPhotoEdit(root, processor: processor, buffer: buffer)

        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            try rawExports(root, original: URL(fileURLWithPath: CommandLine.arguments[2]))
        } else {
            print("SKIP: Single/batch RAW integration requires a RAW fixture unreadable by ImageIO after renaming to .raw")
        }
    }

    static func checkJPEG(_ data: Data, width: Int, height: Int, orientation: Int) throws {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        try check(properties?[kCGImagePropertyPixelWidth] as? Int == width &&
                  properties?[kCGImagePropertyPixelHeight] as? Int == height &&
                  properties?[kCGImagePropertyOrientation] as? Int == orientation,
                  "JPEG fallback writes valid dimensions and orientation")
    }

    static func restoredPhotoEdit(_ root: URL, processor: Sony2FujiProcessor,
                                  buffer: Sony2FujiProcessor.Buffer) throws {
        let source = root.appendingPathComponent("library-original.jpg")
        // 用代码生成普通照片，验证真实导入路径使用带内容哈希的相册身份。
        let data = try processor.makeJPEGData(from: buffer, sourceURL: root.appendingPathComponent("decoded-original.x3f"),
                                              orientation: .up, quality: 0.92)
        try data.write(to: source)
        let store = try EditPersistence(directory: root.appendingPathComponent("library-edits"))
        let content = try PhotoIdentity.fallback(for: source)
        var settings = RawSettings.default; settings.exposure = 0.75
        try store.save(content, state: .init(settings: settings))
        let before = try Data(contentsOf: store.directory.appendingPathComponent("edits.json"))
        let identity = try PhotoIdentity.fallback(for: source, resourceIdentifier: "library-original")
        let model = RawEditorViewModel(editPersistence: store)
        var restored: RawSettings?
        model.importImage(from: .raster(source), identity: identity, onSettingsRestored: { restored = $0 })
        try waitUntil { !model.isBusy }
        try check(model.hasImage && model.sourceIdentity?.key == "photo:library-original" && restored?.exposure == 0.75,
                  "Photo import restores legacy content adjustments while retaining its library identity")
        try check(try Data(contentsOf: store.directory.appendingPathComponent("edits.json")) == before,
                  "Opening the editor does not migrate legacy edits")
    }

    static func rawExports(_ root: URL, original: URL) throws {
        let source = root.appendingPathComponent("renamed.raw")
        try FileManager.default.copyItem(at: original, to: source)
        let properties = CGImageSourceCreateWithURL(source as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
        try check(properties == nil, "The renamed RAW fixture reproduces missing ImageIO metadata")
        let store = try EditPersistence(directory: root.appendingPathComponent("raw-edits"))
        let model = RawEditorViewModel(editPersistence: store)
        model.importImage(from: .raw(source))
        try waitUntil { !model.isBusy }
        try check(model.hasImage, "The native core successfully decodes the renamed RAW")
        var single: Result<Data, Error>?
        model.exportJPEG(settings: .default, longEdge: 64) { single = $0 }
        try waitUntil { single != nil }
        try check(!single!.get().isEmpty, "Single RAW JPEG export tolerates missing source metadata")
        let identity = try PhotoIdentity.fallback(for: source)
        let target = BatchTarget(identity: identity, sourceURL: source, displayName: "renamed.raw", sourceKind: .raw)
        let snapshot = BatchSourceSnapshot(identity: identity, sourceFile: .externallyManaged(source),
            displayName: "renamed.raw", sourceKind: .raw, settings: .default)
        let journal = try BatchJournalStore(directory: root.appendingPathComponent("raw-jobs"))
        let batch = BatchExportModel(job: .init(source: snapshot, targets: [target]), journalStore: journal)
        let data = try batch.render(target: target, settings: .default, look: nil, longEdge: 64)
        try check(!data.isEmpty, "Batch RAW JPEG export tolerates missing source metadata")
    }
}
