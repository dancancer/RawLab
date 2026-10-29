import Foundation

enum HDRRequestError: Error { case invalidSettings }

func makeHDRRequest(settings: HDRSettings, intent: sony2fuji_intent,
                    longEdge: Int? = nil) throws -> sony2fuji_hdr_request_v1 {
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
    return request
}
