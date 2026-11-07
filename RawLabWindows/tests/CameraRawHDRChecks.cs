using RawLab.Windows;
using System.IO;
using System.Text.Json;

internal static class CameraRawHDRChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    internal static void Run()
    {
        CapabilityIsSeparateFromGainMapContainers();
        CameraModeUsesNeutralHDRSnapshot();
        CameraStampIsUsedWhenProbeHasNoDigest();
        Console.WriteLine("PASS: Windows camera RAW HDR model");
    }

    private static void CapabilityIsSeparateFromGainMapContainers()
    {
        Check(PhotoInput.IsRaw("photo.ARW") && PhotoInput.IsRaw("photo.dng") &&
            PhotoInput.IsRaw("photo.nef") && PhotoInput.IsRaw("photo.cr3"),
            "camera HDR uses the regular RAW routing");
        Check(!PhotoInput.IsHDRContainer("photo.ARW") && PhotoInput.IsHDRContainer("photo.heic"),
            "camera RAW capability stays separate from raster gain-map defaults");
    }

    private static void CameraModeUsesNeutralHDRSnapshot()
    {
        var state = new Adjustments { Denoise = DenoiseSettings.Clean };
        state.ResolveWhiteBalance((5200, 8));
        state.Set(Parameter.Exposure, .75);
        state.SetHDRMode(true, sourceIsHDR: true, cameraRaw: true);

        Check(state.IsHDREditing && state.HDR is { Mode: HDRMode.Hdr, Exposure: 0, Temperature: 6500, Tint: 0 },
            "camera HDR starts from a neutral HDR snapshot");
        Check(state.Capture().Values[(int)Parameter.Exposure] == .75 && state.AsShot == (5200, 8),
            "camera HDR retains the dormant SDR exposure and as-shot white balance");
        Check(state.Denoise == DenoiseSettings.Clean,
            "camera HDR retains the dormant RAW denoise settings");

        var cameraEdit = new SavedEdit(new("photo.arw", 1, 2, 3), state.Capture(), null);
        try
        {
            _ = AdjustmentTransfer.Capture(AdjustmentScope.All, cameraEdit,
                new AdjustmentTransferContext("photo.arw", true));
            throw new Exception("camera HDR preset transfer was not gated");
        }
        catch (AdjustmentTransferException error)
        {
            Check(error.Failure == AdjustmentFailure.Incompatible && error.Detail == "hdr.camera_raw",
                "a RAW source without HDR capability cannot capture a preset");
        }
        var context = new AdjustmentTransferContext("photo.arw",true,SupportsCameraHDR:true);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.All,cameraEdit,context);
        var prepared = AdjustmentTransfer.Prepare(payload,cameraEdit,context);
        Check(prepared.Settings.HDR == state.HDR && prepared.Settings.ProRAWDecodeVersion == null,
            "a capable camera RAW transfers its HDR snapshot independently of ProRAW");

        var batch = BatchJob.Create("photo.arw", state.Capture(), null, "HDR");
        try { batch.Validate(); throw new Exception("camera HDR batch was not gated"); }
        catch (InvalidDataException) { }
        batch.SourceSupportsCameraHDR = true;
        batch.Validate();
        Check(BatchHDRPreparation.Required(batch.Copy()),"capable camera RAW batch freezes each target");

        var reopened = JsonSerializer.Deserialize<AdjustmentSnapshot>(
            JsonSerializer.Serialize(state.Capture()))!.Restore();
        Check(reopened.IsHDREditing && reopened[Parameter.Exposure] == 0 &&
            reopened.Capture().Values[(int)Parameter.Exposure] == .75 &&
            reopened.AsShot == (5200, 8) && reopened.Denoise == DenoiseSettings.Clean,
            "camera HDR and RAW SDR snapshots survive persistence and reopen independently");

        state.Set(Parameter.Exposure, 1.25);
        state.SetHDRMode(false, sourceIsHDR: true, cameraRaw: true);
        Check(!state.IsHDREditing && state[Parameter.Exposure] == .75 && state.AsShot == (5200, 8),
            "turning camera HDR off restores the independent RAW SDR snapshot");
        state.SetHDRMode(true, sourceIsHDR: true, cameraRaw: true);
        Check(state[Parameter.Exposure] == 1.25,
            "turning camera HDR on again restores its durable HDR snapshot");
    }

    private static void CameraStampIsUsedWhenProbeHasNoDigest()
    {
        var info = new HDRSourceInfo(HDRProbeState.Supported, 24, 16, 1, HDRNative.ContainerCameraRaw,
            0, HDRNative.ColorSrgb, 0, HDRNative.HeadroomUnknown, new byte[32]);
        var first = info with { CameraStamp = new HDRFileStamp(10, 20, 30) };
        var second = first with { CameraStamp = new HDRFileStamp(10, 21, 30) };
        Check(first.IsCameraRaw && first.CacheIdentity != Convert.ToHexString(first.SourceSha256) &&
            first.CacheIdentity != second.CacheIdentity,
            "camera HDR cache identity uses the file stamp instead of the empty probe digest");
    }
}
