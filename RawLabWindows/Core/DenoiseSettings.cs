namespace RawLab.Windows;

public sealed record DenoiseSettings(bool Enabled=false,double Luma=0,double Chroma=46,double Coarse=50)
{
    public static DenoiseSettings Detail => new(true);
    public static DenoiseSettings Clean => new(true,10,72,100);
    public int Preset => (this with {Enabled=true})==Detail ? 0 : (this with {Enabled=true})==Clean ? 1 : 2;
    internal Native.WaveletConfig NativeConfig()
    {
        if(new[]{Luma,Chroma,Coarse}.Any(v=>!double.IsFinite(v) || v<0 || v>100))
            throw new ArgumentOutOfRangeException(nameof(Luma),"Denoise strengths must be finite and between 0 and 100.");
        return new(){Version=1,StructSize=24,Enabled=Enabled ? 1 : 0,Luma=(float)Luma,Chroma=(float)Chroma,Coarse=(float)Coarse};
    }
}
