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

        // 改为对齐 Mac/iOS/Android 三端的新契约（WP-2 D1）：
        // 旧断言锁定了 FromSnapshot 在反序列化阶段直接拒绝未知 ProRAWDecodeVersion 的错误实现，
        // 导致带休眠未来版本字段的记录连 SDR 打开、编辑、保存都被阻断。新契约允许反序列化与 SDR 读写
        // 原样保留休眠字段，仅在进入或实际使用 ProRAW HDR（开启 HDR / 渲染 / 导出 / 同步）时拒绝。
        var json = JsonNode.Parse(JsonSerializer.Serialize(settings.Capture()))!.AsObject();
        json["ProRAWDecodeVersion"] = 99;
        var unknown = JsonSerializer.Deserialize<AdjustmentSnapshot>(json.ToJsonString())!;
        var restoredUnknown = unknown.Restore();
        check(restoredUnknown.IsHDREditing && restoredUnknown.ProRAWDecodeVersion == 99,
            "Unknown ProRAW decoder revision deserializes and restores verbatim without eager FromSnapshot rejection");

        var sdrDormant = restoredUnknown.Clone();
        sdrDormant.SetHDRMode(false, sourceIsHDR: true, cameraRaw: true, proRAW: true);
        sdrDormant.Set(Parameter.Exposure, 0.6);
        sdrDormant.RequireActiveHDRDecodeVersion();
        sdrDormant.RequireActiveHDRDecodeVersion(sourceIsProRAW: true);
        check(!sdrDormant.IsHDREditing && sdrDormant.ProRAWDecodeVersion == 99,
            "Turning HDR off and editing SDR preserve dormant ProRAWDecodeVersion verbatim");

        var tempRoot = Path.Combine(Path.GetTempPath(), "rawlab-proraw-dormant-model-" + Guid.NewGuid());
        Directory.CreateDirectory(tempRoot);
        try
        {
            var dng = Path.Combine(tempRoot, "photo.dng");
            File.WriteAllText(dng, "proraw-fixture");
            var storeDir = Path.Combine(tempRoot, "edits");
            var store = new EditStore(storeDir);
            store.Save(dng, sdrDormant.Capture(), null);
            var reopened = new EditStore(storeDir);
            var loaded = reopened.ReadState(dng);
            check(loaded.Edit?.Settings.ProRAWDecodeVersion == 99 &&
                loaded.Edit.Settings.Restore()[Parameter.Exposure] == 0.6,
                "EditStore reads SDR record with unknown ProRAWDecodeVersion verbatim");
            var editedSdr = loaded.Edit!.Settings.Restore();
            editedSdr.Set(Parameter.Exposure, 1.1);
            var editedSaved = new SavedEdit(loaded.Identity, editedSdr.Capture(), null);
            reopened.SaveState(loaded.Identity, editedSaved);
            var rawStored = JsonNode.Parse(File.ReadAllText(Path.Combine(storeDir, "edits.json")))!["Records"]![Path.GetFullPath(dng)]!["Settings"]!;
            check(rawStored["ProRAWDecodeVersion"]?.GetValue<int>() == 99 &&
                new EditStore(storeDir).Find(dng)?.Settings.ProRAWDecodeVersion == 99,
                "Saving SDR edits preserves unknown ProRAWDecodeVersion verbatim on disk");

            var partialReset = EditorAdjustmentRules.PrepareReset(
                new EditorResetScope(EditorResetKind.Group, Group: EditorAdjustmentGroup.Light), editedSaved);
            check(partialReset.Status == EditorResetStatus.Ready &&
                partialReset.Candidate!.Settings.ProRAWDecodeVersion == 99,
                "Partial SDR group reset preserves dormant ProRAWDecodeVersion");

            var editedHdr = restoredUnknown.Clone();
            editedHdr.Set(Parameter.Exposure, 1.0);
            var hdrAllReset = EditorAdjustmentRules.PrepareReset(
                new EditorResetScope(EditorResetKind.All), new SavedEdit(loaded.Identity, editedHdr.Capture(), null));
            check(hdrAllReset.Status == EditorResetStatus.Ready &&
                hdrAllReset.Candidate!.Settings.ProRAWDecodeVersion == 99,
                "Active HDR all-reset preserves ProRAWDecodeVersion");

            // SDR 模式下「重置全部调整」只重置激活的 SDR 快照，保留休眠的 ProRAWDecodeVersion 与 HDR 快照。
            var sdrAllReset = EditorAdjustmentRules.PrepareReset(new EditorResetScope(EditorResetKind.All), editedSaved);
            check(sdrAllReset.Status == EditorResetStatus.Ready &&
                sdrAllReset.Candidate!.Settings.ProRAWDecodeVersion == 99 &&
                sdrAllReset.Candidate.Settings.HDR == editedSaved.Settings.HDR &&
                !EditorAdjustmentRules.IsModified(new EditorResetScope(EditorResetKind.All), sdrAllReset.Candidate),
                "Real SDR all-reset preserves dormant ProRAWDecodeVersion and HDR snapshot and clears modified state");

            var sdrJob = BatchJob.Create(dng, editedSdr.Capture(), null, "SDR");
            sdrJob.SourceIsProRAW = true;
            sdrJob.Validate();
            check(true, "SDR batch preflight admits dormant unknown ProRAWDecodeVersion");
        }
        finally { Directory.Delete(tempRoot, true); }

        try
        {
            sdrDormant.SetHDRMode(true, sourceIsHDR: true, cameraRaw: true, proRAW: true);
            check(false, "Entering ProRAW HDR rejects unknown ProRAWDecodeVersion");
        }
        catch (HDRModeException error)
        {
            check(error.Failure == HDRModeFailure.InvalidSettings,
                "Entering ProRAW HDR rejects unknown ProRAWDecodeVersion");
        }

        foreach (var proRAWSource in new bool?[] { null, true, false })
        {
            try
            {
                restoredUnknown.RequireActiveHDRDecodeVersion(proRAWSource);
                check(false, "Active HDR render gate rejects unknown ProRAWDecodeVersion");
            }
            catch (HDRModeException error)
            {
                check(error.Failure == HDRModeFailure.InvalidSettings,
                    "Active HDR render gate rejects unknown ProRAWDecodeVersion");
            }
        }

        if (typeof(Adjustments).Assembly.GetType("RawLab.Windows.RenderEngine")
                ?.GetMethod("ValidateHDRRender", Static) is { } validateRender)
        {
            try
            {
                validateRender.Invoke(null, [restoredUnknown, true]);
                check(false, "RenderEngine.ValidateHDRRender rejects unknown ProRAWDecodeVersion");
            }
            catch (TargetInvocationException wrapped) when (wrapped.InnerException is HDRModeException error)
            {
                check(error.Failure == HDRModeFailure.InvalidSettings,
                    "RenderEngine.ValidateHDRRender rejects unknown ProRAWDecodeVersion");
            }
        }

        if (TryFindProjectRoot() is { } projectRoot)
        {
            var renderEngineSource = File.ReadAllText(Path.Combine(projectRoot, "RenderEngine.cs"));
            check(CountOccurrences(renderEngineSource, "ValidateHDRRender(settings)") >= 4 &&
                CountOccurrences(renderEngineSource, "ValidateHDRRender(settings, ") >= 3,
                "RenderEngine gates RenderPreview, RenderCore, RenderHDR, AutoExposureCore and SampleHslCore with ValidateHDRRender");
        }

        var unknownHdrJob = BatchJob.Create("photo.dng", unknown, null, "HDR");
        unknownHdrJob.SourceIsProRAW = true;
        try
        {
            unknownHdrJob.Validate();
            check(false, "ProRAW HDR batch rejects unknown ProRAWDecodeVersion");
        }
        catch (InvalidDataException)
        {
            check(true, "ProRAW HDR batch rejects unknown ProRAWDecodeVersion");
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

    private static string? TryFindProjectRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "RawLabWindows.csproj"))) return directory.FullName;
        return null;
    }

    private static int CountOccurrences(string text, string value)
    {
        var count = 0;
        for (var index = 0; (index = text.IndexOf(value, index, StringComparison.Ordinal)) >= 0; index += value.Length)
            count++;
        return count;
    }
}
