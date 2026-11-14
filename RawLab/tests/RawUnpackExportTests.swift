import Foundation
import CoreGraphics

@_silgen_name("rawlab_counter_reset")
func rawlabCounterReset()

@_silgen_name("rawlab_counter_bridge_load")
func rawlabCounterBridgeLoad() -> Int32

@_silgen_name("rawlab_counter_bridge_inspect")
func rawlabCounterBridgeInspect() -> Int32

@_silgen_name("rawlab_counter_bridge_lens_cpp")
func rawlabCounterBridgeLensCpp() -> Int32

@_silgen_name("rawlab_counter_c_inspect_lens")
func rawlabCounterCInspectLens() -> Int32

@_silgen_name("rawlab_counter_core_decode")
func rawlabCounterCoreDecode() -> Int32

struct UnpackCounts: Equatable {
    let bridgeLoad: Int32
    let bridgeInspect: Int32
    let bridgeLensCpp: Int32
    let cInspectLens: Int32
    let coreDecode: Int32

    var totalUnpack: Int32 { bridgeLoad + coreDecode }

    static func current() -> UnpackCounts {
        UnpackCounts(
            bridgeLoad: rawlabCounterBridgeLoad(),
            bridgeInspect: rawlabCounterBridgeInspect(),
            bridgeLensCpp: rawlabCounterBridgeLensCpp(),
            cInspectLens: rawlabCounterCInspectLens(),
            coreDecode: rawlabCounterCoreDecode()
        )
    }
}

