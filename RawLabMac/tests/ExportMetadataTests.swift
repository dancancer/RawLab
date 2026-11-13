import AppKit
import Foundation
import ImageIO

@main
struct ExportMetadataTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as! [CFString: Any]
    }

    static func decoded(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    static func pixels(_ url: URL) -> Data { decoded(url).dataProvider!.data! as Data }

    static func hasPNGEXIF(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        var offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            if String(data: data[offset+4..<offset+8], encoding: .ascii) == "eXIf" { return true }
            offset += length + 12
        }
        return false
    }

    static func image(bits: Int = 8) -> CGImage {
        var bytes = Data()
        for i in 0..<18 {
            let value = UInt16((i * 3547 + 123) % 65536)
            if bits == 16 { bytes.append(UInt8(value & 255)); bytes.append(UInt8(value >> 8)) }
            else { bytes.append(UInt8(value >> 8)) }
        }
        return CGImage(width: 3, height: 2, bitsPerComponent: bits, bitsPerPixel: 3 * bits,
                       bytesPerRow: 9 * bits / 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: bits == 16 ? .byteOrder16Little : CGBitmapInfo(rawValue: 0),
                       provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func encode(_ image: CGImage, to url: URL, type: CFString,
                       properties: [CFString: Any] = [:]) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        check(CGImageDestinationFinalize(destination), "Create image fixture")
    }

    static func verifyCapture(_ values: [CFString: Any], orientation: UInt32, width: Int, height: Int) {
        let exif = values[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let tiff = values[kCGImagePropertyTIFFDictionary] as! [CFString: Any]
        let gps = values[kCGImagePropertyGPSDictionary] as! [CFString: Any]
        check(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2021:03:04 05:06:07", "Original capture date is retained")
        check(abs((exif[kCGImagePropertyExifExposureTime] as! Double) - 0.008) < 1e-8,
              "Shutter speed is retained")
        check(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] == [400] &&
              abs((exif[kCGImagePropertyExifFNumber] as! Double) - 2.8) < 1e-6, "ISO and aperture are retained")
        check(exif[kCGImagePropertyExifLensModel] as? String == "Fixture 50mm" &&
              tiff[kCGImagePropertyTIFFMake] as? String == "Fixture Camera", "Camera and lens are retained")
        check(abs((gps[kCGImagePropertyGPSLatitude] as! Double) - 12.3) < 1e-6 &&
              gps[kCGImagePropertyGPSLatitudeRef] as? String == "N", "GPS metadata is retained")
        check(values[kCGImagePropertyOrientation] as? UInt32 == orientation,
              "Orientation matches the exported pixel orientation")
        check(exif[kCGImagePropertyExifPixelXDimension] as? Int == width &&
              exif[kCGImagePropertyExifPixelYDimension] as? Int == height &&
              exif[kCGImagePropertyExifColorSpace] as? Int == 1, "EXIF dimensions and color space describe the output")
        check(exif[kCGImagePropertyExifMakerNote] == nil && exif[kCGImagePropertyExifCFAPattern] == nil,
              "Sensor-only data and opaque MakerNotes are not copied")
    }

    static func syntheticChecks(in output: URL) throws {
        let original = output.appendingPathComponent("original.jpg")
        let fixture: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture Camera", kCGImagePropertyTIFFModel: "Fixture Model"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:03:04 05:06:07",
                kCGImagePropertyExifExposureTime: 0.008, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifLensModel: "Fixture 50mm"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.6, kCGImagePropertyGPSLongitudeRef: "E"]
        ]
        encode(image(), to: original, type: "public.jpeg" as CFString, properties: fixture)
        let originalBytes = try Data(contentsOf: original)
        for (suffix, type, bits) in [("jpg", "public.jpeg", 8), ("png", "public.png", 16)] {
            let destination = output.appendingPathComponent("metadata-copy.\(suffix)")
            encode(image(bits: bits), to: destination, type: type as CFString)
            let before = pixels(destination)
            try ExportMetadata.preserve(from: original, in: destination)
            verifyCapture(properties(destination), orientation: 1, width: 3, height: 2)
            check(pixels(destination) == before && decoded(destination).bitsPerComponent == bits,
                  "\(suffix) metadata attachment preserves decoded pixels and bit depth")
        }
        let jpeg = try ExportMetadata.jpegData(image: image(), sourceURL: original, orientation: .right, quality: 0.92)
        let jpegURL = output.appendingPathComponent("ios-encoder.jpg")
        try jpeg.write(to: jpegURL)
        verifyCapture(properties(jpegURL), orientation: 6, width: 3, height: 2)
        check(try Data(contentsOf: original) == originalBytes, "Source file is unchanged")
        do {
            try ExportMetadata.preserve(from: original, in: original)
            check(false, "Overwriting the metadata source must fail")
        } catch ExportMetadata.Failure.sameFile { print("PASS: Metadata source cannot be overwritten") }
        let unsupported = output.appendingPathComponent("unsupported.X3F")
        try Data("FOVb synthetic metadata-only source".utf8).write(to: unsupported)
        do {
            _ = try ExportMetadata.properties(from: unsupported, width: 3, height: 2, orientation: .up)
            check(false, "Unreadable source metadata requires an explicit fallback")
        } catch ExportMetadata.Failure.unreadableSource { print("PASS: Unreadable source metadata remains strict by default") }
        for (suffix, type, bits) in [("jpg", "public.jpeg", 8), ("png", "public.png", 16)] {
            let destination = output.appendingPathComponent("fallback.\(suffix)")
            encode(image(bits: bits), to: destination, type: type as CFString)
            let before = pixels(destination)
            try ExportMetadata.preserve(from: unsupported, in: destination, fallbackSourceProperties: [:])
            let values = properties(destination)
            let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any]
            check(pixels(destination) == before && decoded(destination).bitsPerComponent == bits,
                  "\(suffix) explicit metadata fallback preserves pixels and depth")
            check(exif?[kCGImagePropertyExifPixelXDimension] as? Int == 3 &&
                  exif?[kCGImagePropertyExifPixelYDimension] as? Int == 2 &&
                  exif?[kCGImagePropertyExifDateTimeOriginal] == nil,
                  "\(suffix) fallback records output dimensions without invented capture EXIF")
        }
        let plain = output.appendingPathComponent("no-exif.png")
        encode(image(), to: plain, type: "public.png" as CFString)
        let plainJPEG = try ExportMetadata.jpegData(image: image(), sourceURL: plain, orientation: .up, quality: 0.92)
        check(!plainJPEG.isEmpty, "Images without shooting EXIF can still be exported")
    }

    struct InjectedPreserveFailure: Error {}

    static func singlePhotoStagingChecks(in output: URL) throws {
        let stagingDir = output.appendingPathComponent("single-photo-staging-anchor")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let sourceImage = output.appendingPathComponent("original.jpg")

        for suffix in ["jpg", "png"] {
            let targetURL = stagingDir.appendingPathComponent("preexisting-target.\(suffix)")
            let oldContent = "OLD_TARGET_CONTENT_BEFORE_EXPORT_\(suffix)"
            let oldBytes = Data(oldContent.utf8)
            try oldBytes.write(to: targetURL)

            let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
            engine.metadataPreserver = { _, _, _ in
                throw InjectedPreserveFailure()
            }

            var didFail = false
            do {
                _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: targetURL)
            } catch is InjectedPreserveFailure {
                didFail = true
            }
            check(didFail, "\(suffix) single-photo export reports error when ExportMetadata.preserve fails")

            let currentBytes = try Data(contentsOf: targetURL)
            check(currentBytes == oldBytes, "\(suffix) pre-existing target file bytes remain intact after preserve failure")

            let dirEntries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            let leftovers = dirEntries.filter { $0.hasPrefix(".rawlab-") }
            check(leftovers.isEmpty, "\(suffix) no .rawlab-* staging files remain in destination directory after failure")

            // 成功导出路径：补写元数据成功时原子替换目标文件，旧字节更新且同目录无暂存残留
            engine.metadataPreserver = { source, destination, fallback in
                try ExportMetadata.preserve(from: source, in: destination, fallbackSourceProperties: fallback)
            }
            _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: targetURL)
            let updatedBytes = try Data(contentsOf: targetURL)
            check(updatedBytes != oldBytes && !updatedBytes.isEmpty, "\(suffix) target file is updated when export succeeds")
            // 源片 3×2、EXIF 方向 6：成片像素转正为 2×3，EXIF 尺寸描述转正后的成片
            verifyCapture(properties(targetURL), orientation: 1, width: 2, height: 3)
            let successEntries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            let successLeftovers = successEntries.filter { $0.hasPrefix(".rawlab-") }
            check(successLeftovers.isEmpty, "\(suffix) no .rawlab-* staging files remain after successful export")

            // 目标文件原本不存在时元数据注入失败：目标文件不被创建，且无暂存残留
            let nonExistentTarget = stagingDir.appendingPathComponent("non-existent-target.\(suffix)")
            engine.metadataPreserver = { _, _, _ in
                throw InjectedPreserveFailure()
            }
            var nonExistentFailed = false
            do {
                _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: nonExistentTarget)
            } catch is InjectedPreserveFailure {
                nonExistentFailed = true
            }
            check(nonExistentFailed, "\(suffix) export to non-existent target fails on metadata error")
            check(!FileManager.default.fileExists(atPath: nonExistentTarget.path), "\(suffix) non-existent target is not created on metadata failure")
            let nonExistentEntries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            let nonExistentLeftovers = nonExistentEntries.filter { $0.hasPrefix(".rawlab-") }
            check(nonExistentLeftovers.isEmpty, "\(suffix) no .rawlab-* staging files remain after failed non-existent target export")

            // Should-3 锚点：rename 发布覆盖已存在普通文件时保留目标 POSIX 权限位（对齐 #242/#261 核心契约）
            engine.metadataPreserver = { source, destination, fallback in
                try ExportMetadata.preserve(from: source, in: destination, fallbackSourceProperties: fallback)
            }
            let privateTarget = stagingDir.appendingPathComponent("private-target.\(suffix)")
            try Data("PRIVATE_TARGET_BEFORE_EXPORT".utf8).write(to: privateTarget)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateTarget.path)
            _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: privateTarget)
            let privateMode = try FileManager.default.attributesOfItem(atPath: privateTarget.path)[.posixPermissions] as? NSNumber
            check(privateMode.map { $0.int32Value & 0o777 } == 0o600,
                  "\(suffix) publishing over a 0600 target keeps its POSIX permission bits")

            // Should-3 锚点：目标为指向无关文件的符号链接时替换链接本身，不跟随写穿
            let linkBehind = stagingDir.appendingPathComponent("behind-link.\(suffix)")
            let linkBehindBytes = Data("LINK_BEHIND_BEFORE_EXPORT".utf8)
            try linkBehindBytes.write(to: linkBehind)
            let symlinkTarget = stagingDir.appendingPathComponent("symlink-target.\(suffix)")
            try FileManager.default.createSymbolicLink(at: symlinkTarget, withDestinationURL: linkBehind)
            _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: symlinkTarget)
            check(try Data(contentsOf: linkBehind) == linkBehindBytes,
                  "\(suffix) file behind an unrelated symlink is not written through by export")
            var symlinkInfo = stat()
            check(lstat(symlinkTarget.path, &symlinkInfo) == 0 && (symlinkInfo.st_mode & S_IFMT) == S_IFREG,
                  "\(suffix) export replaces the symlink itself instead of failing")

            // Should-3 锚点：悬空符号链接不再触发 moveItem 已存在冲突（旧 fileExists 分支缺陷）
            let danglingTarget = stagingDir.appendingPathComponent("dangling-target.\(suffix)")
            try FileManager.default.createSymbolicLink(at: danglingTarget,
                                                       withDestinationURL: stagingDir.appendingPathComponent("missing-behind.\(suffix)"))
            _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: danglingTarget)
            var danglingInfo = stat()
            check(lstat(danglingTarget.path, &danglingInfo) == 0 && (danglingInfo.st_mode & S_IFMT) == S_IFREG,
                  "\(suffix) dangling symlink target publishes as a regular file")

            // Note-5 锚点：替换发布失败（目标是已存在目录）时报既有 outputIO 错误且无 .rawlab-* 残留
            let occupiedDir = stagingDir.appendingPathComponent("occupied-dir.\(suffix)")
            try FileManager.default.createDirectory(at: occupiedDir, withIntermediateDirectories: false)
            var publishFailed = false
            do {
                _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: occupiedDir)
            } catch let error as RenderError {
                publishFailed = true
                check(error.localizedDescription == "无法写入成片，请检查输出位置和剩余空间。",
                      "\(suffix) publish failure reports the dedicated output storage error")
            }
            check(publishFailed, "\(suffix) exporting onto an existing directory fails instead of silently succeeding")
            let occupiedEntries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            check(occupiedEntries.filter { $0.hasPrefix(".rawlab-") }.isEmpty,
                  "\(suffix) no .rawlab-* staging files remain after publish failure")
        }

        // Must-1 锚点：目标已存在且与原片是同一文件（含硬链接别名）时，导出被覆盖保护拒绝，
        // 绝不静默替换损毁原片（暂存重定向不得击穿核心的「不能覆盖原始文件」语义）。
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let sourceBytes = try Data(contentsOf: sourceImage)
        for (label, output) in [("same file", sourceImage),
                                ("hardlink alias", stagingDir.appendingPathComponent("source-alias.jpg"))] {
            if label == "hardlink alias" {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.linkItem(at: sourceImage, to: output)
            }
            var rejected = false
            do {
                _ = try engine.render(sourceImage, settings: Adjustments(), lut: nil, edge: nil, output: output)
            } catch let error as RenderError {
                rejected = true
                check(error.localizedDescription == "不能覆盖原始文件。",
                      "\(label) exporting onto the original file reports the dedicated overwrite protection error")
            }
            check(rejected, "\(label) export onto the original file is rejected instead of silently overwriting")
            check(try Data(contentsOf: sourceImage) == sourceBytes,
                  "\(label) rejected export keeps the original bytes unchanged")
            let rejectEntries = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            check(rejectEntries.filter { $0.hasPrefix(".rawlab-") }.isEmpty,
                  "\(label) rejected export leaves no .rawlab-* staging files")
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try syntheticChecks(in: output)
        try singlePhotoStagingChecks(in: output)
        if let fixture = ProcessInfo.processInfo.environment["RAWLAB_TEST_METADATA_RAW"] {
            try unreadableRAWChecks(URL(fileURLWithPath: fixture), output: output)
        } else {
            print("SKIP: set RAWLAB_TEST_METADATA_RAW to verify an extensionless RAW with unreadable ImageIO metadata")
        }
        // 防空跑：缺样片是显式失败而不是 exit 0 的静默 SKIP（docs/process/ci.md：SKIP 记为门禁失败）。
        let raw = ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"].map { URL(fileURLWithPath: $0) } ??
            root.appendingPathComponent("lutools/examples/DSC06251.ARW")
        guard FileManager.default.fileExists(atPath: raw.path) else {
            fputs("FAIL: RAW export fixture not found: \(raw.path) — set RAWLAB_TEST_RAW to an external RAW sample\n", stderr)
            exit(1)
        }
        let original = properties(raw)
        let originalEXIF = original[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        let jpeg = output.appendingPathComponent("capture.jpg")
        _ = try engine.render(raw, settings: Adjustments(), lut: nil, edge: nil, output: jpeg, exportLongEdge: 400)
        let exported = properties(jpeg)
        check(max(decoded(jpeg).width, decoded(jpeg).height) == 400, "Final RAW export honors the chosen long-edge limit")
        let exif = exported[kCGImagePropertyExifDictionary] as? [CFString: Any]
        check(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == originalEXIF[kCGImagePropertyExifDateTimeOriginal] as? String,
              "Mac JPEG export retains the actual RAW capture timestamp")
        check(exported[kCGImagePropertyOrientation] as? Int == 1, "RAW pixels are upright without double rotation")
        check(exif?[kCGImagePropertyExifPixelXDimension] as? Int == decoded(jpeg).width &&
              exif?[kCGImagePropertyExifPixelYDimension] as? Int == decoded(jpeg).height,
              "RAW export dimensions reflect crop, rotation and resize")
        let png = output.appendingPathComponent("capture.png")
        _ = try engine.render(raw, settings: Adjustments(), lut: nil, edge: nil, output: png, exportLongEdge: 400)
        let pngEXIF = properties(png)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        check(decoded(png).bitsPerComponent == 16 &&
              pngEXIF?[kCGImagePropertyExifDateTimeOriginal] as? String == originalEXIF[kCGImagePropertyExifDateTimeOriginal] as? String,
              "Mac PNG exports preserve sixteen-bit pixels and RAW capture EXIF")
        check(try hasPNGEXIF(png), "Core-generated PNG contains actual eXIf, not only XMP projection")
    }

    static func unreadableRAWChecks(_ fixture: URL, output: URL) throws {
        let input = output.appendingPathComponent("raw-without-extension")
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: fixture)
        let original = try Data(contentsOf: fixture)
        let source = CGImageSourceCreateWithURL(input as CFURL, nil)
        check(source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } == nil,
              "Extensionless RAW reproduces unavailable ImageIO source properties")
        let engine = try RenderEngine(gpuMode: SONY2FUJI_GPU_OFF)
        for suffix in ["jpg", "png"] {
            let destination = output.appendingPathComponent("raw-fallback.\(suffix)")
            _ = try engine.render(input, settings: Adjustments(), lut: nil, edge: nil, output: destination, exportLongEdge: 400)
            let values = properties(destination)
            let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let rendered = decoded(destination)
            if suffix == "png" { check(rendered.bitsPerComponent == 16, "RAW metadata fallback retains sixteen-bit PNG output") }
            check(max(rendered.width, rendered.height) == 400 && values[kCGImagePropertyOrientation] as? Int == 1,
                  "\(suffix) exports decoded RAW with output dimensions and upright orientation")
            check(exif?[kCGImagePropertyExifPixelXDimension] as? Int == rendered.width &&
                  exif?[kCGImagePropertyExifPixelYDimension] as? Int == rendered.height &&
                  exif?[kCGImagePropertyExifDateTimeOriginal] == nil && exif?[kCGImagePropertyExifISOSpeedRatings] == nil,
                  "\(suffix) fallback writes output EXIF without invented capture data")
        }
        check(try Data(contentsOf: fixture) == original, "Metadata fallback never modifies the RAW fixture")
    }
}
