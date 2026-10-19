import CryptoKit
import Darwin
import Foundation
import ImageIO
import UIKit

enum RasterExportBenchmark {
    private static let expectedRawSHA256 =
        "dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f"
    private static let expectedRawBytes = 45_199_360
    private static let expectedWidth = 4672
    private static let expectedHeight = 7008
    private static let measuredRuns = 5

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private struct Fixture {
        let url: URL
        let width: Int
        let height: Int
        let bytes: Int
        let sha256: String
    }

    private struct Footprint {
        let start: UInt64
        let peak: UInt64
        var delta: UInt64 { peak - start }
    }

    private struct Run {
        let index: Int
        let elapsedMs: Double
        let outputBytes: Int
        let footprint: Footprint
    }

    private final class FootprintSampler {
        private let queue = DispatchQueue(label: "com.rawlab.tests.raster-export-footprint")
        private let timer: DispatchSourceTimer
        private let lock = NSLock()
        private var start: UInt64?
        private var peak: UInt64 = 0
        private var failure: String?

        init() {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.sample() }
        }

        func startSampling() throws -> UInt64 {
            let initial = try Self.physFootprint()
            lock.lock()
            start = initial
            peak = initial
            lock.unlock()
            timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
            timer.resume()
            return initial
        }

        func stop() throws -> Footprint {
            timer.cancel()
            queue.sync {}
            lock.lock()
            let result = (start, peak, failure)
            lock.unlock()
            if let failure = result.2 { throw Failure(message: failure) }
            guard let start = result.0 else {
                throw Failure(message: "phys_footprint sampler stopped before it started")
            }
            return Footprint(start: start, peak: result.1)
        }

        func cancel() {
            timer.cancel()
            queue.sync {}
        }

        private func sample() {
            do {
                let current = try Self.physFootprint()
                lock.lock()
                peak = max(peak, current)
                lock.unlock()
            } catch {
                lock.lock()
                failure = "task_info(TASK_VM_INFO) sample failed: \(error)"
                lock.unlock()
                timer.cancel()
            }
        }

