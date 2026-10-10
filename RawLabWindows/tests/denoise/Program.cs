using RawLab.Windows;
using System.Runtime.InteropServices;

static void Check(bool value,string message) { if(!value)throw new Exception(message);Console.WriteLine("PASS: "+message); }
var settings=new Adjustments();
Check(settings.Denoise==new DenoiseSettings(false,0,46,50),"Default is off with texture-preserving strengths");
Check(settings.Effects==new PhotoEffectsSettings(),"Photo effects use canonical disabled defaults");
Check(settings.DisplayChromaDenoise==0,"Display chroma denoise defaults off independently of wavelet chroma");
var signedEffects=PhotoEffectSpec.For(PhotoEffectParameter.VignetteAmount);
Check(PhotoEffectSpec.For(PhotoEffectParameter.VignetteMidpoint).Value(.005)==1 && signedEffects.Value(.4975)==-1,
    "Photo effect slider rounds half steps away from zero");
settings.SetEffect(PhotoEffectParameter.VignetteAmount,.5);
Check(settings.Effects.VignetteAmount==1,"Photo effect input rounds positive half steps away from zero");
settings.SetEffect(PhotoEffectParameter.VignetteAmount,-.5);
Check(settings.Effects.VignetteAmount==-1,"Photo effect input rounds negative half steps away from zero");
settings.Denoise=DenoiseSettings.Clean;
Check(settings.Denoise==new DenoiseSettings(true,10,72,100),"Clean preset retains light luminance grain");
settings.SetEffect(PhotoEffectParameter.VignetteAmount,-40);
settings.SetEffect(PhotoEffectParameter.VignetteMidpoint,20);
settings.SetEffect(PhotoEffectParameter.GrainAmount,65);
settings.SetEffect(PhotoEffectParameter.GrainSize,70);
Check(settings.Effects==new PhotoEffectsSettings(-40,20,0,50,0,65,70,50),"Photo effects retain all eight parameters");
settings.SetEffect(PhotoEffectParameter.VignetteAmount,0);
Check(settings.Effects.VignetteMidpoint==20 && settings.Effects != new PhotoEffectsSettings(),"Zero vignette amount preserves auxiliary values and remains dirty");
settings.SetEffect(PhotoEffectParameter.VignetteAmount,-40);
settings.SetEffect(PhotoEffectParameter.GrainAmount,1000);
Check(settings.Effects.GrainAmount==100,"Photo effect values clamp to their canonical range");
settings.SetEffect(PhotoEffectParameter.VignetteRoundness,-1000);
Check(settings.Effects.VignetteRoundness==-100,"Signed photo effect values clamp to their canonical range");
var snapshot=settings.Clone();
settings.Denoise=settings.Denoise with {Enabled=false};
Check((settings.Denoise with {Enabled=true})==snapshot.Denoise,"Disable retains strengths and clones stay independent");
Check(snapshot.Effects==settings.Effects,"Clones retain immutable photo effects");
settings.DisplayChromaDenoise=2;
Check(settings.DisplayChromaDenoise==2 && settings.Denoise.Chroma==72,"Display chroma denoise is distinct from wavelet chroma");
var config=snapshot.Denoise.NativeConfig();
Check(Marshal.SizeOf<Native.WaveletConfig>()==24 && config.Version==1 && config.StructSize==24 &&
      config.Enabled==1 && config.Luma==10 && config.Chroma==72 && config.Coarse==100,"Additive native ABI mapping");
var effectsConfig=snapshot.Effects.NativeConfig();
Check(Marshal.SizeOf<Native.PhotoEffectsConfig>()==40 && effectsConfig.Version==1 && effectsConfig.StructSize==40 &&
      effectsConfig.VignetteAmount==-40 && effectsConfig.VignetteMidpoint==20 && effectsConfig.GrainAmount==100,
      "Versioned forty-byte photo effects ABI mapping");
var serialized=System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(settings.Capture()))!.AsObject();
serialized.Remove("Effects"); serialized.Remove("DisplayChromaDenoise");
var legacy=System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(serialized.ToJsonString())!.Restore();
Check(legacy.Effects==new PhotoEffectsSettings() && legacy.DisplayChromaDenoise==0,"Old snapshots default missing effects and display chroma to off");
settings.ResetAll();Check(settings.Denoise==new DenoiseSettings(),"Reset all disables denoising");
Check(settings.Effects==new PhotoEffectsSettings() && settings.DisplayChromaDenoise==0,"Reset all restores effects and display chroma defaults");
settings.Denoise=DenoiseSettings.Clean;settings.ResetGroup("细节");
Check(!settings.Denoise.Enabled,"Detail group reset disables denoising");
Check(settings.DisplayChromaDenoise==0,"Detail group reset disables display chroma denoise");
foreach(var invalid in new[]{-1d,101d,double.NaN,double.PositiveInfinity}) {
    try { (new DenoiseSettings(true,invalid,46,50)).NativeConfig();throw new Exception("Invalid value accepted"); }
    catch(ArgumentOutOfRangeException) { }
}
foreach(var invalid in new[]{-101d,101d,double.NaN,double.PositiveInfinity}) {
    try { (new PhotoEffectsSettings(invalid,50,0,50,0,0,25,50)).NativeConfig();throw new Exception("Invalid effect value accepted"); }
    catch(ArgumentOutOfRangeException) { }
}
Console.WriteLine("PASS: Nonfinite and out-of-range values rejected");
