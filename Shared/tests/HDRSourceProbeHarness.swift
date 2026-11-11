import Foundation

// 此 harness 只运行探测决策；RAW 解码和原生探测由其他原生测试覆盖。
struct ProRAWSource {
    let width: Int
    let height: Int
    static func probe(_ url: URL) throws -> ProRAWSource? { fatalError("unexpected ProRAW probe") }
    static func validatedDecodeVersion(_ saved: Int?) throws -> Int { fatalError("unexpected ProRAW decode validation") }
}

@_cdecl("sony2fuji_hdr_probe")
func unusedNativeProbe(_ path: UnsafePointer<CChar>?, _ info: UnsafeMutablePointer<sony2fuji_hdr_source_info_v1>?,
                       _ diagnostic: UnsafeMutablePointer<sony2fuji_hdr_diagnostic_v1>?) -> sony2fuji_status {
    fatalError("native probe must be injected")
}

@_cdecl("sony2fuji_hdr_probe_camera_raw_with_processing")
func unusedCameraProbe(_ path: UnsafePointer<CChar>?, _ processing: sony2fuji_processing_version,
                       _ info: UnsafeMutablePointer<sony2fuji_hdr_source_info_v1>?,
                       _ diagnostic: UnsafeMutablePointer<sony2fuji_hdr_diagnostic_v1>?) -> sony2fuji_status {
    fatalError("unexpected camera RAW probe")
}

@main enum HDRSourceProbeHarness {
    static func main() throws { try HDRSourceProbeTests.run() }
}
