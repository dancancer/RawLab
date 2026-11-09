import Foundation

enum HDRRequestError: Error { case invalidSettings }

struct HDRRenderRequest {
    let native: sony2fuji_hdr_request_v7
    let lookURL: URL?
}

func makeHDRRequest(settings: HDRSettings, intent: sony2fuji_intent,
                    longEdge: Int? = nil, lookDirectory: URL = HDRLookSettings.directory) throws -> HDRRenderRequest {
    guard settings.mode == .hdr, settings.isValid,
          intent == SONY2FUJI_INTENT_PREVIEW || intent == SONY2FUJI_INTENT_FINAL,
          longEdge.map({ (1...65535).contains($0) }) ?? true else { throw HDRRequestError.invalidSettings }
    var request=sony2fuji_hdr_request_v1()
    request.version=1; request.struct_size=UInt32(MemoryLayout<sony2fuji_hdr_request_v1>.size)
    request.hdr_processing_version=UInt32(settings.processingVersion); request.intent=UInt32(intent.rawValue)
    request.exposure_ev=Float(settings.exposure); request.temperature=Float(settings.temperature); request.tint=Float(settings.tint)
    request.contrast=Float(settings.contrast); request.highlights=Float(settings.highlights)
    request.shadows=Float(settings.shadows); request.saturation=Float(settings.saturation)
    let g=settings.geometry
    request.crop_x=Float(g.cropX); request.crop_y=Float(g.cropY)
    request.crop_width=min(Float(g.cropWidth),1-request.crop_x); request.crop_height=min(Float(g.cropHeight),1-request.crop_y)
    request.quarter_turns=Int32(g.quarterTurns); request.flip_horizontal=g.flipHorizontal ? 1 : 0
    request.flip_vertical=g.flipVertical ? 1 : 0; request.straighten_degrees=Float(g.straightenDegrees)
    request.perspective_horizontal=Float(g.perspectiveHorizontal); request.perspective_vertical=Float(g.perspectiveVertical)
    request.long_edge=UInt32(longEdge ?? 0)
    var extended = sony2fuji_hdr_request_v2()
    extended.base = request
    if request.hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_TONE_VERSION {
        let tone = settings.toneSettings
        extended.base.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_request_v2>.size)
        extended.black_point = Float(tone.blackPoint)
        extended.white_point = Float(tone.whitePoint)
        extended.curve_strength = Float(tone.curveStrength)
        extended.curve = tone.curve.nativeConfig
    }
    var colorRequest = sony2fuji_hdr_request_v3()
    colorRequest.base = extended
    if request.hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_COLOR_VERSION {
        let color = settings.colorSettings
        colorRequest.base.base.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_request_v3>.size)
        colorRequest.vibrance = Float(color.vibrance)
        colorRequest.hsl = color.hsl.nativeConfig
        colorRequest.grading = color.grading.nativeConfig
    }
    var renditionRequest = sony2fuji_hdr_request_v4()
    renditionRequest.base = colorRequest
    if request.hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION {
        let rendition = settings.renditionSettings
        renditionRequest.base.base.base.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_request_v4>.size)
        renditionRequest.peak_limit_ev = Float(rendition.peakLimitEV)
        renditionRequest.sdr_exposure_ev = Float(rendition.sdrExposureEV)
        renditionRequest.sdr_contrast = Float(rendition.sdrContrast)
        renditionRequest.sdr_saturation = Float(rendition.sdrSaturation)
    }
    var effectsRequest = sony2fuji_hdr_request_v5()
    effectsRequest.base = renditionRequest
    if request.hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION {
        let effects = settings.effectsSettings
        effectsRequest.base.base.base.base.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_request_v5>.size)
        effectsRequest.effects = .init(
            version: UInt32(SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION),
            struct_size: UInt32(MemoryLayout<sony2fuji_photo_effects_config>.size),
            vignette_amount: Float(effects.vignetteAmount), vignette_midpoint: Float(effects.vignetteMidpoint),
            vignette_roundness: Float(effects.vignetteRoundness), vignette_feather: Float(effects.vignetteFeather),
            vignette_highlights: Float(effects.vignetteHighlights), grain_amount: Float(effects.grainAmount),
            grain_size: Float(effects.grainSize), grain_roughness: Float(effects.grainRoughness))
    }
    var detailRequest = sony2fuji_hdr_request_v6()
    detailRequest.base = effectsRequest
    if request.hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION {
        let detail = settings.detailSettings
        detailRequest.base.base.base.base.base.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_request_v6>.size)
        detailRequest.sharpening = Float(detail.sharpening)
        detailRequest.clarity = Float(detail.clarity)
        detailRequest.dehaze = Float(detail.dehaze)
        detailRequest.denoise = Float(detail.denoise)
    }
    var lookRequest = sony2fuji_hdr_request_v7()
    lookRequest.base = detailRequest
    if request.hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION {
        lookRequest.base.base.base.base.base.base.struct_size = UInt32(MemoryLayout<sony2fuji_hdr_request_v7>.size)
        lookRequest.look_strength = Float(settings.lookSettings.strength)
        if let fingerprint = settings.lookSettings.sha256 {
            withUnsafeMutableBytes(of: &lookRequest.look_sha256) { bytes in
                bytes.copyBytes(from: fingerprint.utf8)
            }
        }
    }
    return HDRRenderRequest(native: lookRequest, lookURL: settings.lookSettings.asset(in: lookDirectory))
}

func withHDRRequestPrefix<T>(_ request: HDRRenderRequest,
                             _ body: (UnsafePointer<sony2fuji_hdr_request_v1>) throws -> T) rethrows -> T {
    var native = request.native
    func call(_ path: UnsafePointer<CChar>?, _ invoke: (UnsafePointer<sony2fuji_hdr_request_v1>) throws -> T) rethrows -> T {
        native.look_path = path
        return try withUnsafePointer(to: &native) { full in
            try full.withMemoryRebound(to: sony2fuji_hdr_request_v1.self, capacity: 1, invoke)
        }
    }
    if let url = request.lookURL { return try url.path.withCString { try call($0, body) } }
    return try call(nil, body)
}