        private static func physFootprint() throws -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let capacity = Int(count)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else {
                throw Failure(message: "task_info(TASK_VM_INFO) failed with status \(status)")
            }
            let footprint = UInt64(info.phys_footprint)
            guard footprint > 0 else {
                throw Failure(message: "task_info(TASK_VM_INFO) returned zero phys_footprint")
            }
            return footprint
        }
    }

    static func run(raw: URL, directory: URL) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try runOnMain(raw: raw, directory: directory)
    }

    private static func runOnMain(raw: URL, directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = raw.standardizedFileURL
        guard fileManager.fileExists(atPath: raw.path) else {
            throw Failure(message: "Missing RAW fixture: \(raw.path)")
        }

        let rawFile = try fileHash(raw)
        guard rawFile.sha256 == expectedRawSHA256 && rawFile.bytes == expectedRawBytes else {
            throw Failure(message: "Unexpected RAW fixture: bytes=\(rawFile.bytes), sha256=\(rawFile.sha256)")
        }

        let fixture = try autoreleasepool { try makeFixture(raw: raw, directory: directory) }
        let logURL = directory.appendingPathComponent("raster-export-benchmark.jsonl")
        try? fileManager.removeItem(at: logURL)
        _ = fileManager.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        func emit(_ record: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            try log.write(contentsOf: data)
            FileHandle.standardOutput.write(data)
        }

        let edits = directory.appendingPathComponent("benchmark-edits", isDirectory: true)
        let persistence = try EditPersistence(directory: edits)
        let identity = PhotoIdentity(resourceIdentifier: "raster-export-benchmark-\(UUID().uuidString)")
        let model = RawEditorViewModel(editPersistence: persistence)
        defer {
            model.invalidatePreviewRequests()
            model.sourceFile = nil
            model.editPersistence = nil
            try? fileManager.removeItem(at: edits)
        }

        model.importImage(from: .raster(fixture.url), identity: identity)
        try waitUntil({ !model.isBusy }, timeout: 180, label: "raster import")
        guard case .raster? = model.sourceKind else {
            throw Failure(message: "Raster import published the wrong source kind: \(String(describing: model.sourceKind))")
        }
        guard model.hasImage, model.sourceIdentity == identity,
              model.sourceFile != nil,
              model.previewImage != nil, model.basePreviewImage != nil,
              model.draftBuffer != nil, model.draftPreviewBuffer != nil,
              !model.previewRendering, !model.previewResizePending else {
            throw Failure(message: "Raster import did not publish the normal preview and draft buffer: \(model.statusMessage ?? "unknown error")")
        }

        try emit([
            "type": "fixture",
            "rawPath": raw.path,
            "rawBytes": rawFile.bytes,
            "rawSHA256": rawFile.sha256,
            "jpegPath": fixture.url.path,
            "jpegBytes": fixture.bytes,
            "jpegSHA256": fixture.sha256,
            "width": fixture.width,
            "height": fixture.height,
            "quality": 0.92,
            "orientation": "up",
            "gpuMode": gpuModeName(model.processor.gpuMode),
            "backend": "not exposed by RawEditorViewModel.exportJPEG",
            "platform": platformName(),
            "platformNote": "Simulator timing and sampled memory are indicative only, not physical-device evidence.",
            "memoryScope": "End-to-end export, including the returned JPEG Data; sampled peak, not a kernel high-water mark.",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "buildConfiguration": ProcessInfo.processInfo.environment["CONFIGURATION"] ?? NSNull(),
            "gitHead": ProcessInfo.processInfo.environment["RAWLAB_GIT_HEAD"] ?? NSNull()
        ])

        let settings = RawSettings.default
        let warmupBytes = try autoreleasepool { try exportBytes(model: model, settings: settings) }
        try waitUntil({ !model.isBusy && !model.previewRendering && !model.previewResizePending },
                      timeout: 180, label: "warmup export")
        try emit(["type": "warmup", "outputBytes": warmupBytes])

        var runs: [Run] = []
        for index in 1...measuredRuns {
            let run = try autoreleasepool {
                try measure(model: model, settings: settings, index: index)
            }
            runs.append(run)
            try emit([
                "type": "run", "index": run.index, "elapsedMs": run.elapsedMs,
                "outputBytes": run.outputBytes,
                "startPhysFootprintBytes": NSNumber(value: run.footprint.start),
                "sampledPeakPhysFootprintBytes": NSNumber(value: run.footprint.peak),
                "physFootprintDeltaBytes": NSNumber(value: run.footprint.delta),
                "sampleIntervalMs": 1.0
            ])
            try waitUntil({ !model.isBusy && !model.previewRendering && !model.previewResizePending },
                          timeout: 180, label: "export \(index) settle")
        }

        try emit([
            "type": "summary",
            "runs": runs.count,
            "timeMs": stats(runs.map(\.elapsedMs)),
            "startPhysFootprintBytes": stats(runs.map { Double($0.footprint.start) }),
            "sampledPeakPhysFootprintBytes": stats(runs.map { Double($0.footprint.peak) }),
            "physFootprintDeltaBytes": stats(runs.map { Double($0.footprint.delta) }),
            "sampleIntervalMs": 1.0,
            "platform": platformName(),
            "platformNote": "Simulator timing and sampled memory are indicative only, not physical-device evidence.",
            "memoryScope": "End-to-end export, including the returned JPEG Data; sampled peak, not a kernel high-water mark."
        ])
    }

    private static func makeFixture(raw: URL, directory: URL) throws -> Fixture {
        let processor = Sony2FujiProcessor()
        let rendered = try processor.processRaw(url: raw, settings: .default,
                                                 previewLongEdge: nil, lutURL: nil)
        let data = try processor.makeJPEGData(from: rendered.buffer, sourceURL: raw,
                                              orientation: .up, quality: 0.92)
        let url = directory.appendingPathComponent("raster-export-fixture.jpg")
        try data.write(to: url, options: .atomic)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = number(properties[kCGImagePropertyPixelWidth]),
              let height = number(properties[kCGImagePropertyPixelHeight]) else {
            throw Failure(message: "Generated JPEG has no readable dimensions")
        }
        guard (width == expectedWidth && height == expectedHeight) ||
              (width == expectedHeight && height == expectedWidth) else {
            throw Failure(message: "Generated JPEG dimensions are \(width)x\(height), expected 4672x7008")
        }
        return Fixture(url: url, width: width, height: height, bytes: data.count, sha256: sha256(data))
    }

    private static func exportBytes(model: RawEditorViewModel, settings: RawSettings) throws -> Int {
        var result: Result<Data, Error>?
        defer { result = nil }
        model.exportJPEG(settings: settings) { result = $0 }
        try waitUntil({ result != nil }, timeout: 600, label: "JPEG export")
        guard let result else { throw Failure(message: "JPEG export did not complete") }
        let data = try result.get()
        guard !data.isEmpty else { throw Failure(message: "JPEG export returned empty data") }
        return data.count
    }

    private static func measure(model: RawEditorViewModel, settings: RawSettings, index: Int) throws -> Run {
        let sampler = FootprintSampler()
        _ = try sampler.startSampling()
        var stopped = false
        var result: Result<Data, Error>?
        defer {
            result = nil
            if !stopped { sampler.cancel() }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        model.exportJPEG(settings: settings) { result = $0 }
        try waitUntil({ result != nil }, timeout: 600, label: "measured JPEG export \(index)")
        let ended = DispatchTime.now().uptimeNanoseconds
        let footprint = try sampler.stop()
        stopped = true
        guard let result else { throw Failure(message: "Measured JPEG export did not complete") }
        let data = try result.get()
        guard !data.isEmpty else { throw Failure(message: "Measured JPEG export returned empty data") }
        return Run(index: index, elapsedMs: Double(ended - started) / 1_000_000,
                   outputBytes: data.count, footprint: footprint)
    }

    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval, label: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(message: "Timed out waiting for \(label)") }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }

    private static func fileHash(_ url: URL) throws -> (bytes: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            bytes += data.count
        }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        return ["median": median, "min": sorted[0], "max": sorted[sorted.count - 1],
                "range": sorted[sorted.count - 1] - sorted[0]]
    }

    private static func gpuModeName(_ mode: sony2fuji_gpu_mode) -> String {
        if mode == SONY2FUJI_GPU_OFF { return "off" }
        if mode == SONY2FUJI_GPU_FORCE { return "force" }
        if mode == SONY2FUJI_GPU_AUTO { return "auto" }
        return "unknown"
    }

    private static func platformName() -> String {
        #if targetEnvironment(simulator)
        return "iOS Simulator"
        #else
        return "iOS device"
        #endif
    }
}
