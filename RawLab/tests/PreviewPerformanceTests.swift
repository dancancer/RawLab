import Darwin
import Foundation
import ImageIO
import UIKit

@main
struct PreviewPerformanceTests {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else {
                throw Failure.message("Usage: preview-performance root raw-path output-dir")
            }
            let heartbeat = Heartbeat()
            let runner = try Runner(root: URL(fileURLWithPath: CommandLine.arguments[1]),
                                    raw: URL(fileURLWithPath: CommandLine.arguments[2]),
                                    output: URL(fileURLWithPath: CommandLine.arguments[3]), heartbeat: heartbeat)
            let completed = DispatchSemaphore(value: 0)
            var failure: Error?
            let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in heartbeat.tick() }
            DispatchQueue(label: "rawlab.tests.preview-performance").async {
                do { try runner.execute() } catch { failure = error }
                completed.signal()
            }
            while completed.wait(timeout: .now()) != .success {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            timer.invalidate()
            if let failure { throw failure }
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    enum Failure: Error { case message(String), expected }

    final class Heartbeat {
        private let lock = NSLock()
        private var last = DispatchTime.now().uptimeNanoseconds
        private var maximum: UInt64 = 0
        private var ticks = 0

        func begin() {
            lock.lock(); defer { lock.unlock() }
            last = DispatchTime.now().uptimeNanoseconds; maximum = 0; ticks = 0
        }

        func tick() {
            lock.lock(); defer { lock.unlock() }
            let now = DispatchTime.now().uptimeNanoseconds
            maximum = max(maximum, now - last); last = now; ticks += 1
        }

        func snapshot() -> (maximumMs: Double, count: Int) {
            lock.lock(); defer { lock.unlock() }
            let gap = max(maximum, DispatchTime.now().uptimeNanoseconds - last)
            return (Double(gap) / 1_000_000, ticks)
        }
    }

    final class Runner {
        let root: URL
        let raw: URL
        let output: URL
        let reference: URL?
        let log: FileHandle
        let heartbeat: Heartbeat
        var failures = 0

        init(root: URL, raw: URL, output: URL, heartbeat: Heartbeat) throws {
            self.root = root; self.raw = raw; self.output = output
            self.heartbeat = heartbeat
            reference = ProcessInfo.processInfo.environment["RAWLAB_PERFORMANCE_REFERENCE"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            let logURL = output.appendingPathComponent("metrics.jsonl")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
        }

        deinit { try? log.close() }

        func emit(_ record: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            try log.write(contentsOf: data)
            FileHandle.standardOutput.write(data)
        }

        func check(_ condition: Bool, _ name: String) throws {
            if !condition { failures += 1 }
            try emit(["type": "check", "name": name, "passed": condition])
        }

        func execute() throws {
            try fixtureMetadata()
            #if RAWLAB_RECIPE_CACHE_TESTS
            try cacheInvariants()
            #endif
            let copied = output.appendingPathComponent("copied-source.\(raw.pathExtension)")
            guard !FileManager.default.fileExists(atPath: copied.path) else {
                throw Failure.message("Copied fixture path already exists; use a new output directory")
            }
            try FileManager.default.copyItem(at: raw, to: copied)
            defer { try? FileManager.default.removeItem(at: copied) }
            for (name, mode) in [("cpu", SONY2FUJI_GPU_OFF), ("metal-force", SONY2FUJI_GPU_FORCE)] {
                try autoreleasepool { try runMode(name, mode, copied: copied) }
            }
            try emit(["type": "summary", "failures": failures,
                      "residentMeasurements": "before/after snapshots, not peak resident memory",
                      "mainHeartbeatScope": "serial background processor harness, not the SwiftUI app",
                      "platform": "iOS simulator; does not establish physical-device timing"])
            if failures != 0 { throw Failure.message("\(failures) regression checks failed; see metrics.jsonl") }
        }

        func fixtureMetadata() throws {
            guard let source = CGImageSourceCreateWithURL(raw as CFURL, nil),
                  let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                throw Failure.message("ImageIO metadata unavailable for fixture")
            }
            let tiff = fields[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = fields[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let native = raw.path.withCString { rawlab_get_raw_dimensions($0) }
            let file = try raw.resourceValues(forKeys: [.fileSizeKey])
            try emit(["type": "fixture", "file": raw.lastPathComponent,
                      "fileBytes": file.fileSize as Any? ?? NSNull(),
                      "make": tiff[kCGImagePropertyTIFFMake] ?? NSNull(),
                      "model": tiff[kCGImagePropertyTIFFModel] ?? NSNull(),
                      "librawInitialActiveWidth": native.width, "librawInitialActiveHeight": native.height,
                      "dimensionNote": "LibRaw identification dimensions before processing/crop; rendered source dimensions appear per case",
                      "imageIOWidth": fields[kCGImagePropertyPixelWidth] ?? NSNull(),
                      "imageIOHeight": fields[kCGImagePropertyPixelHeight] ?? NSNull(),
                      "imageIOFormat": CGImageSourceGetType(source).map { $0 as String } ?? "unknown",
                      "imageIOCompression": ["topLevel": fields["Compression" as CFString] ?? NSNull(),
                          "tiff": tiff[kCGImagePropertyTIFFCompression] ?? NSNull(),
                          "exifBitsPerPixel": exif[kCGImagePropertyExifCompressedBitsPerPixel] ?? NSNull()],
                      "system": ProcessInfo.processInfo.operatingSystemVersionString,
                      "processorSourceRoot": ProcessInfo.processInfo.environment["RAWLAB_PROCESSOR_SOURCE_ROOT"] ?? "unknown",
                      "previewLongEdge": 1280, "viewportPreview": true, "finalLongEdgeCap": 1280])
        }

        func runMode(_ name: String, _ mode: sony2fuji_gpu_mode, copied: URL) throws {
            let processor = makeProcessor(mode)
            guard let camera = try run("cold-neutral", mode: name, processor: processor, settings: .default),
                  camera.isCalibrated else { throw Failure.message("Fixture must provide calibrated camera WB") }
            for (index, exposure) in [0.2, 0.4, 0.6].enumerated() {
                var settings = RawSettings.default; settings.exposure = exposure
                _ = try run("warm-exposure-\(index + 1)", mode: name, processor: processor, settings: settings)
            }
            let recipe = MasterRecipe.allRecipes[0]
            let lut = root.appendingPathComponent("RawLabMac/Resources/MasterRecipes/\(recipe.lutFileName)")
            guard FileManager.default.fileExists(atPath: lut.path) else { throw Failure.message("Missing recipe LUT") }
            var settings = RawSettings.default
            settings.applyMasterRecipe(recipe); settings.tint = 20; settings.lutStrength = 0.65
            for index in 1...3 {
                settings.exposure = recipe.exposureDelta + Double(index) * 0.2
                _ = try run("recipe-tint20-ev-\(index)", mode: name, processor: processor, settings: settings, lut: lut)
            }
            settings.lutStrength = 1.15
            _ = try run("recipe-strength-change", mode: name, processor: processor, settings: settings, lut: lut)
            _ = try run("recipe-other-url", mode: name, processor: processor, settings: settings, lut: lut, source: copied)
            _ = try run("recipe-return-url", mode: name, processor: processor, settings: settings, lut: lut)
            settings.exposure += 0.2
            _ = try run("interactive-same-wb", mode: name, processor: processor, settings: settings, lut: lut, interactive: true)
            _ = try run("settled-preview", mode: name, processor: processor, settings: settings, lut: lut)
            _ = try run("release-final", mode: name, processor: processor, settings: settings, lut: lut,
                        interactive: true, final: true)
            let manual = manuallyRenderedRecipe(settings, camera: camera)
            _ = try run("manual-final", mode: name, processor: makeProcessor(mode), settings: manual, lut: lut, final: true)
            try check(try pixels(name, "release-final") == pixels(name, "manual-final"),
                      "\(name): FINAL after interactive matches independent manually expanded recipe")
            // Compare the pre-interactive settings used while switching source URLs.
            var earlierManual = manual; earlierManual.exposure -= 0.2 * settings.recipeScale
            _ = try run("manual-source-switch", mode: name, processor: makeProcessor(mode), settings: earlierManual, lut: lut)
            try check(try pixels(name, "recipe-other-url") == pixels(name, "manual-source-switch") &&
                      pixels(name, "recipe-return-url") == pixels(name, "manual-source-switch"),
                      "\(name): recipe camera baseline follows copied target URL and return URL")
            var custom = RawSettings.default
            custom.whiteBalanceMode = .custom; custom.temperature = 6000; custom.tint = camera.tint
            _ = try run("custom-kelvin-6000", mode: name, processor: processor, settings: custom)
            custom.temperature = 8000
            _ = try run("custom-kelvin-8000", mode: name, processor: processor, settings: custom)
        }

        func makeProcessor(_ mode: sony2fuji_gpu_mode) -> Sony2FujiProcessor {
            Sony2FujiProcessor(gpuMode: mode, lensDatabaseURL: root.appendingPathComponent("lutools/third_party/lensfun/version_1"))
        }

        func manuallyRenderedRecipe(_ settings: RawSettings, camera: Sony2FujiProcessor.RawWhiteBalance) -> RawSettings {
            var manual = settings
            let scale = settings.recipeScale
            manual.masterRecipeID = nil
            manual.exposure *= scale; manual.shadows *= scale; manual.highlights *= scale
            manual.contrast = 1 + (settings.contrast - 1) * scale
            manual.saturation = 1 + (settings.saturation - 1) * scale
            manual.hsl = settings.hsl.scaled(by: scale)
            if settings.whiteBalanceMode == .camera { manual.temperature = camera.temperature }
            manual.tint = min(150, max(-150, camera.tint + settings.tint * scale))
            if settings.tint * scale != 0 { manual.whiteBalanceMode = .custom }
            return manual
        }

        func run(_ label: String, mode: String, processor: Sony2FujiProcessor, settings: RawSettings,
                 lut: URL? = nil, source: URL? = nil, interactive: Bool = false,
                 final: Bool = false) throws -> Sony2FujiProcessor.RawWhiteBalance? {
            try autoreleasepool {
                let before = residentBytes(), thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
                heartbeat.begin()
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try processor.processRaw(url: source ?? raw, settings: settings,
                    previewLongEdge: final ? nil : 1280, lutURL: lut, interactive: interactive,
                    viewportPreview: true, exportLongEdge: final ? 1280 : nil)
                let processed = DispatchTime.now().uptimeNanoseconds
                let image = processor.makeUIImage(from: result.buffer, orientation: result.orientation)
                let imaged = DispatchTime.now().uptimeNanoseconds
                let histogram = processor.computeHistogram(from: result.buffer, bins: 256)
                let ended = DispatchTime.now().uptimeNanoseconds
                let after = residentBytes(), thermalAfter = ProcessInfo.processInfo.thermalState.rawValue
                let beat = heartbeat.snapshot()
                guard image != nil, histogram.count == 256, max(result.buffer.width, result.buffer.height) <= 1280 else {
                    throw Failure.message("\(mode)/\(label): invalid preview/image/histogram")
                }
                let filename = "\(mode).\(label).rgba"
                try result.buffer.data.write(to: output.appendingPathComponent(filename))
                var row: [String: Any] = ["type": "case", "mode": mode, "case": label,
                    "intent": final ? "FINAL" : "PREVIEW", "interactive": interactive,
                    "viewportRequested": true, "viewportEffective": !final,
                    "source": source == nil ? "original" : "copied-target-url",
                    "processMs": milliseconds(start, processed), "imageMs": milliseconds(processed, imaged),
                    "histogramMs": milliseconds(imaged, ended), "totalMs": milliseconds(start, ended),
                    "executionQueue": "serial-background", "mainHeartbeatPeriodMs": 10,
                    "mainHeartbeatMaximumGapMs": beat.maximumMs, "mainHeartbeatTicks": beat.count,
                    "residentBeforeBytes": before as Any? ?? NSNull(), "residentAfterBytes": after as Any? ?? NSNull(),
                    "thermalBefore": thermalBefore, "thermalAfter": thermalAfter,
                    "width": result.buffer.width, "height": result.buffer.height, "stride": result.buffer.stride,
                    "renderSourceWidth": result.buffer.nativeSize.map { Double($0.width) } as Any? ?? NSNull(),
                    "renderSourceHeight": result.buffer.nativeSize.map { Double($0.height) } as Any? ?? NSNull(),
                    "rgbaBytes": result.buffer.data.count, "rgbaFile": filename,
                    "exposure": settings.exposure, "tint": settings.tint, "temperature": settings.temperature,
                    "lutStrength": settings.lutStrength,
                    "recipeID": settings.masterRecipeID as Any? ?? NSNull()]
                if let camera = result.rawWhiteBalance {
                    row["cameraTemperature"] = camera.temperature; row["cameraTint"] = camera.tint
                }
                if let reference {
                    let baseline = try Data(contentsOf: reference.appendingPathComponent(filename))
                    let comparison = difference(result.buffer.data, baseline)
                    row["baselineEqual"] = result.buffer.data == baseline
                    row["baselineMaximumDifference"] = comparison.maximum
                    row["baselineDifferingBytes"] = comparison.count
                    row["baselineStrict"] = !interactive || final
                    if (!interactive || final) && result.buffer.data != baseline { failures += 1 }
                    if interactive && !final {
                        row["qualityNote"] = "An existing exact RAW cache may serve interactive requests; baseline may have decoded half-size. Settled/FINAL remain strict."
                    }
                }
                if mode == "metal-force" {
                    let cpu = try pixels("cpu", label)
                    let comparison = difference(result.buffer.data, cpu)
                    row["cpuMaximumDifference"] = comparison.maximum
                    row["cpuDifferingBytes"] = comparison.count
                    if comparison.maximum > 2 { failures += 1 }
                }
                try emit(row)
                return result.rawWhiteBalance
            }
        }

        func pixels(_ mode: String, _ label: String) throws -> Data {
            try Data(contentsOf: output.appendingPathComponent("\(mode).\(label).rgba"))
        }

        func difference(_ first: Data, _ second: Data) -> (maximum: Int, count: Int) {
            guard first.count == second.count else { return (Int.max, max(first.count, second.count)) }
            var maximum = 0, count = 0
            first.withUnsafeBytes { a in second.withUnsafeBytes { b in
                let left = a.bindMemory(to: UInt8.self), right = b.bindMemory(to: UInt8.self)
                for index in 0..<left.count {
                    let delta = abs(Int(left[index]) - Int(right[index]))
                    maximum = max(maximum, delta); if delta != 0 { count += 1 }
                }
            } }
            return (maximum, count)
        }

        func milliseconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1_000_000 }

        func residentBytes() -> UInt64? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let capacity = Int(count)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
        }

        #if RAWLAB_RECIPE_CACHE_TESTS
        func cacheInvariants() throws {
            let directory = output.appendingPathComponent("cache-fixtures")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.txt"), second = directory.appendingPathComponent("second.txt")
            let missing = directory.appendingPathComponent("missing.txt")
            try Data([1]).write(to: first); try Data([1, 2]).write(to: second)
            let cache = RecipeWhiteBalanceCache()
            var loads = 0
            let load = { () -> Sony2FujiProcessor.RawWhiteBalance in
                loads += 1
                return Sony2FujiProcessor.RawWhiteBalance(temperature: Double(4000 + loads), tint: Double(loads), isCalibrated: true)
            }
            let original = try cache.resolve(url: first, load: load)
            try check(try cache.resolve(url: first, load: load) == original && loads == 1, "cache: identical source loads once")
            try Data([1, 2]).write(to: first)
            _ = try cache.resolve(url: first, load: load)
            try check(loads == 2, "cache: size changes invalidate")
            let modified = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(60)], ofItemAtPath: first.path)
            _ = try cache.resolve(url: first, load: load)
            try check(loads == 3, "cache: mtime changes invalidate")
            try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(60)], ofItemAtPath: second.path)
            let other = try cache.resolve(url: second, load: load)
            try check(loads == 4 && other != original, "cache: different URL loads its own camera baseline")
            var errors = 0
            for _ in 0..<2 {
                do {
                    _ = try cache.resolve(url: first) { errors += 1; throw Failure.expected }
                    try check(false, "cache: loader error propagates")
                } catch Failure.expected { }
            }
            try check(errors == 2, "cache: failed loads are retried")
            try check(try cache.resolve(url: second, load: load) == other && loads == 4,
                      "cache: failed load preserves the previous successful key")
            _ = try cache.resolve(url: first, load: load)
            try check(loads == 5, "cache: successful retry replaces the key")
            _ = try cache.resolve(url: missing, load: load); _ = try cache.resolve(url: missing, load: load)
            try check(loads == 7, "cache: unreadable resource identity is never reused")
            _ = try cache.resolve(url: first, load: load)
            try check(loads == 8, "cache: unknown identity clears previous cached metadata")
            _ = try cache.resolve(url: first, processing: .legacy, load: load)
            try check(loads == 9, "cache: processing version changes invalidate the camera baseline")
            _ = try cache.resolve(url: first, processing: .legacy, load: load)
            try check(loads == 9, "cache: unchanged legacy identity reuses the baseline")
            _ = try cache.resolve(url: first, processing: .current, load: load)
            try check(loads == 10, "cache: returning to current identity loads its own baseline")
        }
        #endif
    }
}
