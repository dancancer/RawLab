using System.IO;

namespace RawLab.Windows;

internal static class PhotoInput
{
    internal static readonly HashSet<string> RawExtensions = new("arw arq dng nef nrw cr2 cr3 crw raf rw2 rwl orf pef srw raw 3fr fff iiq mos x3f".Split(' '),StringComparer.OrdinalIgnoreCase);
    internal static readonly HashSet<string> RasterExtensions = new("jpg jpeg png tif tiff heic heif".Split(' '),StringComparer.OrdinalIgnoreCase);
    internal static bool IsRaw(string path) => RawExtensions.Contains(Path.GetExtension(path).TrimStart('.'));
    internal static bool IsRaster(string path) => RasterExtensions.Contains(Path.GetExtension(path).TrimStart('.'));
    internal static bool IsHDRContainer(string path) => Path.GetExtension(path).TrimStart('.').Equals("heic", StringComparison.OrdinalIgnoreCase) ||
        Path.GetExtension(path).TrimStart('.').Equals("heif", StringComparison.OrdinalIgnoreCase) ||
        Path.GetExtension(path).TrimStart('.').Equals("jpg", StringComparison.OrdinalIgnoreCase) ||
        Path.GetExtension(path).TrimStart('.').Equals("jpeg", StringComparison.OrdinalIgnoreCase);

    // A probe result other than NOT_HDR is deliberately surfaced to the caller;
    // malformed gain-map metadata must never silently become an SDR import.
    internal static HDRProbeState ProbeHDR(string path, out HDRSourceInfo? info)
    {
        if (!IsHDRContainer(path)) { info = null; return HDRProbeState.NotHDR; }
        return HDRNative.Probe(path, out info);
    }

    internal static Adjustments PrepareInputSettings(string path,Adjustments value)
    {
        if(!IsRaster(path))return value;
        var prepared=value.Clone();
        prepared.ExposureMode=2;
        // HDR relative white balance is independent from the legacy raster WB;
        // preparing a raster input must not reset an active HDR record.
        if (!prepared.IsHDREditing) { prepared.ResolveWhiteBalance(null); prepared.ResetWhiteBalance(); }
        prepared.Lens=new(false,false,false);
        return prepared;
    }

    internal static Adjustments PrepareHDRInputSettings(string path, Adjustments value)
    {
        if (ProbeHDR(path, out var info) != HDRProbeState.Supported) return value;
        var prepared = value.Clone();
        if (prepared.HDR == null)
            prepared.HDR = HDRSettings.Enabling(null, HDRSettings.FromSdr(prepared), info?.IsHDR == true);
        return prepared;
    }

    internal static Adjustments PrepareBatchSettings(string source,string target,Adjustments value)
    {
        if (IsHDRContainer(source)) value = PrepareHDRInputSettings(source, value);
        if(!IsRaster(source) || !IsRaw(target))return value;
        var recipeTint=value.MasterRecipeID == null ? (double?)null : value[Parameter.Tint];
        var prepared=PrepareInputSettings(source,value);
        prepared.ExposureMode=1;
        if(recipeTint is {} tint)prepared.Set(Parameter.Tint,tint);
        return prepared;
    }
}
