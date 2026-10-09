using RawLab.Windows;
using System.Runtime.InteropServices;

static void Check(bool value,string message) { if(!value)throw new Exception(message);Console.WriteLine("PASS: "+message); }
var settings=new Adjustments();
Check(settings.Denoise==new DenoiseSettings(false,0,46,50),"Default is off with texture-preserving strengths");
settings.Denoise=DenoiseSettings.Clean;
Check(settings.Denoise==new DenoiseSettings(true,10,72,100),"Clean preset retains light luminance grain");
var snapshot=settings.Clone();
settings.Denoise=settings.Denoise with {Enabled=false};
Check((settings.Denoise with {Enabled=true})==snapshot.Denoise,"Disable retains strengths and clones stay independent");
var config=snapshot.Denoise.NativeConfig();
Check(Marshal.SizeOf<Native.WaveletConfig>()==24 && config.Version==1 && config.StructSize==24 &&
      config.Enabled==1 && config.Luma==10 && config.Chroma==72 && config.Coarse==100,"Additive native ABI mapping");
settings.ResetAll();Check(settings.Denoise==new DenoiseSettings(),"Reset all disables denoising");
settings.Denoise=DenoiseSettings.Clean;settings.ResetGroup("细节");
Check(!settings.Denoise.Enabled,"Detail group reset disables denoising");
foreach(var invalid in new[]{-1d,101d,double.NaN,double.PositiveInfinity}) {
    try { (new DenoiseSettings(true,invalid,46,50)).NativeConfig();throw new Exception("Invalid value accepted"); }
    catch(ArgumentOutOfRangeException) { }
}
Console.WriteLine("PASS: Nonfinite and out-of-range values rejected");
