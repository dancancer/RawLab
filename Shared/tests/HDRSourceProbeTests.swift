import Foundation
import ImageIO

enum HDRSourceProbeTests {
    static func unsupportedSystem(_ url: URL, onSDRFallback: () -> Void) throws -> HDRSourceInfo? {
        try HDRSourceInfo.probe(url, onSDRFallback: onSDRFallback, supportsHDR: false) { _, _, diagnostic in
            diagnostic!.pointee.reason = UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM)
            return SONY2FUJI_STATUS_UNSUPPORTED
        }
    }

    static func run() throws {
        let url = URL(fileURLWithPath: "/probe-fixture.jpg")
        var notices = 0
        let fallback = try unsupportedSystem(url) { notices += 1 }
        try require(fallback == nil && notices == 1,
                    "macOS 14 unsupported-system probes fall back to SDR and report once")
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lutools/tests/fixtures/hdr/apple-legacy-macos26.jpg")
        notices = 0
        do {
            _ = try unsupportedSystem(apple) { notices += 1 }
            throw NSError(domain: "Apple gain maps must retain the unsupported-system error", code: 1)
        } catch let error as HDRNativeError {
            try require(error.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM) && notices == 0,
                        "Apple gain maps fail before SDR open or batch admission and retain their system diagnostic")
        }
        try declaredGainMaps()
        for suffix in ["jpeg", "heic", "heif"] {
            notices = 0
            let info = try unsupportedSystem(url.deletingPathExtension().appendingPathExtension(suffix)) { notices += 1 }
            try require(info == nil && notices == 1, "\(suffix) containers share the macOS 14 SDR fallback policy")
        }
        for reason in [SONY2FUJI_HDR_REASON_NOT_HDR, SONY2FUJI_HDR_REASON_MALFORMED_AUX,
                       SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR, SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,
                       SONY2FUJI_HDR_REASON_OUT_OF_MEMORY] {
            notices = 0
            do {
                let info = try HDRSourceInfo.probe(url, onSDRFallback: { notices += 1 }, supportsHDR: false) { _, _, diagnostic in
                    diagnostic!.pointee.reason = UInt32(reason)
                    return SONY2FUJI_STATUS_UNSUPPORTED
                }
                try require(reason == SONY2FUJI_HDR_REASON_NOT_HDR && info == nil, "only NOT_HDR is an ordinary image")
            } catch let error as HDRNativeError {
                try require(reason != SONY2FUJI_HDR_REASON_NOT_HDR && error.reason == UInt32(reason),
                            "other HDR failures retain their diagnostics")
            }
            try require(notices == 0, "ordinary images and other HDR failures do not report SDR fallback")
        }
        do {
            _ = try HDRSourceInfo.probe(url, supportsHDR: false, allowSDRFallback: false) { _, _, diagnostic in
                diagnostic!.pointee.reason = UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM)
                return SONY2FUJI_STATUS_UNSUPPORTED
            }
            throw NSError(domain: "strict Agent probes must reject unsupported-system gain maps", code: 1)
        } catch let error as HDRNativeError {
            try require(error.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM),
                        "strict probes reject gain maps on macOS 14 instead of generating raster Agent recipes")
        }
        do {
            _ = try HDRSourceInfo.probe(url, supportsHDR: true) { _, _, diagnostic in
                diagnostic!.pointee.reason = UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM)
                return SONY2FUJI_STATUS_UNSUPPORTED
            }
            throw NSError(domain: "supported systems must retain unsupported-system errors", code: 1)
        } catch let error as HDRNativeError {
            try require(error.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM),
                        "macOS 15 and iOS 18 keep strict HDR probe behavior")
        }
        let supported = try HDRSourceInfo.probe(url, supportsHDR: true) { _, info, _ in
            info!.pointee.width = 42
            return SONY2FUJI_STATUS_OK
        }
        try require(supported?.native.width == 42, "successful HDR probes retain source information")
    }

    private static func declaredGainMaps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 3,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data([128, 128, 128]) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        for (index, declaration) in ["urn:com:apple:photo:2020:aux:hdrgainmap", "http://ns.apple.com/HDRGainMap/1.0/",
                                     "http://ns.adobe.com/hdr-gain-map/1.0/", "urn:iso:std:iso:ts:21496:-1",
                                     "urn:iso:std:iso:ts:21496:-1 urn:com:apple:photo:2020:aux:hdrgainmap"].enumerated() {
            let url = directory.appendingPathComponent("declaration-\(index).jpg")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            try require(CGImageDestinationFinalize(destination), "gain-map declaration fixture is generated")
            var data = try Data(contentsOf: url)
            // 模拟旧系统已识别声明但不提供辅助字典的边界，保留可读取的 SDR 基图。
            data.append(Data(declaration.utf8))
            try data.write(to: url)
            var notices = 0
            do {
                let info = try unsupportedSystem(url) { notices += 1 }
                try require(index >= 2 && info == nil && notices == 1,
                            "only ISO and Adobe declarations without Apple auxiliary data allow SDR fallback")
            } catch let error as HDRNativeError {
                try require(index < 2 && error.reason == UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM) && notices == 0,
                            "both Apple declarations retain their system diagnostic when ImageIO has no auxiliary data")
            }
        }
    }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }
}
