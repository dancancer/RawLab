using System.IO;

namespace RawLab.Windows;

internal sealed partial class RenderEngine
{
    private Native.Buffer displayInput;
    private Stamp? inputStamp;
    internal long CachedDisplayBytes => checked((long)displayInput.Size);

    internal static Adjustments PrepareInputSettings(string path,Adjustments value) =>
        PhotoInput.PrepareInputSettings(path,value);
    internal static Adjustments PrepareBatchSettings(string source,string target,Adjustments value) =>
        PhotoInput.PrepareBatchSettings(source,target,value);
    private void EnsureInput(string path)
    {
        var info=new FileInfo(path);var stamp=new Stamp(info.FullName,info.Length,info.LastWriteTimeUtc.Ticks);
        if(inputStamp==stamp)return;
        var wasDisplay=displayInput.Data!=IntPtr.Zero;
        Native.sony2fuji_release_buffer(ref displayInput);
        if(inputStamp is {} previous && (wasDisplay || LibraryEntry.IsRaster(path) ||
            (previous.Path.Equals(stamp.Path,StringComparison.OrdinalIgnoreCase) && previous!=stamp)))
        {RecreateSession();lensStamp=null;}
        inputStamp=null;
        if(LibraryEntry.IsRaster(path))Native.CheckWithoutSession(Native.sony2fuji_load_display_image(path,ref displayInput));
        inputStamp=stamp;
    }
    private void SetInput(ref Native.RenderOptions options, string path)
    {
        if (!LibraryEntry.IsRaster(path)) return;
        options.InputType = 2; options.InputPixels = displayInput.Data;
        options.InputWidth = displayInput.Width; options.InputHeight = displayInput.Height;
        options.InputPixelFormat = displayInput.PixelFormat; options.InputColorSpace = 0; options.InputIsLinear = 0;
    }
    private static void SetInput(ref Native.RenderOptions options, Native.Buffer input)
    {
        options.InputType = 2; options.InputPixels = input.Data; options.InputWidth = input.Width;
        options.InputHeight = input.Height; options.InputPixelFormat = input.PixelFormat;
        options.InputColorSpace = 0; options.InputIsLinear = 0;
    }
}
