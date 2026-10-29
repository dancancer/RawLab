import Foundation

@main enum HDRAgentTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        let source=URL(fileURLWithPath:CommandLine.arguments[1])
        let cli=URL(fileURLWithPath:CommandLine.arguments[2])
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let engine=try RenderEngine(gpuMode:SONY2FUJI_GPU_OFF)
        var settings=Adjustments()
        settings.hdr=HDRSettings(); settings.hdr!.exposure=1.25; settings.hdr!.temperature=7200
        settings.hdr!.tint = -12; settings.hdr!.contrast=30; settings.hdr!.highlights=20
        settings.aiDenoiseEnabled=true
        let before=settings
        let output=directory.appendingPathComponent("edited.jpg")
        let recipe=directory.appendingPathComponent("recipe.json")
        try engine.agentRecipe(source,settings:settings,lut:URL(fileURLWithPath:"/inactive/look.cube"),
            output:output).write(to:recipe)
        require(settings==before,"Agent serialization changed dormant/native settings")
        let document=try JSONSerialization.jsonObject(with:Data(contentsOf:recipe)) as! [String:Any]
        let edits=document["edits"] as! [String:Any]
        require(document["schema_version"] as? Int==6,"Mac HDR Agent emitted old recipe")
        require(edits["look"]==nil && edits["denoise"]==nil,"inactive SDR adjustments entered HDR recipe")
        let sourceInfo=try HDRSourceInfo.probe(source)
        require(sourceInfo != nil && sourceInfo!.fingerprint.count==32,"Mac HDR source was not verified")
        let preview=try engine.render(source,settings:settings,lut:URL(fileURLWithPath:"/inactive/look.cube"),edge:32)!
        require(preview.hdr != nil && preview.image.width==32,"Mac preview did not use typed HDR rendering")
        require(preview.hdr!.image.isProxy,"Mac preview source lost proxy provenance")
        let nativeExport=directory.appendingPathComponent("native.jpg")
        _ = try engine.render(source,settings:settings,lut:nil,edge:nil,output:nativeExport)
        let nativeInfo=try HDRSourceInfo.probe(nativeExport)
        require(nativeInfo != nil,"Mac native export lost HDR")
        let sdrOutput=directory.appendingPathComponent("edited-sdr.jpg")
        _ = try engine.render(source,settings:settings,lut:nil,edge:nil,output:sdrOutput,exportFormat:.jpeg)
        let sdrInfo=try HDRSourceInfo.probe(sdrOutput)
        require(sdrInfo==nil,"Explicit SDR output retained an HDR gain map")
        let forced=try RenderEngine(gpuMode:SONY2FUJI_GPU_FORCE)
        var identity=Adjustments(); identity.hdr=HDRSettings()
        do { _ = try forced.render(source,settings:identity,lut:nil,edge:32); fatalError("identity bypassed Force policy") }
        catch let failure as HDRNativeError { require(failure.reason==UInt32(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU),"wrong Force rejection") }
        var sdr=settings; sdr.hdr?.mode = .sdr; sdr.aiDenoiseEnabled=false
        let sdrPreview=try engine.render(source,settings:sdr,lut:nil,edge:32)!
        require(sdrPreview.hdr==nil && sdrPreview.histogram.count==3,"SDR mode did not use the SDR base")
        do { _ = try engine.agentRecipe(source,settings:sdr,lut:nil,output:sdrOutput); fatalError("SDR-mode HDR generated an unusable v5 recipe") }
        catch is RenderError {}
        let process=Process(); process.executableURL=cli; process.arguments=["--recipe",recipe.path,"--json"]
        let pipe=Pipe(); process.standardOutput=pipe
        try process.run()
        let reply=try JSONSerialization.jsonObject(with:pipe.fileHandleForReading.readDataToEndOfFile()) as! [String:Any]
        process.waitUntilExit()
        require(process.terminationStatus==0 && reply["ok"] as? Bool==true,"Mac HDR Agent could not render through CLI")
        let exported=try HDRSourceInfo.probe(output)
        require(exported != nil && exported!.native.content_headroom>1,"Mac HDR Agent lost gain map")
        do {
            _ = try engine.agentRecipe(source,settings:settings,lut:nil,output:directory.appendingPathComponent("invalid.png"))
            fatalError("HDR Agent silently changed an SDR output choice into JPEG")
        } catch is RenderError {}
        print("PASS Mac HDR Agent source verification, inactive settings and v6 CLI export")
    }
}
