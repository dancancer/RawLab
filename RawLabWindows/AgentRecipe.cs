using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

internal sealed partial class RenderEngine
{
    public string AgentRecipe(string path,Adjustments settings,string? look,string output,int? longEdge=null)
    {
        if(settings.AIDenoiseEnabled)throw new NotSupportedException(Loc.Text("Agent 配方不支持 AI 降噪，请先关闭 AI 降噪。"));
        var state=PrepareRecipe(path,settings);
        var raster=LibraryEntry.IsRaster(path);
        var request=state.Request(path,look,0,output,longEdge);
        var hsl=state.RenderHsl.NativeConfig();var effects=state.Effects.NativeConfig();
        var denoise=state.Denoise.NativeConfig();var geometry=state.Geometry.NativeConfig();
        var perspective=state.Geometry.NativePerspectiveConfig();
        object whiteBalance=raster ? new {mode="none"} : request.WbMode==3
            ? new {mode="temperature",temperature_kelvin=request.Temperature,tint=request.Tint}
            : new {mode="camera"};
        var exposure=state.ExposureMode switch{0=>"scene",1=>"preview",2=>"sensor",_=>throw new ArgumentOutOfRangeException(nameof(settings))};
        var format=ExportFormatExtensions.FromPath(output) switch{ExportFormat.Jpeg=>"jpeg",ExportFormat.Png=>"png",ExportFormat.RenderedDng=>"dng",_=>throw new ArgumentOutOfRangeException(nameof(output))};
        object size=longEdge is {} edge ? new{mode="limit_long_edge",long_edge=edge} : new{mode="native"};
        var atmosphere=state.RenderAtmosphere.NativeConfig();
        var toneControls=state.RenderToneControls.NativeConfig();
        var tone=new Dictionary<string,object> {
            ["contrast"]=Math.Clamp(request.Contrast,0,2),["saturation"]=Math.Clamp(request.Saturation,0,2),
            ["highlights"]=Math.Clamp(request.Highlights,-1,1),["shadows"]=Math.Clamp(request.Shadows,-1,1),["s_curve"]=Math.Clamp(request.ToneCurve,-1,1)
        };
        tone["curve"] = state.RenderCurve;
        if(toneControls.BlackPoint!=0)tone["black_point"]=toneControls.BlackPoint;
        if(toneControls.WhitePoint!=0)tone["white_point"]=toneControls.WhitePoint;
        var document=new{
            schema_version=5,
            processing=ProcessingIdentity.Require(state.Processing),
            input=new{path=Path.GetFullPath(path),type=raster ? "raster" : "raw"},
            edits=new{
                exposure=new{mode=exposure,ev=request.ExposureEv,brightness=request.Brightness},
                white_balance=whiteBalance,
                look=new{path=look==null ? null : Path.GetFullPath(look),strength=(float)state[Parameter.Strength]/100},
                tone,
                detail=new{sharpening=Math.Clamp(request.Sharpening,0,2)},
                hsl=new{hue=hsl.Hue,saturation=hsl.Saturation,lightness=hsl.Lightness},
                effects=new{vignette_amount=effects.VignetteAmount,vignette_midpoint=effects.VignetteMidpoint,
                    vignette_roundness=effects.VignetteRoundness,vignette_feather=effects.VignetteFeather,vignette_highlights=effects.VignetteHighlights,
                    grain_amount=effects.GrainAmount,grain_size=effects.GrainSize,grain_roughness=effects.GrainRoughness,clarity=atmosphere.Clarity,dehaze=atmosphere.Dehaze},
                denoise=new{raw_level=0,chroma_mode=state.DisplayChromaDenoise,wavelet=new{enabled=denoise.Enabled!=0,
                    luma=denoise.Enabled!=0 ? denoise.Luma : 0,chroma=denoise.Enabled!=0 ? denoise.Chroma : 46,coarse=denoise.Enabled!=0 ? denoise.Coarse : 50}},
                lens_correction=new{distortion=state.Lens.Distortion,tca=state.Lens.Tca,auto_crop=state.Lens.AutoCrop,
                    profile_id=string.IsNullOrEmpty(state.Lens.CoreProfileId) ? null : state.Lens.CoreProfileId},
                geometry=new{crop=new{x=geometry.CropX,y=geometry.CropY,width=geometry.CropWidth,height=geometry.CropHeight},
                    quarter_turns=geometry.QuarterTurns,flip_horizontal=geometry.FlipHorizontal!=0,flip_vertical=geometry.FlipVertical!=0,
                    straighten_degrees=geometry.StraightenDegrees,perspective=new{horizontal=perspective.Horizontal,vertical=perspective.Vertical}}
            },
            output=new{path=Path.GetFullPath(output),format,jpeg_quality=request.JpegQuality,size}
        };
        var options=new JsonSerializerOptions{WriteIndented=true};
        var json=JsonSerializer.Serialize(document,options);
        _ = state.RenderGrading.NativeConfig();
        if(toneControls.Vibrance==0 && state.RenderGrading.IsDefault)return json;
        var result=System.Text.Json.Nodes.JsonNode.Parse(json)!;
        if(toneControls.Vibrance!=0) result["edits"]!["color"]=new System.Text.Json.Nodes.JsonObject { ["vibrance"]=toneControls.Vibrance };
        if (!state.RenderGrading.IsDefault) {
            var grading = new System.Text.Json.Nodes.JsonObject();
            foreach (var zone in Enum.GetValues<ColorGradingZone>()) {
                var wheel = state.RenderGrading[zone];
                grading[zone.ToString().ToLowerInvariant()] = new System.Text.Json.Nodes.JsonObject {
                    ["hue"] = wheel.NativeHue, ["saturation"] = (float)wheel.Saturation };
            }
            result["edits"]!["color_grading"] = grading;
        }
        return result.ToJsonString(options);
    }
}
