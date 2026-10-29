using System.Text.Json;
using RawLab.Windows;

internal static class HDRChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    internal static void Run()
    {
        SettingsUseSwiftKeysAndRejectUnknownFields();
        SnapshotKeepsInactiveHDRIndependent();
        EnablingRejectsUnsupportedLegacyState();
        ResetOnlyTouchesHDRRecord();
        TransferUsesHDRPayloadV2AndFloatMappings();
        NativeLayoutsMatchHDRContract();
        LogicalFieldsCrossFamiliesWithoutCopyingGeometryOrInactiveState();
        BatchPreparationPreservesTheFrozenModeWithoutReopeningItsSource();
        Check(JsonSerializer.Deserialize<ExportFormat>("1")==ExportFormat.Png &&
            JsonSerializer.Deserialize<ExportFormat>("2")==ExportFormat.RenderedDng,
            "Existing journal enum numbers keep PNG and DNG meanings");
        Console.WriteLine("PASS: Windows HDR settings, snapshot isolation, transfer v2 and ABI model");
    }

    private static void BatchPreparationPreservesTheFrozenModeWithoutReopeningItsSource()
    {
        foreach(var hdr in new HDRSettings?[]{null,new() {Mode=HDRMode.Sdr,Temperature=7400},new() {Mode=HDRMode.Hdr}}) {
            var settings=new Adjustments {HDR=hdr};settings.Set(Parameter.Exposure,.5);
            var snapshot=settings.Capture();
            foreach(var target in new[]{"ordinary.jpg","target.dng"}) {
                var prepared=PhotoInput.PrepareBatchSettings("frozen-source.jpg",target,settings);
                Check(prepared.HDR==snapshot.HDR && prepared.IsHDREditing==(hdr?.Mode==HDRMode.Hdr),
                    "Batch target preparation must preserve the frozen HDR/SDR mode without probing the source");
                Check(prepared[Parameter.Exposure]==.5 && settings.Capture().SameAs(snapshot),
                    "Batch input normalization retains exposure and does not mutate the frozen source");
            }
        }
    }

    private static void LogicalFieldsCrossFamiliesWithoutCopyingGeometryOrInactiveState()
    {
        var id=new OriginalIdentity("hdr.jpg",1,2,3);
        var settings=new Adjustments {HDR=new HDRSettings {Exposure=.5,Geometry=new(QuarterTurns:1)}};
        var saved=new SavedEdit(id,settings.Capture(),null);
        var modified=AdjustmentTransfer.Capture(AdjustmentScope.Modified,saved,new("hdr.jpg",false));
        Check(!modified.Fields.Any(field=>field.Group()=="geometry"),"HDR modified scope excludes source geometry");
        var legacy=new AdjustmentPayload(new("sdr.jpg",false,2),new Dictionary<AdjustmentField,JsonElement> {
            [AdjustmentField.Exposure]=JsonSerializer.SerializeToElement(1.25)
        });
        var applied=AdjustmentTransfer.Prepare(legacy,saved,new("hdr.jpg",false));
        Check(applied.Settings.HDR!.Exposure==1.25 && applied.Settings.Values.SequenceEqual(saved.Settings.Values),
            "Legacy logical scalars update active HDR while preserving inactive SDR");
        var sdr=AdjustmentTransfer.Prepare(modified,new SavedEdit(id,new Adjustments().Capture(),null),new("sdr.jpg",false));
        Check(sdr.Settings.HDR==null && sdr.Settings.Restore()[Parameter.Exposure]==.5,
            "HDR public logical scalars can reach SDR without silently enabling HDR");
    }

    private static void ResetOnlyTouchesHDRRecord()
    {
        var state = new Adjustments { HDR = new HDRSettings { Mode = HDRMode.Hdr, Exposure = 1, Contrast = 20, Saturation = 30 } };
        state.Set(Parameter.Exposure, 0.25); // active HDR value
        var identity = new OriginalIdentity("hdr.jpg", 1, 2, 3);
        var edit = new SavedEdit(identity, state.Capture(), null);
        var candidate = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group, EditorAdjustmentGroup.Light), edit);
        Check(candidate.Status == EditorResetStatus.Ready && candidate.Candidate!.Settings.HDR!.Exposure == 0 &&
              candidate.Candidate.Settings.HDR.Contrast == 0 && candidate.Candidate.Settings.HDR.Saturation == 30,
            "HDR light reset owns HDR scalars only");
        var resetEdit = candidate.Candidate!;
        Check(resetEdit.Settings.Values[(int)Parameter.Exposure] == 0,
            "HDR reset leaves the independent SDR scalar untouched");
    }

    private static void EnablingRejectsUnsupportedLegacyState()
    {
        var denoise = new Adjustments { Denoise = DenoiseSettings.Clean };
        try { denoise.SetHDRMode(true, true); throw new Exception("non-default denoise enabled HDR"); }
        catch (HDRModeException error) { Check(error.Failure == HDRModeFailure.Conflicts && error.Conflicts.Contains("denoise"), "denoise conflict is explicit"); }
        var whiteBalance = new Adjustments(); whiteBalance.Set(Parameter.Tint, 4);
        try { whiteBalance.SetHDRMode(true, true); throw new Exception("non-neutral WB enabled HDR"); }
        catch (HDRModeException error) { Check(error.Conflicts.Contains("white_balance"), "legacy WB conflict is explicit"); }
        Check(PhotoInput.IsHDRContainer("photo.heic") && PhotoInput.IsHDRContainer("photo.jpg") &&
              !PhotoInput.IsHDRContainer("photo.png"), "HDR source probe is restricted to supported containers");
    }

    private static void SettingsUseSwiftKeysAndRejectUnknownFields()
    {
        var settings = new HDRSettings { Exposure = 1.25, Temperature = 7200, Tint = -4, Contrast = 20 };
        var json = JsonSerializer.Serialize(settings);
        Check(json.Contains("\"record_version\":1") && json.Contains("\"hdr_processing_version\":1"),
            "HDR record versions use the shared snake_case contract");
        Check(json.Contains("\"exposure_ev\":1.25") && json.Contains("\"relative_temperature\":7200") &&
              json.Contains("\"relative_tint\":-4"), "HDR scalar keys match the shared contract");
        Check(!json.Contains("\"RecordVersion\"") && !json.Contains("\"Temperature\""),
            "HDR settings do not leak CLR property names");
        var restored = JsonSerializer.Deserialize<HDRSettings>(json)!;
        Check(restored == settings, "HDR settings round-trip");
        try
        {
            _ = JsonSerializer.Deserialize<HDRSettings>(json.Replace("}", ",\"future\":true}"));
            throw new Exception("unknown HDR settings field accepted");
        }
        catch (JsonException) { }
        catch (InvalidDataException) { }
    }

    private static void SnapshotKeepsInactiveHDRIndependent()
    {
        var settings = new Adjustments();
        settings.Set(Parameter.Exposure, 0.75);
        settings.HDR = new HDRSettings { Mode = HDRMode.Sdr, Exposure = -1.5, Contrast = 32 };
        var snapshot = settings.Capture();
        var restored = snapshot.Restore();
        Check(restored[Parameter.Exposure] == 0.75 && restored.HDR?.Exposure == -1.5,
            "SDR and inactive HDR values remain separate");
        restored.HDR = restored.HDR! with { Mode = HDRMode.Hdr };
        restored.Set(Parameter.Exposure, 1.5);
        Check(restored[Parameter.Exposure] == 1.5 && restored.Capture().HDR!.Exposure == 1.5 &&
              restored.Capture().Values[(int)Parameter.Exposure] == .75,
            "editing HDR mode does not overwrite the inactive SDR snapshot");
        var roundTrip = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!;
        Check(roundTrip.HDR?.Mode == HDRMode.Sdr && roundTrip.HDR.Exposure == -1.5,
            "old SDR mode plus independent HDR record survives persistence");
        restored.HDR = restored.HDR! with { Mode = HDRMode.Hdr, Temperature = 7400, Tint = 8 };
        var prepared = PhotoInput.PrepareInputSettings("photo.jpg", restored);
        prepared.ResolveWhiteBalance(null);
        Check(prepared.HDR?.Temperature == 7400 && prepared.HDR.Tint == 8,
            "raster preparation and white-balance resolution do not reset active HDR relative WB");
    }

    private static void TransferUsesHDRPayloadV2AndFloatMappings()
    {
        var settings = new Adjustments {
            HDR = new HDRSettings { Mode = HDRMode.Hdr, Exposure = .5, Contrast = 25, Highlights = -20,
                Shadows = 30, Saturation = -10, Temperature = 7300, Tint = 12 }
        };
        var identity = new OriginalIdentity("hdr.jpg", 1, 2, 3);
        var edit = new SavedEdit(identity, settings.Capture(), null);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.All, edit, new("hdr.jpg", false));
        Check(payload.PayloadVersion == 2 && payload.ScopeVersion == 2 && payload.Source.HdrProcessingVersion == 1,
            "HDR transfer uses payload/scope v2 and hdr_processing_version=1");
        Check(AdjustmentPayload.Number(payload[AdjustmentField.Contrast]) == 1.25 &&
              AdjustmentPayload.Number(payload[AdjustmentField.Highlights]) == .2 &&
              AdjustmentPayload.Number(payload[AdjustmentField.Shadows]) == .3 &&
              AdjustmentPayload.Number(payload[AdjustmentField.Saturation]) == .9,
            "HDR transfer uses native contrast/highlight/shadow/saturation mappings");
        Check(AdjustmentPayload.Number(payload[AdjustmentField.HdrTemperature]) == 7300 &&
              AdjustmentPayload.Number(payload[AdjustmentField.HdrTint]) == 12,
            "HDR relative white balance uses dedicated payload fields");
        var json = payload.ToJson();
        Check(json.Contains("\"hdr_processing_version\":1") && json.Contains("\"hdr.relative_temperature\""),
            "HDR payload JSON includes source HDR processing and fields");
        var target = new SavedEdit(identity, new Adjustments { HDR = new HDRSettings { Mode = HDRMode.Hdr } }.Capture(), null);
        var prepared = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(json), target, new("hdr.jpg", false));
        Check(prepared.Settings.HDR?.Exposure == .5 && prepared.Settings.HDR.Contrast == 25 &&
              prepared.Settings.HDR.Highlights == -20 && prepared.Settings.HDR.Shadows == 30 &&
              prepared.Settings.HDR.Saturation == -10 && prepared.Settings.HDR.Temperature == 7300,
            "HDR transfer reverses all percentage mappings without touching SDR state");
        var batch = BatchJob.Create("hdr.jpg", settings.Capture(), null, "HDR");
        batch.Format = ExportFormat.HdrJpeg;
        batch.Validate();
        var copied = batch.Copy();
        Check(copied.Format == ExportFormat.HdrJpeg && copied.Settings.HDR?.Mode == HDRMode.Hdr &&
              copied.Settings.HDR.Saturation == settings.HDR!.Saturation,
            "frozen batch snapshots preserve HDR mode and independent settings");
    }

    private static void NativeLayoutsMatchHDRContract()
    {
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequest>() == 88,
            "HDR request layout is stable");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRSourceInfo>() == 72,
            "HDR source info layout is stable");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRBuffer>() == 56,
            "HDR buffer layout is stable");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRImagePair>() == 208,
            "HDR image pair layout is stable");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRExportConfig>() == 64 &&
              System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRSdrExportConfig>() == 56,
            "HDR export layouts are stable");
    }
}
