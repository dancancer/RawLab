using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using RawLab.Windows;

internal static class ProRAWHDRChecks
{
    private static readonly BindingFlags Static = BindingFlags.Static | BindingFlags.NonPublic;

    internal static void Run(Action<bool, string> check)
    {
        SourceIdentity(check);
        ProRAWDecoderVersion(check);
        NativeEntrypoints(check);
        Console.WriteLine("PASS: Windows ProRAW HDR model");
    }

    private static void SourceIdentity(Action<bool, string> check)
    {
        var info = new HDRSourceInfo(HDRProbeState.Supported, 48, 32, 1, HDRNative.ContainerProRAW,
            1, HDRNative.ColorSrgb, 0, HDRNative.HeadroomUnknown, new byte[32]) {
            CameraStamp = new HDRFileStamp(10, 20, 30)
        };
        var changed = info with { CameraStamp = new HDRFileStamp(10, 21, 30) };
        check(info.IsProRAW && info.IsCameraRaw, "ProRAW is an explicit camera-RAW source, not a gain-map raster");
        check(info.CacheIdentity != changed.CacheIdentity && info.CacheIdentity.StartsWith("camera:", StringComparison.Ordinal),
            "ProRAW source-only cache identity uses the file stamp until decode returns SHA-256");
    }

    private static void ProRAWDecoderVersion(Action<bool, string> check)
    {
        var settings = new Adjustments();
        settings.SetHDRMode(true, sourceIsHDR: true, cameraRaw: true, proRAW: true);
        check(settings.IsHDREditing && settings.ProRAWDecodeVersion == 2,
            "Enabling ProRAW HDR persists decoder revision 2");

        var json = JsonNode.Parse(JsonSerializer.Serialize(settings.Capture()))!.AsObject();
        json["ProRAWDecodeVersion"] = 99;
        var unknown = JsonSerializer.Deserialize<AdjustmentSnapshot>(json.ToJsonString())!;
        try
        {
            _ = unknown.Restore();
            check(false, "Unknown ProRAW decoder revision is rejected before HDR restore");
        }
        catch (InvalidDataException)
        {
            check(true, "Unknown ProRAW decoder revision is rejected before HDR restore");
        }

        var job = BatchJob.Create("photo.dng", settings.Capture(), null, "HDR");
        job.SourceIsProRAW = true; // Persisted capability comes from the strict source probe at creation.
        try
        {
            job.Validate();
            check(true, "ProRAW HDR batch settings are admitted independently of generic camera RAW");
        }
        catch (InvalidDataException)
        {
            check(false, "ProRAW HDR batch settings are admitted independently of generic camera RAW");
        }

        var identity = new OriginalIdentity("photo.dng", 1, 2, 3);
        var source = new SavedEdit(identity, settings.Capture(), null);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.All, source,
            new AdjustmentTransferContext("source", true, IsProRAW: true));
        var target = new SavedEdit(identity, settings.Capture(), null);
        var transferred = AdjustmentTransfer.Prepare(payload, target,
            new AdjustmentTransferContext("target", true, IsProRAW: true));
        check(transferred.Settings.ProRAWDecodeVersion == HDRNative.ProRAWDecodeVersion,
            "ProRAW HDR transfer preserves the target decoder identity");
        try
        {
            _ = AdjustmentTransfer.Capture(AdjustmentScope.All, source,
                new AdjustmentTransferContext("bayer", true));
            check(false, "Generic Bayer RAW HDR transfer remains gated");
        }
        catch (AdjustmentTransferException error)
        {
            check(error.Detail == "hdr.camera_raw", "Generic Bayer RAW HDR transfer remains gated");
        }
    }

    private static void NativeEntrypoints(Action<bool, string> check)
    {
        foreach (var name in new[] {
            "sony2fuji_hdr_probe_proraw", "sony2fuji_hdr_decode_proraw", "sony2fuji_hdr_export_proraw",
            "sony2fuji_hdr_export_stream", "sony2fuji_session_set_cancellation_callback"
        })
        {
            var method = typeof(Native).GetMethod(name, Static);
            var entryPoint = method?.GetCustomAttribute<DllImportAttribute>()?.EntryPoint;
            check(method != null && (entryPoint == null || entryPoint == name), "P/Invoke declares " + name);
        }
    }
}
