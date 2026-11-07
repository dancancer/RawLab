import Foundation

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

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }
}
