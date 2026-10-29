import Foundation

@main enum HDRNativeRequestTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        var settings=HDRSettings()
        require(MemoryLayout<sony2fuji_hdr_image_pair_v1>.size==208,"Swift HDR pair layout differs from C11 contract")
        settings.exposure=1.25; settings.temperature=7200; settings.tint = -12
        settings.contrast=30; settings.highlights=20; settings.shadows=40; settings.saturation=10
        settings.geometry.quarterTurns=1; settings.geometry.flipHorizontal=true
        let request=try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_FINAL,longEdge:1600)
        require(request.version==1 && request.struct_size==88 && request.hdr_processing_version==1,"HDR ABI header differs")
        require(request.exposure_ev==1.25 && request.temperature==7200 && request.tint == -12,"HDR exposure/WB mapping differs")
        require(request.contrast==30 && request.highlights==20 && request.shadows==40 && request.saturation==10,"HDR logical tone mapping differs")
        require(request.quarter_turns==1 && request.flip_horizontal==1 && request.long_edge==1600,"HDR geometry/size mapping differs")
        let data=try HDRRecipe.document(settings:settings,input:URL(fileURLWithPath:"/tmp/source.heic"),
            output:URL(fileURLWithPath:"/tmp/output.jpg"),baseColor:.displayP3,longEdge:1600)
        let root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let edits=root["edits"] as! [String:Any]
        let tone=edits["tone"] as! [String:Double]
        let wb=edits["white_balance"] as! [String:Any]
        require(root["schema_version"] as? Int==6 && wb["mode"] as? String=="relative","HDR JSON context missing")
        require(tone["contrast"]==1.3 && tone["highlights"] == -0.2 && tone["shadows"]==0.4,"HDR canonical transfer units differ")
        require(!String(decoding:data,as:UTF8.self).contains("headroom"),"display/source headroom entered a recipe")
        for edge in [0,-1,65536] {
            do { _ = try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_FINAL,longEdge:edge); fatalError("invalid edge accepted") }
            catch HDRRequestError.invalidSettings {}
        }
        settings.mode = .sdr
        do { _ = try makeHDRRequest(settings:settings,intent:SONY2FUJI_INTENT_FINAL); fatalError("SDR mode entered HDR") }
        catch HDRRequestError.invalidSettings {}
        print("PASS shared HDR native request and v6 logical mapping")
    }
}
