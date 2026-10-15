using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

internal sealed partial class RenderEngine
{
    public string AgentRecipe(string path,Adjustments settings,string? look,string output,int? longEdge=null)
    {
        var state=PrepareRecipe(path,settings);
        var request=state.Request(path,look,0,output,longEdge);
        var hsl=state.RenderHsl.NativeConfig();var effects=state.Effects.NativeConfig();
        var denoise=state.Denoise.NativeConfig();var geometry=state.Geometry.NativeConfig();
        var perspective=state.Geometry.NativePerspectiveConfig();
        object whiteBalance=request.WbMode==3
            ? new {mode="temperature",temperature_kelvin=request.Temperature,tint=request.Tint}
            : new {mode="camera"};
        var exposure=state.ExposureMode switch{0=>"scene",1=>"preview",2=>"sensor",_=>throw new ArgumentOutOfRangeException(nameof(settings))};
        var format=ExportFormatExtensions.FromPath(output) switch{ExportFormat.Jpeg=>"jpeg",ExportFormat.Png=>"png",ExportFormat.RenderedDng=>"dng",_=>throw new ArgumentOutOfRangeException(nameof(output))};
        object size=longEdge is {} edge ? new{mode="limit_long_edge",long_edge=edge} : new{mode="native"};
        var document=new{
            schema_version=4,
            input=new{path=Path.GetFullPath(path),type="raw"},
            edits=new{
                exposure=new{mode=exposure,ev=request.ExposureEv,brightness=request.Brightness},
                white_balance=whiteBalance,
                look=new{path=look==null ? null : Path.GetFullPath(look),strength=(float)state[Parameter.Strength]/100},
                tone=new{contrast=Math.Clamp(request.Contrast,0,2),saturation=Math.Clamp(request.Saturation,0,2),
                    highlights=Math.Clamp(request.Highlights,-1,1),shadows=Math.Clamp(request.Shadows,-1,1),s_curve=Math.Clamp(request.ToneCurve,-1,1)},
                detail=new{sharpening=Math.Clamp(request.Sharpening,0,2)},
                hsl=new{hue=hsl.Hue,saturation=hsl.Saturation,lightness=hsl.Lightness},
                effects=new{vignette_amount=effects.VignetteAmount,vignette_midpoint=effects.VignetteMidpoint,
                    vignette_roundness=effects.VignetteRoundness,vignette_feather=effects.VignetteFeather,vignette_highlights=effects.VignetteHighlights,
                    grain_amount=effects.GrainAmount,grain_size=effects.GrainSize,grain_roughness=effects.GrainRoughness},
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
        return JsonSerializer.Serialize(document,new JsonSerializerOptions{WriteIndented=true});
    }
}