@main
struct RawUnpackExportTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        checks += 1
        print("PASS: \(message)")
    }

    static func checkMissingFileError(_ label: String, _ operation: () throws -> Void) {
        rawlabCounterReset()
        do {
            try operation()
            check(false, "\(label) missing file throws")
        } catch let error as NSError {
            let counts = UnpackCounts.current()
            check(error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError,
                  "\(label) missing file throws NSFileReadNoSuchFileError (got \(error.domain):\(error.code))")
            check(counts.totalUnpack == 0, "\(label) missing file unpacks 0 times (got \(counts.totalUnpack))")
        }
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("Usage: raw-unpack-export <RAW> <OUT_DIR>\n", stderr)
            exit(2)
        }
        let rawURL = URL(fileURLWithPath: args[1])
        let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Header-only dimensions query must not trigger RAWProcessor::loadFile pixel unpack.
        rawlabCounterReset()
        let dims = rawURL.path.withCString { rawlab_get_raw_dimensions($0) }
        var counts = UnpackCounts.current()
        check(dims.width > 0 && dims.height > 0, "rawlab_get_raw_dimensions returns valid size (\(dims.width)x\(dims.height))")
        check(counts.bridgeLoad == 0 && counts.coreDecode == 0 && counts.bridgeInspect == 1,
              "rawlab_get_raw_dimensions uses inspectFile with 0 unpacks (load=\(counts.bridgeLoad) inspect=\(counts.bridgeInspect) decode=\(counts.coreDecode))")

        rawlabCounterReset()
        let emptyDims = "".withCString { rawlab_get_raw_dimensions($0) }
        check(emptyDims.width == 0 && emptyDims.height == 0 && UnpackCounts.current().totalUnpack == 0,
              "empty path dimensions return 0x0 with 0 unpacks")

        // 2. RAW file kind probe must route through shared C API sony2fuji_session_inspect_lens.
        rawlabCounterReset()
        let kind = rawURL.path.withCString { rawlab_probe_raw_file($0) }
        counts = UnpackCounts.current()
        check(kind != RAWLAB_FILE_NOT_RAW, "rawlab_probe_raw_file detects RAW fixture (kind=\(kind.rawValue))")
        if rawURL.pathExtension.lowercased() == "arw" {
            check(kind == RAWLAB_FILE_SONY_RAW, "Sony ARW fixture classified as RAWLAB_FILE_SONY_RAW")
        }
        check(counts.cInspectLens >= 1 && counts.bridgeLensCpp == 0 && counts.totalUnpack == 0,
              "rawlab_probe_raw_file uses sony2fuji_session_inspect_lens with 0 unpacks (cInspect=\(counts.cInspectLens) cppLens=\(counts.bridgeLensCpp))")

        let notRawURL = outDir.appendingPathComponent("not-raw.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: notRawURL)
        rawlabCounterReset()
        let notRawKind = notRawURL.path.withCString { rawlab_probe_raw_file($0) }
        counts = UnpackCounts.current()
        check(notRawKind == RAWLAB_FILE_NOT_RAW && counts.cInspectLens >= 1 && counts.bridgeLensCpp == 0,
              "non-RAW probe returns RAWLAB_FILE_NOT_RAW via C API")

        // 3. exportDNG (native and long-edge scaled) unpacks RAW at most once.
        let processor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        let dngNativeURL = outDir.appendingPathComponent("native.dng")
        rawlabCounterReset()
        try processor.exportDNG(url: rawURL, settings: .default, lutURL: nil, outputURL: dngNativeURL, exportLongEdge: nil)
        counts = UnpackCounts.current()
        let dngSize = (try? FileManager.default.attributesOfItem(atPath: dngNativeURL.path)[.size] as? Int) ?? 0
        check(dngSize > 1024, "native exportDNG produced non-empty DNG (\(dngSize) bytes)")
        check(counts.bridgeLoad == 0 && counts.bridgeInspect == 0 && counts.coreDecode == 1 && counts.totalUnpack == 1,
              "native exportDNG unpacks exactly once (bridgeLoad=\(counts.bridgeLoad) coreDecode=\(counts.coreDecode) total=\(counts.totalUnpack))")

        // Probe the exported non-Sony DNG via shared C API -> RAWLAB_FILE_RAW.
        rawlabCounterReset()
        let dngKind = dngNativeURL.path.withCString { rawlab_probe_raw_file($0) }
        counts = UnpackCounts.current()
        check(dngKind == RAWLAB_FILE_RAW && counts.cInspectLens >= 1 && counts.bridgeLensCpp == 0,
              "exported DNG classified as RAWLAB_FILE_RAW via C API (kind=\(dngKind.rawValue))")

        let dngScaledURL = outDir.appendingPathComponent("scaled.dng")
        rawlabCounterReset()
        try Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF).exportDNG(
            url: rawURL, settings: .default, lutURL: nil, outputURL: dngScaledURL, exportLongEdge: 1200)
        counts = UnpackCounts.current()
        check(FileManager.default.fileExists(atPath: dngScaledURL.path), "scaled exportDNG produced file")
        check(counts.bridgeLoad == 0 && counts.bridgeInspect == 0 && counts.coreDecode == 1 && counts.totalUnpack == 1,
              "scaled exportDNG unpacks exactly once (total=\(counts.totalUnpack))")

        // 4. processRaw (native export & preview) unpacks RAW exactly once.
        rawlabCounterReset()
        let nativeResult = try Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF).processRaw(
            url: rawURL, settings: .default, previewLongEdge: nil, lutURL: nil)
        counts = UnpackCounts.current()
        check(Set([UInt32(nativeResult.buffer.width), UInt32(nativeResult.buffer.height)]) == Set([dims.width, dims.height]),
              "native processRaw buffer (\(nativeResult.buffer.width)x\(nativeResult.buffer.height)) matches header dims (\(dims.width)x\(dims.height))")
        check(counts.bridgeLoad == 0 && counts.bridgeInspect == 0 && counts.coreDecode == 1 && counts.totalUnpack == 1,
              "native processRaw unpacks exactly once (total=\(counts.totalUnpack))")

        let previewProcessor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        rawlabCounterReset()
        let previewResult = try previewProcessor.processRaw(
            url: rawURL, settings: .default, previewLongEdge: 1200, lutURL: nil)
        counts = UnpackCounts.current()
        let previewLong = max(previewResult.buffer.width, previewResult.buffer.height)
        check(previewLong > 0 && previewLong <= 1200, "preview processRaw obeys 1200px long edge (got \(previewLong))")
        check(counts.bridgeLoad == 0 && counts.bridgeInspect == 0 && counts.coreDecode == 1 && counts.totalUnpack == 1,
              "preview processRaw unpacks exactly once (total=\(counts.totalUnpack))")

        // 5. Warm sampleHSL reuses preview session (0 unpacks); cold sampleHSL on another RAW unpacks once.
        rawlabCounterReset()
        let warmHSL = try previewProcessor.sampleHSL(
            url: rawURL, buffer: nil, settings: .default, previewLongEdge: 1200, lutURL: nil,
            interactive: false, revision: HSLTargetRevision(source: 1, request: 1), point: CGPoint(x: 0.5, y: 0.5))
        counts = UnpackCounts.current()
        check(warmHSL.availability == .available, "warm sampleHSL returns available sample")
        check(counts.bridgeLoad == 0 && counts.bridgeInspect == 0 && counts.totalUnpack == 0,
              "warm sampleHSL reuses preview session without re-unpacking (total=\(counts.totalUnpack))")

        rawlabCounterReset()
        let coldHSL = try Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF).sampleHSL(
            url: dngScaledURL, buffer: nil, settings: .default, previewLongEdge: 1200, lutURL: nil,
            interactive: false, revision: HSLTargetRevision(source: 2, request: 1), point: CGPoint(x: 0.5, y: 0.5))
        counts = UnpackCounts.current()
        check(coldHSL.availability == .available, "cold sampleHSL returns available sample")
        check(counts.bridgeLoad == 0 && counts.bridgeInspect == 0 && counts.coreDecode == 1 && counts.totalUnpack == 1,
              "cold sampleHSL unpacks exactly once (total=\(counts.totalUnpack))")

        // 6. Missing RAW file preserves NSFileReadNoSuchFileError with zero unpacks.
        let missingURL = outDir.appendingPathComponent("missing.arw")
        let errProcessor = Sony2FujiProcessor(gpuMode: SONY2FUJI_GPU_OFF)
        checkMissingFileError("processRaw") {
            _ = try errProcessor.processRaw(url: missingURL, settings: .default, previewLongEdge: nil, lutURL: nil)
        }
        checkMissingFileError("exportDNG") {
            try errProcessor.exportDNG(url: missingURL, settings: .default, lutURL: nil,
                                       outputURL: outDir.appendingPathComponent("err.dng"), exportLongEdge: nil)
        }
        checkMissingFileError("sampleHSL") {
            _ = try errProcessor.sampleHSL(url: missingURL, buffer: nil, settings: .default, previewLongEdge: 1200,
                                           lutURL: nil, interactive: false, revision: HSLTargetRevision(source: 1, request: 1), point: CGPoint(x: 0.5, y: 0.5))
        }

        print("PASS: raw unpack export suite (\(checks) checks)")
    }
}
