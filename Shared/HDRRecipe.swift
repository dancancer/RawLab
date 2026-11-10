import Foundation

enum HDRRecipe {
    enum BaseColor: String { case srgb, displayP3 = "display_p3" }
    enum Failure: Error { case invalidSettings }

    static func document(settings: HDRSettings, input: URL, output: URL,
                         baseColor: BaseColor, longEdge: Int? = nil) throws -> Data {
        guard settings.isValid, settings.mode == .hdr, input.isFileURL, output.isFileURL,
              !input.path.utf8.contains(0), !output.path.utf8.contains(0),
              longEdge.map({ (1...65535).contains($0) }) ?? true else { throw Failure.invalidSettings }
        let g=settings.geometry
        let size: [String:Any]=longEdge.map { ["mode":"limit_long_edge","long_edge":$0] } ?? ["mode":"native"]
        var tone: [String: Any] = ["contrast": 1 + settings.contrast / 100, "saturation": 1 + settings.saturation / 100,
            "highlights": -settings.highlights / 100, "shadows": settings.shadows / 100]
        let version = settings.processingVersion
        if version >= 2 {
            let current = settings.toneSettings
            tone["black_point"] = current.blackPoint / 100
            tone["white_point"] = current.whitePoint / 100
            tone["s_curve"] = current.curve.mode == .custom ? 0 : current.curveStrength / 100
            tone["curve"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current.curve))
        }
        var edits: [String: Any] = [
                "exposure":["ev":settings.exposure],
                "white_balance":["mode":"relative","relative_temperature":settings.temperature,"relative_tint":settings.tint],
                "tone": tone,
                "geometry":["crop":["x":g.cropX,"y":g.cropY,"width":g.cropWidth,"height":g.cropHeight],
                            "quarter_turns":g.quarterTurns,"flip_horizontal":g.flipHorizontal,"flip_vertical":g.flipVertical,
                            "straighten_degrees":g.straightenDegrees,
                            "perspective":["horizontal":g.perspectiveHorizontal,"vertical":g.perspectiveVertical]]
        ]
        if version >= 3 {
            let color = settings.colorSettings
            edits["color"] = ["vibrance": color.vibrance / 100]
            edits["hsl"] = ["hue": color.hsl.hue, "saturation": color.hsl.saturation, "lightness": color.hsl.lightness]
            edits["color_grading"] = Dictionary(uniqueKeysWithValues: ColorGradingZone.allCases.map { zone in
                let wheel = color.grading[zone]
                return (zone.rawValue, ["hue": wheel.hue, "saturation": wheel.saturation])
            })
        }
        if version >= 4 {
            let rendition = settings.renditionSettings
            edits["rendition"] = ["peak_limit_ev": rendition.peakLimitEV, "sdr_exposure_ev": rendition.sdrExposureEV,
                "sdr_contrast": rendition.sdrContrast / 100, "sdr_saturation": rendition.sdrSaturation / 100]
        }
        if version >= 5 {
            let fx = settings.effectsSettings
            edits["effects"] = ["vignette_amount": fx.vignetteAmount, "vignette_midpoint": fx.vignetteMidpoint,
                "vignette_roundness": fx.vignetteRoundness, "vignette_feather": fx.vignetteFeather,
                "vignette_highlights": fx.vignetteHighlights, "grain_amount": fx.grainAmount,
                "grain_size": fx.grainSize, "grain_roughness": fx.grainRoughness]
        }
        if version >= 6 {
            let detail = settings.detailSettings
            edits["detail"] = ["sharpening": detail.sharpening, "clarity": detail.clarity,
                "dehaze": detail.dehaze, "denoise": detail.denoise]
        }
        if let asset = settings.lookSettings.asset(), let fingerprint = settings.lookSettings.sha256 {
            edits["look"] = ["path": asset.path, "sha256": fingerprint, "strength": settings.lookSettings.strength]
        }
        let document: [String:Any]=[
            "schema_version": version == 8 ? 15 : version == 1 ? 6 : version + 6,
            "processing":["family":"rawlab_hdr","version":version,"quality":"standard"],
            "input":["path":input.standardizedFileURL.path,"type":"hdr_raster"],
            "edits":edits,
            "output":["path":output.standardizedFileURL.path,"format":"hdr_jpeg","base_color":baseColor.rawValue,
                      "jpeg_quality":95,"size":size]
        ]
        return try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys])
    }
}
