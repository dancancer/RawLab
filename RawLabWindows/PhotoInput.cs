using System.IO;

namespace RawLab.Windows;

internal static class PhotoInput
{
    internal static readonly HashSet<string> RawExtensions = new("arw arq dng nef nrw cr2 cr3 crw raf rw2 rwl orf pef srw raw 3fr fff iiq mos srf sr2 mrw kdc dcr erf x3f".Split(' '),StringComparer.OrdinalIgnoreCase);
    internal static readonly HashSet<string> RasterExtensions = new("jpg jpeg png tif tiff heic heif".Split(' '),StringComparer.OrdinalIgnoreCase);
    internal static bool IsRaw(string path) => RawExtensions.Contains(Path.GetExtension(path).TrimStart('.'));
    internal static bool IsX3f(string? path) => string.Equals(Path.GetExtension(path), ".x3f", StringComparison.OrdinalIgnoreCase);
    internal static bool IsNormalX3f(string? path, Adjustments settings) => IsX3f(path) && settings.X3fMode == X3fMode.Normal;
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

    internal static HDRProbeState ProbeCameraRaw(string path, out HDRSourceInfo? info)
    {
        if (!IsRaw(path)) { info = null; return HDRProbeState.NotHDR; }
        // DNG may be Apple ProRAW or an ordinary Bayer/linear RAW. Probe the
        // strict ProRAW identity first; a normal DNG then follows the existing
        // camera-RAW HDR path without being promoted by its extension.
        if (Path.GetExtension(path).Equals(".dng", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                if (HDRNative.ProbeProRAW(path, out info) == HDRProbeState.Supported)
                    return HDRProbeState.Supported;
            }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            catch (BadImageFormatException) { }
        }
        try { return HDRNative.ProbeCameraRaw(path, out info); }
        catch (EntryPointNotFoundException) { info = null; return HDRProbeState.NotHDR; }
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

    internal static bool IsHDRCameraAICandidate(HDRSourceInfo? info) =>
        info?.SupportsBayerDevelopment == true;

    internal static string? HDRCameraAIUnavailableHint(HDRSettings? settings, int gpuMode)
    {
        if (settings?.Mode != HDRMode.Hdr) return null;
        if (settings.CameraSettings.CameraProfile != null) return Loc.Text("请先清除 HDR 相机配置，再使用 AI 降噪。");
        if (settings.CameraSettings.FbddLevel != 0) return Loc.Text("请先关闭 FBDD，再使用 HDR AI 降噪。");
        return gpuMode == 2 ? Loc.Text("HDR 编辑目前使用 CPU。请将 GPU 模式设为自动或关闭。") : null;
    }

    internal static Adjustments PrepareHDRInputSettings(string path, Adjustments value)
    {
        if (ProbeHDR(path, out var info) != HDRProbeState.Supported) return value;
        var prepared = value.Clone();
        if (prepared.HDR == null)
            prepared.HDR = HDRSettings.Enabling(null, HDRSettings.FromSdr(prepared), info?.IsHDR == true);
        return prepared;
    }

    internal static X3fMode X3fDefaultMode(string path)
    {
        var status = Native.sony2fuji_x3f_default_mode(path, out var mode);
        Native.Check(status);
        return mode;
    }

    internal static Adjustments PrepareDefaultSettings(string path)
    {
        var prepared = PrepareInputSettings(path, new Adjustments());
        if (IsX3f(path)) prepared.X3fMode = X3fDefaultMode(path);
        return PrepareHDRInputSettings(path, prepared);
    }

    internal static Adjustments PrepareBatchSettings(string source,string target,Adjustments value)
    {
        if (IsRaster(target) && value.AIDenoiseEnabled && !value.IsHDREditing) {
            // 普通图片目标只关闭 AI 降噪；曝光、白平衡和镜头仍由渲染时的输入归一化处理，快照保持原样。
            var raster = value.Clone();
            raster.AIDenoiseEnabled = false;
            return raster;
        }
        if(!IsRaster(source) || !IsRaw(target))return value;
        var recipeTint=value.MasterRecipeID == null ? (double?)null : value[Parameter.Tint];
        var prepared=PrepareInputSettings(source,value);
        prepared.ExposureMode=1;
        if(recipeTint is {} tint)prepared.Set(Parameter.Tint,tint);
        return prepared;
    }
}
