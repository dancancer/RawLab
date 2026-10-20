using System.IO;

namespace RawLab.Windows;

internal static class PhotoInput
{
    internal static readonly HashSet<string> RawExtensions = new("arw arq dng nef nrw cr2 cr3 crw raf rw2 rwl orf pef srw raw 3fr fff iiq mos x3f".Split(' '),StringComparer.OrdinalIgnoreCase);
    internal static readonly HashSet<string> RasterExtensions = new("jpg jpeg png tif tiff".Split(' '),StringComparer.OrdinalIgnoreCase);
    internal static bool IsRaw(string path) => RawExtensions.Contains(Path.GetExtension(path).TrimStart('.'));
    internal static bool IsRaster(string path) => RasterExtensions.Contains(Path.GetExtension(path).TrimStart('.'));

    internal static Adjustments PrepareInputSettings(string path,Adjustments value)
    {
        if(!IsRaster(path))return value;
        var prepared=value.Clone();
        prepared.ExposureMode=2;
        prepared.ResolveWhiteBalance(null);prepared.ResetWhiteBalance();
        prepared.Lens=new(false,false,false);
        return prepared;
    }

    internal static Adjustments PrepareBatchSettings(string source,string target,Adjustments value)
    {
        if(!IsRaster(source) || !IsRaw(target))return value;
        var recipeTint=value.MasterRecipeID == null ? (double?)null : value[Parameter.Tint];
        var prepared=PrepareInputSettings(source,value);
        prepared.ExposureMode=1;
        if(recipeTint is {} tint)prepared.Set(Parameter.Tint,tint);
        return prepared;
    }
}
