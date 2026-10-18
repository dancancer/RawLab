import Foundation
import ImageIO
import UIKit

@main
struct ProcessorExportTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let lensDatabase = root.appendingPathComponent("lutools/third_party/lensfun/version_1")
        let processor = Sony2FujiProcessor(lensDatabaseURL: lensDatabase)
        checkProcessorErrorMapping(processor)
        let cpuProcessor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF, lensDatabaseURL: lensDatabase)
        let forcedProcessor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_FORCE, lensDatabaseURL: lensDatabase)
        var random: UInt32 = 8171
        var noisy = Data(count: 256 * 256 * 4)
        for i in 0..<(256 * 256) {
            for c in 0..<3 {
                random = random &* 1664525 &+ 1013904223
                noisy[i * 4 + c] = UInt8(108 + Int(random >> 24) % 40)
            }
            noisy[i * 4 + 3] = 255
        }
        let noiseBuffer = Sony2FujiProcessor.Buffer(data: noisy, width: 256, height: 256, stride: 1024,
                                                   pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .legacy)
        let limited = try processor.processBuffer(buffer: noiseBuffer, settings: .default,
                                                   previewLongEdge: nil, lutURL: nil,
                                                   exportLongEdge: 64)
        check(limited.width == 64 && limited.height == 64,
              "iOS final buffer export applies the requested long-edge cap")
        let capped = try processor.processBuffer(buffer: noiseBuffer, settings: .default,
                                                  previewLongEdge: nil, lutURL: nil,
                                                  exportLongEdge: 512)
        check(capped.width == noiseBuffer.width && capped.height == noiseBuffer.height,
              "iOS final export never enlarges a small buffer")
        let finalWinsOverPreview = try processor.processBuffer(buffer: noiseBuffer, settings: .default,
                                                                previewLongEdge: 128, lutURL: nil,
                                                                interactive: true, exportLongEdge: 64)
        check(finalWinsOverPreview.width == 64 && finalWinsOverPreview.height == 64,
              "iOS export size stays FINAL and separate from the preview edge")
        let dngURL = output.appendingPathComponent("buffer.dng")
        try processor.exportDNG(buffer: noiseBuffer, settings: .default, lutURL: nil,
                                outputURL: dngURL, exportLongEdge: 64)
        check(FileManager.default.fileExists(atPath: dngURL.path),
              "iOS DNG export writes directly to the requested file")
        check(CGImageSourceCreateWithURL(dngURL as CFURL, nil) != nil,
              "iOS DNG export is a readable TIFF/DNG file")
        let unwritableDNGURL = output.appendingPathComponent("missing-directory/fail.dng")
        do {
            try processor.exportDNG(buffer: noiseBuffer, settings: .default, lutURL: nil,
                                    outputURL: unwritableDNGURL, exportLongEdge: 64)
            check(false, "DNG output failure is surfaced as a storage error")
        } catch let error as Sony2FujiProcessor.ProcessorError {
            if case .outputIO = error {
                check(true, "DNG output failure is surfaced as a storage error")
            } else {
                check(false, "DNG output failure is surfaced as a storage error")
            }
        }
        let missingRawURL = output.appendingPathComponent("missing-source.ARW")
        do {
            try processor.exportDNG(url: missingRawURL, settings: .default, lutURL: nil,
                                    outputURL: output.appendingPathComponent("missing-source.dng"), exportLongEdge: 64)
            check(false, "missing RAW is not classified as a global output failure")
        } catch let error as Sony2FujiProcessor.ProcessorError {
            if case .outputIO = error {
                check(false, "missing RAW is not classified as a global output failure")
            } else {
                check(true, "missing RAW is not classified as a global output failure")
            }
        }
        let rasterURL = output.appendingPathComponent("oriented.jpg")
        try writeOrientedRaster(to: rasterURL)
        let raster = try processor.loadRasterBuffer(url: rasterURL)
        let oriented = try processor.loadRasterBuffer(url: rasterURL, applyingOrientation: true)
        check(raster.orientation == .up && raster.buffer.width == 3 && raster.buffer.height == 2,
              "raster import applies source EXIF orientation in the shared decoder")
        check(oriented.orientation == .up && oriented.buffer.width == raster.buffer.width &&
                  oriented.buffer.height == raster.buffer.height && oriented.buffer.data == raster.buffer.data,
              "raster preview and FINAL load apply EXIF orientation exactly once")
        let invalidRasterURL = output.appendingPathComponent("invalid-raster.bin")
        try Data("not an image".utf8).write(to: invalidRasterURL)
        do {
            _ = try processor.loadRasterBuffer(url: invalidRasterURL)
            check(false, "raster loader rejects unsupported file contents")
        } catch { check(true, "raster loader rejects unsupported file contents") }
        let noiseOff = try processor.processBuffer(buffer: noiseBuffer, settings: .default, previewLongEdge: 128, lutURL: nil)
        var denoised = RawSettings.default
        denoised.denoise.apply(.clean)
        let noiseOn = try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 128, lutURL: nil)
        check(noiseOff.data != noiseOn.data, "iOS settings reach native wavelet processing")
        let noiseProxy = try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 96, lutURL: nil, interactive: true)
        let noiseExact = try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 128, lutURL: nil)
        check(noiseExact.data == noiseOn.data, "iOS interactive approximation never changes exact output")
        denoised.denoise.enabled = false
        check(try processor.processBuffer(buffer: noiseBuffer, settings: denoised, previewLongEdge: 128, lutURL: nil).data == noiseOff.data,
              "iOS disabling denoise restores the original output")
        var effects = RawSettings.default
        effects.photoEffects.vignetteAmount = -65
        effects.photoEffects.vignetteMidpoint = 52
        effects.photoEffects.vignetteRoundness = -35
        effects.photoEffects.vignetteFeather = 70
        effects.photoEffects.vignetteHighlights = 75
        effects.photoEffects.grainAmount = 70
        effects.photoEffects.grainSize = 60
        effects.photoEffects.grainRoughness = 80
        let effectsOn = try processor.processBuffer(buffer: noiseBuffer, settings: effects,
                                                     previewLongEdge: 128, lutURL: nil)
        check(effectsOn.data != noiseOff.data, "iOS photo effects reach native vignette and grain processing")
        let effectsCPU = try cpuProcessor.processBuffer(buffer: noiseBuffer, settings: effects,
                                                         previewLongEdge: 128, lutURL: nil)
        check(Self.maximumDifference(effectsOn.data, effectsCPU.data) <= 2,
              "iOS Auto/CPU photo effects remain within two code values")
        let effectsExport = try processor.processBuffer(buffer: noiseBuffer, settings: effects,
                                                        previewLongEdge: nil, lutURL: nil,
                                                        exportLongEdge: 64)
        check(effectsExport.width == 64 && effectsExport.height == 64,
              "iOS photo effects survive final export resizing")
        var chroma = RawSettings.default
        chroma.displayChromaDenoise = 1
        let chromaOn = try processor.processBuffer(buffer: noiseBuffer, settings: chroma,
                                                   previewLongEdge: 128, lutURL: nil)
        check(chromaOn.data != noiseOff.data, "iOS display chroma mode reaches native processing")
        var combined = effects
        combined.denoise.apply(.clean)
        combined.displayChromaDenoise = 2
        combined.sharpening = 0.5
        let combinedCPU = try cpuProcessor.processBuffer(buffer: noiseBuffer, settings: combined,
                                                           previewLongEdge: nil, lutURL: nil, exportLongEdge: 64)
        let combinedGPU = try forcedProcessor.processBuffer(buffer: noiseBuffer, settings: combined,
                                                              previewLongEdge: nil, lutURL: nil, exportLongEdge: 64)
        check(Self.maximumDifference(combinedCPU.data, combinedGPU.data) <= 2,
              "iOS forced Metal combined effects, wavelet, chroma and detail match CPU")
        let combinedAgain = try forcedProcessor.processBuffer(buffer: noiseBuffer, settings: combined,
                                                                previewLongEdge: nil, lutURL: nil, exportLongEdge: 64)
        check(combinedAgain.data == combinedGPU.data, "iOS GPU grain is deterministic")
        let scroll = PhotoScrollView()
        scroll.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        scroll.pixels = CGSize(width: 2400, height: 1600)
        scroll.displayScale = 2
        scroll.imageView.image = UIImage(cgImage: processor.makeCGImage(from: noiseOff)!)
        scroll.layoutIfNeeded()
        check(abs(scroll.imageView.bounds.width - 1200) < 0.01, "iOS geometry starts in display points")
        scroll.displayScale = 3
        scroll.setNeedsLayout()
        scroll.layoutIfNeeded()
        check(abs(scroll.imageView.bounds.width - 800) < 0.01,
              "iOS display density change rebuilds geometry without a bounds change")
        scroll.setZoomScale(1, animated: false)
        scroll.setContentOffset(CGPoint(x: 100, y: 80), animated: false)
        let originalOffset = scroll.contentOffset
        for frame in [noiseProxy, noiseExact] {
            scroll.imageView.image = UIImage(cgImage: processor.makeCGImage(from: frame)!)
            scroll.setNeedsLayout()
            scroll.layoutIfNeeded()
            check(scroll.zoomScale == 1 && scroll.contentOffset == originalOffset,
                  "iOS denoise frame replacement preserves native zoom and pan")
        }
        let bytes = Data([45, 110, 180, 255, 170, 110, 60, 255, 85, 145, 75, 255,
                          80, 70, 65, 255, 180, 185, 190, 255, 210, 65, 115, 255])
        let buffer = Sony2FujiProcessor.Buffer(data: bytes, width: 3, height: 2, stride: 12,
                                              pixelFormat: SONY2FUJI_PIXEL_RGBA8, semantic: .legacy)
        let displayBuffer = buffer.withSemantic(.display)
        let original = output.appendingPathComponent("source.jpg")
        let destination = CGImageDestinationCreateWithURL(original as CFURL, "public.jpeg" as CFString, 1, nil)!
        let originalProperties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:03:04 05:06:07",
                kCGImagePropertyExifExposureTime: 0.008, kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifLensModel: "Fixture 50mm"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.6, kCGImagePropertyGPSLongitudeRef: "E"]
        ]
        CGImageDestinationAddImage(destination, processor.makeCGImage(from: buffer)!, originalProperties as CFDictionary)
        check(CGImageDestinationFinalize(destination), "Create simulator metadata fixture")
        let lut = root.appendingPathComponent("lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube")
        let normal = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: lut)
        var stronger = RawSettings.default
        stronger.lutStrength = 2
        let doubled = try processor.processBuffer(buffer: buffer, settings: stronger, previewLongEdge: nil, lutURL: lut)
        check(normal.data != doubled.data, "iOS buffer processing actually renders 200 percent differently from 100")
        var hsl = RawSettings.default
        for channel in 0..<8 { hsl.hsl.set(.saturation, channel: channel, value: -100) }
        let neutral = try processor.processBuffer(buffer: buffer, settings: .default, previewLongEdge: nil, lutURL: nil)
        let displayNeutral = try processor.processBuffer(buffer: displayBuffer, settings: .default,
                                                         previewLongEdge: nil, lutURL: nil)
        check(displayNeutral.data == displayBuffer.data,
              "iOS display-sRGB neutral rendering round-trips RGB8 pixels")
        var displaySettings = RawSettings.default
        displaySettings.exposure = 0.35
        displaySettings.contrast = 1.12
        displaySettings.saturation = 0.88
        displaySettings.hsl.set(.saturation, channel: 2, value: -35)
        displaySettings.denoise.apply(.detail)
        displaySettings.photoEffects.vignetteAmount = -35
        displaySettings.photoEffects.grainAmount = 18
        displaySettings.geometry.quarterTurns = 1
        displaySettings.geometry.cropX = 0.1
        displaySettings.geometry.cropWidth = 0.8
        let displayFinal = try processor.processBuffer(buffer: raster.buffer, settings: displaySettings,
                                                       previewLongEdge: nil, lutURL: nil)
        let displayCPU = try cpuProcessor.processBuffer(buffer: raster.buffer, settings: displaySettings,
                                                        previewLongEdge: nil, lutURL: nil)
        let displayRepeat = try processor.processBuffer(buffer: raster.buffer, settings: displaySettings,
                                                        previewLongEdge: nil, lutURL: nil)
        check(Self.maximumDifference(displayFinal.data, displayCPU.data) <= 2,
              "iOS display Auto falls back to the CPU reference for full edits")
        check(displayFinal.data == displayRepeat.data && displayFinal.width > 0 && displayFinal.height > 0,
              "iOS display FINAL is deterministic and applies geometry after source decode")
        do {
            _ = try forcedProcessor.processBuffer(buffer: displayBuffer, settings: .default,
                                                  previewLongEdge: nil, lutURL: nil)
            check(false, "iOS display input rejects Force GPU instead of changing semantics")
        } catch { check(true, "iOS display input rejects Force GPU instead of changing semantics") }
        let hslPreview = try processor.processBuffer(buffer: buffer, settings: hsl, previewLongEdge: 3, lutURL: nil)
        let hslExport = try processor.processBuffer(buffer: buffer, settings: hsl, previewLongEdge: nil, lutURL: nil)
        check(hslPreview.data == hslExport.data && hslExport.data != neutral.data,
              "iOS HSL reaches native processing with preview/export parity")
        let hslCPU = try cpuProcessor.processBuffer(buffer: buffer, settings: hsl, previewLongEdge: nil, lutURL: nil)
        let hslGPU = try forcedProcessor.processBuffer(buffer: buffer, settings: hsl, previewLongEdge: nil, lutURL: nil)
        check(Self.maximumDifference(hslGPU.data, hslCPU.data) <= 2,
              "iOS HSL Force succeeds on Metal and matches the CPU reference")
        let rasterEV = try processor.autoExposure(url: nil, buffer: displayBuffer, settings: .default)
        hsl.exposure = 3
        check(try processor.autoExposure(url: nil, buffer: displayBuffer, settings: hsl) == rasterEV && (-4...4).contains(rasterEV),
              "iOS raster Auto returns absolute EV independent of HSL and current exposure")
        let jpeg = try processor.makeJPEGData(from: doubled, sourceURL: original, orientation: .right, quality: 0.92)
        let fields = properties(jpeg)
        let exif = fields[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let gps = fields[kCGImagePropertyGPSDictionary] as! [CFString: Any]
        check(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2021:03:04 05:06:07" &&
              abs((exif[kCGImagePropertyExifExposureTime] as! Double) - 0.008) < 1e-8 &&
              exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] == [400], "iOS JPEG retains date, shutter and ISO")
        check(exif[kCGImagePropertyExifLensModel] as? String == "Fixture 50mm" &&
              abs((gps[kCGImagePropertyGPSLatitude] as! Double) - 12.3) < 1e-6, "iOS JPEG retains lens and GPS")
        check(fields[kCGImagePropertyOrientation] as? Int == 6 &&
              exif[kCGImagePropertyExifPixelXDimension] as? Int == 3 &&
              exif[kCGImagePropertyExifPixelYDimension] as? Int == 2,
              "Raster export keeps the orientation of unrotated buffer pixels")
        try jpeg.write(to: output.appendingPathComponent("ios-raster-exif.jpg"))
        let raw = ProcessInfo.processInfo.environment["RAWLAB_TEST_RAW"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("lutools/examples/DSC06251.ARW")
        guard FileManager.default.fileExists(atPath: raw.path) else {
            print("SKIP: RAW sample unavailable; buffer export checks above passed")
            return
        }
        try checkOriginalProtection(processor, raw: raw, output: output)
        let standardRaw = try processor.processRaw(url: raw, settings: .default, previewLongEdge: 128, lutURL: lut)
        let lensOff = try cpuProcessor.processRaw(url: raw, settings: .default, previewLongEdge: 180, lutURL: nil)
        var unselectedLens = RawSettings.default
        unselectedLens.lensCorrection = LensCorrectionSettings(distortion: true, mode: .manual)
        let unselected = try cpuProcessor.processRaw(url: raw, settings: unselectedLens, previewLongEdge: 180, lutURL: nil)
        check(unselected.lensInfo?.state == SONY2FUJI_LENS_NO_LENS && unselected.buffer.data == lensOff.buffer.data,
              "iOS manual mode without selection reports a skipped correction, never auto")
        guard let candidate = lensOff.lensInfo?.candidates.first(where: { $0.isMatch && $0.hasDistortion }) else {
            fatalError("Lens regression requires a RAW with a matching distortion calibration")
        }
        var lensSettings = RawSettings.default
        lensSettings.lensCorrection = LensCorrectionSettings(distortion: true, tca: true, mode: .manual, profileID: candidate.id)
        let lensOn = try cpuProcessor.processRaw(url: raw, settings: lensSettings, previewLongEdge: 180, lutURL: nil)
        check(lensOn.lensInfo?.appliedDistortion == true && lensOn.lensInfo?.appliedTCA == candidate.hasTCA,
              "iOS manual lens calibration reaches camera-channel processing")
        check(lensOn.buffer.width == lensOff.buffer.width && lensOn.buffer.height == lensOff.buffer.height && lensOn.buffer.data != lensOff.buffer.data,
              "iOS lens auto crop changes geometry while preserving output dimensions")
        let lensGpu = try forcedProcessor.processRaw(url: raw, settings: lensSettings, previewLongEdge: 180, lutURL: nil)
        check(maximumDifference(lensOn.buffer.data, lensGpu.buffer.data) <= 2, "iOS corrected RAW CPU/Force Metal parity")
        var lensAuto = lensSettings; lensAuto.lensCorrection?.mode = .automatic
        let autoLens = try cpuProcessor.processRaw(url: raw, settings: lensAuto, previewLongEdge: 180, lutURL: nil)
        if lensOff.lensInfo!.candidates.filter(\.isMatch).count == 1 {
            check(autoLens.buffer.data == lensOn.buffer.data, "iOS automatic and manual unique matching agree")
        } else { check(autoLens.lensInfo?.state == SONY2FUJI_LENS_AMBIGUOUS, "iOS automatic matching never guesses") }
        check(try cpuProcessor.processRaw(url: raw, settings: .default, previewLongEdge: 180, lutURL: nil).buffer.data == lensOff.buffer.data,
              "iOS lens reset restores exact baseline")
        lensSettings.applyMasterRecipe(MasterRecipe.allRecipes[0]); lensSettings.tint = 20
        var manualRecipe = lensSettings; manualRecipe.masterRecipeID = nil
        manualRecipe.temperature = lensOff.rawWhiteBalance!.temperature
        manualRecipe.tint = lensOff.rawWhiteBalance!.tint + 20; manualRecipe.whiteBalanceMode = .custom
        check(try cpuProcessor.autoExposure(url: raw, buffer: nil, settings: lensSettings) ==
              cpuProcessor.autoExposure(url: raw, buffer: nil, settings: manualRecipe),
              "iOS automatic exposure restores lens correction after recipe neutral processing")
        if ProcessInfo.processInfo.environment["RAWLAB_TEST_MASTER_RECIPES"] == "1" {
            let neutral = try cpuProcessor.processRaw(url: raw, settings: .default, previewLongEdge: 128, lutURL: nil)
            let camera = neutral.rawWhiteBalance!
            for recipe in MasterRecipe.allRecipes {
                let recipeLut = root.appendingPathComponent("RawLabMac/Resources/MasterRecipes/\(recipe.lutFileName)")
                for strength in [0.0, 0.5, 1.0, 2.0] {
                    var current = RawSettings.default
                    current.applyMasterRecipe(recipe); current.lutStrength = strength
                    current.hsl.set(.hue, channel: 7, value: 37)
                    var manual = current
                    manual.masterRecipeID = nil
                    manual.exposure *= strength; manual.highlights *= strength; manual.shadows *= strength
                    manual.contrast = 1 + (current.contrast - 1) * strength
                    manual.saturation = 1 + (current.saturation - 1) * strength
                    manual.hsl = current.hsl.scaled(by: strength)
                    manual.temperature = camera.temperature; manual.tint = min(150, max(-150, camera.tint + current.tint * strength))
                    manual.whiteBalanceMode = strength == 0 ? .camera : .custom
                    let actual = try cpuProcessor.processRaw(url: raw, settings: current, previewLongEdge: 128, lutURL: recipeLut)
                    let expected = try cpuProcessor.processRaw(url: raw, settings: manual, previewLongEdge: 128, lutURL: recipeLut)
                    check(actual.buffer.data == expected.buffer.data, "\(recipe.id) \(strength): explicit manual RAW parity")
                    let gpu = try forcedProcessor.processRaw(url: raw, settings: current, previewLongEdge: 128, lutURL: recipeLut)
                    check(maximumDifference(actual.buffer.data, gpu.buffer.data) <= 2, "\(recipe.id): CPU/Force Metal parity")
                    if strength == 0 { check(actual.buffer.data == neutral.buffer.data, "\(recipe.id): zero is neutral") }
                    let frozen = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(current))
                    let final = try cpuProcessor.processRaw(url: raw, settings: frozen, previewLongEdge: nil, lutURL: recipeLut, exportLongEdge: 128)
                    let single = try cpuProcessor.processRaw(url: raw, settings: current, previewLongEdge: nil, lutURL: recipeLut, exportLongEdge: 128)
                    check(final.buffer.data == single.buffer.data, "\(recipe.id): frozen settings match single final export")
                }
            }
        }
        let rawEV = try processor.autoExposure(url: raw, buffer: nil, settings: .default)
        var autoSettings = RawSettings.default
        autoSettings.exposure = rawEV
        check(try processor.autoExposure(url: raw, buffer: nil, settings: autoSettings) == rawEV && (-4...4).contains(rawEV),
              "iOS RAW Auto returns a bounded idempotent exposure")
        hsl.exposure = 0
        let hslRaw = try processor.processRaw(url: raw, settings: hsl, previewLongEdge: nil, lutURL: lut, exportLongEdge: 128)
        check(max(hslRaw.buffer.width, hslRaw.buffer.height) <= 128,
              "iOS HSL final RAW export honors the requested size")
        let strongRaw = try processor.processRaw(url: raw, settings: stronger, previewLongEdge: 128, lutURL: lut)
        check(standardRaw.buffer.data != strongRaw.buffer.data, "iOS RAW processing also passes through 200 percent")
        var rawDNGSettings = combined
        rawDNGSettings.whiteBalanceMode = .custom
        rawDNGSettings.temperature = 5300
        rawDNGSettings.tint = 12
        rawDNGSettings.exposure = -0.25
        rawDNGSettings.contrast = 1.18
        rawDNGSettings.highlights = -0.18
        rawDNGSettings.shadows = 0.2
        rawDNGSettings.toneCurve = 0.2
        rawDNGSettings.saturation = 1.12
        rawDNGSettings.lutStrength = 0.65
        rawDNGSettings.hsl.set(.hue, channel: 3, value: 18)
        let rawDNGURL = output.appendingPathComponent("ios-raw-rendered.dng")
        try cpuProcessor.exportDNG(url: raw, settings: rawDNGSettings, lutURL: lut,
                                   outputURL: rawDNGURL, exportLongEdge: 128)
        try forcedProcessor.exportDNG(url: raw, settings: rawDNGSettings, lutURL: lut,
                                      outputURL: output.appendingPathComponent("ios-raw-metal.dng"), exportLongEdge: 128)
        if let dngSource = CGImageSourceCreateWithURL(rawDNGURL as CFURL, nil),
           let dngProperties = CGImageSourceCopyPropertiesAtIndex(dngSource, 0, nil) as? [CFString: Any],
           let dng = dngProperties[kCGImagePropertyDNGDictionary] as? [CFString: Any],
           let crop = dng[kCGImagePropertyDNGDefaultCropSize] as? [NSNumber], crop.count >= 2 {
            check(FileManager.default.fileExists(atPath: rawDNGURL.path),
                  "iOS actual RAW DNG export writes the requested file")
            let dngWidth = crop[0].intValue
            let dngHeight = crop[1].intValue
            check(max(dngWidth, dngHeight) == 128 && min(dngWidth, dngHeight) > 0,
                  "iOS actual RAW DNG export honors the final long-edge size")
            check((dngProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1,
                  "iOS actual RAW DNG export is physically upright")
        } else {
            check(false, "iOS actual RAW DNG export is readable by ImageIO")
        }
        let rawFinalCPU = try cpuProcessor.processRaw(url: raw, settings: rawDNGSettings,
                                                       previewLongEdge: nil, lutURL: lut,
                                                       exportLongEdge: 128)
        try rawFinalCPU.buffer.data.write(to: output.appendingPathComponent("ios-raw-reference.rgba"))
        let rawFinalForce = try forcedProcessor.processRaw(url: raw, settings: rawDNGSettings,
                                                            previewLongEdge: nil, lutURL: lut,
                                                            exportLongEdge: 128)
        check(Self.maximumDifference(rawFinalCPU.buffer.data, rawFinalForce.buffer.data) <= 2,
              "iOS actual RAW final CPU and Force Metal output stay within two code values")
        var cameraTemperature = RawSettings.default
        cameraTemperature.temperature = 3000
        cameraTemperature.tint = 80
        let camera = try processor.processRaw(url: raw, settings: cameraTemperature, previewLongEdge: 128, lutURL: lut)
        var customTemperature = cameraTemperature
        customTemperature.whiteBalanceMode = .custom
        let custom = try processor.processRaw(url: raw, settings: customTemperature, previewLongEdge: 128, lutURL: lut)
        let cameraNeutral = try processor.processRaw(url: raw, settings: .default, previewLongEdge: 128, lutURL: lut)
        check(camera.buffer.data == cameraNeutral.buffer.data,
              "Camera RAW keeps neutral post-demosaic WB values")
        check(custom.buffer.data != cameraNeutral.buffer.data,
              "Custom RAW temperature uses the pre-demosaic Kelvin request")
        check(camera.rawWhiteBalance?.isCalibrated == true && (camera.rawWhiteBalance?.temperature ?? 0) > 0,
              "iOS RAW processing returns calibrated as-shot WB metadata")
        let limitedRaw = try processor.processRaw(url: raw, settings: .default, previewLongEdge: nil,
                                                  lutURL: lut, exportLongEdge: 128)
        check(max(limitedRaw.buffer.width, limitedRaw.buffer.height) <= 128,
              "iOS RAW final export honors the long-edge cap")
        check(hslRaw.buffer.data != limitedRaw.buffer.data,
              "iOS HSL changes actual final RAW export pixels")
        let hslRawCPU = try cpuProcessor.processRaw(url: raw, settings: hsl, previewLongEdge: nil, lutURL: lut, exportLongEdge: 128)
        let hslRawGPU = try forcedProcessor.processRaw(url: raw, settings: hsl, previewLongEdge: nil, lutURL: lut, exportLongEdge: 128)
        check(Self.maximumDifference(hslRawGPU.buffer.data, hslRawCPU.buffer.data) <= 2,
              "iOS HSL final RAW export uses Force Metal with CPU parity")
        var viewportSettings = RawSettings.default
        viewportSettings.denoise.apply(.clean)
        let denoiseRaw = ProcessInfo.processInfo.environment["RAWLAB_TEST_DENOISE_RAW"].map { URL(fileURLWithPath: $0) } ?? raw
        _ = try processor.processRaw(url: denoiseRaw, settings: viewportSettings, previewLongEdge: 512,
                                     lutURL: lut, viewportPreview: true)
        viewportSettings.exposure = 0.35
        _ = try processor.processRaw(url: denoiseRaw, settings: viewportSettings, previewLongEdge: 768,
                                     lutURL: lut, interactive: true, viewportPreview: true)
        let nativeDenoise = try processor.processRaw(url: denoiseRaw, settings: viewportSettings, previewLongEdge: nil,
                                                    lutURL: lut, interactive: true, viewportPreview: true)
        var withoutDenoise = viewportSettings
        withoutDenoise.denoise.enabled = false
        let nativeOff = try processor.processRaw(url: denoiseRaw, settings: withoutDenoise, previewLongEdge: nil, lutURL: lut)
        check(nativeDenoise.buffer.data != nativeOff.buffer.data, "iOS native export fixture actually applies denoise")
        let freshDenoise = try Sony2FujiProcessor().processRaw(url: denoiseRaw, settings: viewportSettings,
                                                             previewLongEdge: nil, lutURL: lut)
        let dimensions = denoiseRaw.path.withCString { rawlab_get_raw_dimensions($0) }
        check(nativeDenoise.buffer.width == Int(dimensions.width) && nativeDenoise.buffer.height == Int(dimensions.height),
              "iOS denoise export after viewport resize remains native size")
        check(nativeDenoise.buffer.data == freshDenoise.buffer.data,
              "iOS native denoise export never reuses viewport pixels")
        let nativeJPEG = try processor.makeJPEGData(from: nativeDenoise.buffer, sourceURL: denoiseRaw,
                                                    orientation: nativeDenoise.orientation, quality: 0.92)
        let freshJPEG = try processor.makeJPEGData(from: freshDenoise.buffer, sourceURL: denoiseRaw,
                                                   orientation: freshDenoise.orientation, quality: 0.92)
        check(nativeJPEG == freshJPEG, "iOS native JPEG matches independent FINAL processing")
        try nativeJPEG.write(to: output.appendingPathComponent("ios-denoised-native.jpg"))
        let rawJPEG = try processor.makeJPEGData(from: strongRaw.buffer, sourceURL: raw,
                                                orientation: strongRaw.orientation, quality: 0.92)
        let rawFields = properties(rawJPEG)
        let rawEXIF = rawFields[kCGImagePropertyExifDictionary] as! [CFString: Any]
        let originalRaw = CGImageSourceCreateWithURL(raw as CFURL, nil)!
        let rawSourceFields = CGImageSourceCopyPropertiesAtIndex(originalRaw, 0, nil)! as! [CFString: Any]
        let sourceEXIF = rawSourceFields[kCGImagePropertyExifDictionary] as! [CFString: Any]
        check(rawEXIF[kCGImagePropertyExifDateTimeOriginal] as? String == sourceEXIF[kCGImagePropertyExifDateTimeOriginal] as? String,
              "Actual iOS RAW export retains its source capture date")
        check(rawFields[kCGImagePropertyOrientation] as? Int == 1 &&
              rawEXIF[kCGImagePropertyExifPixelXDimension] as? Int == strongRaw.buffer.width &&
              rawEXIF[kCGImagePropertyExifPixelYDimension] as? Int == strongRaw.buffer.height,
              "iOS RAW export is upright and reports rendered dimensions")
        try rawJPEG.write(to: output.appendingPathComponent("ios-raw-exif.jpg"))
    }
}
