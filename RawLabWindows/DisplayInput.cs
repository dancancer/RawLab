using System.IO;

namespace RawLab.Windows;

internal sealed partial class RenderEngine
{
    private Native.Buffer displayInput;
    private Stamp? inputStamp;
    internal long CachedDisplayBytes => checked((long)displayInput.Size);

    internal static Adjustments PrepareInputSettings(string path,Adjustments value)
    {
        if(!LibraryEntry.IsRaster(path))return value;
        var prepared=value.Clone();
        prepared.ExposureMode=2;
        prepared.ResolveWhiteBalance(null);prepared.ResetWhiteBalance();
        prepared.Lens=new(false,false,false);
        return prepared;
    }
    internal static Adjustments PrepareBatchSettings(string source,string target,Adjustments value)
    {
        if(!LibraryEntry.IsRaster(source) || !LibraryEntry.IsRaw(target))return value;
        var recipeTint=value.MasterRecipeID == null ? (double?)null : value[Parameter.Tint];
        var prepared=PrepareInputSettings(source,value);
        prepared.ExposureMode=1;
        if(recipeTint is {} tint)prepared.Set(Parameter.Tint,tint);
        return prepared;
    }
    private void EnsureInput(string path)
    {
        var info=new FileInfo(path);var stamp=new Stamp(info.FullName,info.Length,info.LastWriteTimeUtc.Ticks);
        if(inputStamp==stamp)return;
        var wasDisplay=displayInput.Data!=IntPtr.Zero;
        Native.sony2fuji_release_buffer(ref displayInput);
        if(inputStamp is {} previous && (wasDisplay || LibraryEntry.IsRaster(path) ||
            (previous.Path.Equals(stamp.Path,StringComparison.OrdinalIgnoreCase) && previous!=stamp)))
        {session.Dispose();session=new();InitializeSession();SetGpuMode(gpuMode);lensStamp=null;}
        inputStamp=null;
        if(LibraryEntry.IsRaster(path))Native.Check(Native.sony2fuji_load_display_image(path,ref displayInput));
        inputStamp=stamp;
    }
    private void SetInput(ref Native.Request request,string path)
    {
        if(!LibraryEntry.IsRaster(path))return;
        request.InputType=2;request.InputPixels=displayInput.Data;
        request.InputWidth=displayInput.Width;request.InputHeight=displayInput.Height;
        request.InputPixelFormat=displayInput.PixelFormat;request.InputColorSpace=0;request.InputIsLinear=0;
        request.WbMode=0;request.Temperature=6500;request.Tint=0;
    }
}
