import Foundation

extension HSLTargetSample {
    static func capture(session: OpaquePointer, request: inout sony2fuji_request,
                        revision: HSLTargetRevision, x: Double, y: Double) -> HSLTargetSample {
        capture(revision: revision, x: x, y: y) { probe in
            sony2fuji_session_create_hsl_probe(session, &request, revision.source, revision.request, &probe)
        }
    }

    static func capture(session: OpaquePointer, pair: UnsafePointer<sony2fuji_hdr_image_pair_v1>,
                        request: HDRRenderRequest, revision: HSLTargetRevision,
                        x: Double, y: Double) -> HSLTargetSample {
        capture(revision: revision, x: x, y: y) { probe in
            withHDRRequestPrefix(request) { prefix in
                sony2fuji_hdr_create_hsl_probe(session, pair, prefix, revision.source, revision.request, &probe, nil)
            }
        }
    }

    private static func capture(revision: HSLTargetRevision, x: Double, y: Double,
                                makeProbe: (inout OpaquePointer?) -> sony2fuji_status) -> HSLTargetSample {
        func unavailable(_ reason: HSLTargetAvailability) -> HSLTargetSample {
            HSLTargetSample(revision: revision, availability: reason, rgb: [], weights: [], preview: true)
        }
        guard x.isFinite, y.isFinite else { return unavailable(.nonfinite) }
        guard (0...1).contains(x), (0...1).contains(y) else { return unavailable(.outside) }
        var probe: OpaquePointer?
        guard makeProbe(&probe) == SONY2FUJI_STATUS_OK, let probe else { return unavailable(.failed) }
        defer { sony2fuji_hsl_probe_destroy(probe) }
        var query = sony2fuji_hsl_probe_query()
        query.version = UInt32(SONY2FUJI_HSL_PROBE_VERSION)
        query.struct_size = UInt32(MemoryLayout<sony2fuji_hsl_probe_query>.size)
        query.source_revision = revision.source; query.request_revision = revision.request
        query.x = Float(x); query.y = Float(y)
        var result = sony2fuji_hsl_probe_result()
        guard sony2fuji_hsl_probe_sample(probe, &query, &result) == SONY2FUJI_STATUS_OK else { return unavailable(.failed) }
        let rgb = withUnsafeBytes(of: result.rgb) { $0.bindMemory(to: Float.self).map(Double.init) }
        let weights = withUnsafeBytes(of: result.weights) { $0.bindMemory(to: Float.self).map(Double.init) }
        return HSLTargetSample(revision: HSLTargetRevision(source: result.source_revision, request: result.request_revision),
            availability: HSLTargetAvailability(rawValue: Int(result.availability.rawValue)) ?? .failed,
            rgb: rgb, weights: weights, preview: result.quality == SONY2FUJI_HSL_PROBE_PREVIEW_CPU)
    }
}
