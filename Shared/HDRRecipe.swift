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
        let document: [String:Any]=[
            "schema_version":6,
            "processing":["family":"rawlab_hdr","version":settings.processingVersion,"quality":"standard"],
            "input":["path":input.standardizedFileURL.path,"type":"hdr_raster"],
            "edits":[
                "exposure":["ev":settings.exposure],
                "white_balance":["mode":"relative","relative_temperature":settings.temperature,"relative_tint":settings.tint],
                "tone":["contrast":1+settings.contrast/100,"saturation":1+settings.saturation/100,
                        "highlights":-settings.highlights/100,"shadows":settings.shadows/100],
                "geometry":["crop":["x":g.cropX,"y":g.cropY,"width":g.cropWidth,"height":g.cropHeight],
                            "quarter_turns":g.quarterTurns,"flip_horizontal":g.flipHorizontal,"flip_vertical":g.flipVertical,
                            "straighten_degrees":g.straightenDegrees,
                            "perspective":["horizontal":g.perspectiveHorizontal,"vertical":g.perspectiveVertical]]
            ],
            "output":["path":output.standardizedFileURL.path,"format":"hdr_jpeg","base_color":baseColor.rawValue,
                      "jpeg_quality":95,"size":size]
        ]
        return try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys])
    }
}
