import RawLabKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum MacUITestRobot {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RenderError.failed(message) }
        print("PASS: \(message)")
    }

    @MainActor static func isolatedModel(root: URL) -> EditorModel {
        EditorModel(
            lookDirectory: root.appendingPathComponent("looks", isDirectory: true),
            editDirectory: root.appendingPathComponent("edits", isDirectory: true),
            batchDirectory: root.appendingPathComponent("batch", isDirectory: true),
            presetDirectory: root.appendingPathComponent("presets", isDirectory: true)
        )
    }

    @MainActor static func settle(_ model: EditorModel) async throws {
        try await Task.sleep(for: .milliseconds(350))
        for _ in 0..<600 {
            if !model.busy, !model.workerActive, model.result != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RenderError.failed("Native editor render timed out")
    }

    @MainActor static func fields(_ view: NSView) -> [NumericTextField] {
        (view as? NumericTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
    }

    @MainActor static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }

    @MainActor static func png(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.failed("No native UI bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    @MainActor static func window<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        title: String = ""
    ) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    static func makeRasterFixtures(in directory: URL) throws -> (jpg: URL, png: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 640, height = 420
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(40 + x * 180 / width)
                pixels[index + 1] = UInt8(30 + y * 180 / height)
                pixels[index + 2] = UInt8(210 - x * 110 / width)
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw RenderError.failed("Cannot construct RGB fixture")
        }
        let jpg = directory.appendingPathComponent("fixture.jpg")
        let png = directory.appendingPathComponent("fixture.png")
        for (url, type) in [(jpg, UTType.jpeg), (png, UTType.png)] where !FileManager.default.fileExists(atPath: url.path) {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw RenderError.failed("Cannot create \(url.lastPathComponent)")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw RenderError.failed("Cannot encode \(url.lastPathComponent)")
            }
        }
        return (jpg, png)
    }
}
