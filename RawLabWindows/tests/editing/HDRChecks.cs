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
        EnablingPreservesLegacyState();
        ResetOnlyTouchesHDRRecord();
        ResetAndModifiedIsolateActiveMode();
        TransferUsesHDRPayloadV2AndFloatMappings();
        ToneKeepsHDRAndSDRIndependent();
        ColorKeepsHDRAndSDRIndependent();
        RenditionKeepsHDRAndSDRIndependent();
        EffectsKeepHDRAndSDRIndependent();
        DetailKeepsHDRAndSDRIndependent();
        LookKeepsHDRAndSDRIndependent();
        CameraDevelopmentUsesItsOwnVersion();
        NeutralReferenceKeepsOnlyCameraLensSettings();
        NeutralReferenceIdentityTracksOnlyCameraLensSettings();
        NativeLayoutsMatchHDRContract();
        LogicalFieldsCrossFamiliesWithoutCopyingGeometryOrInactiveState();
        BatchPreparationPreservesTheFrozenModeWithoutReopeningItsSource();
        Check(JsonSerializer.Deserialize<ExportFormat>("1")==ExportFormat.Png &&
            JsonSerializer.Deserialize<ExportFormat>("2")==ExportFormat.RenderedDng,
            "Existing journal enum numbers keep PNG and DNG meanings");
        Console.WriteLine("PASS: Windows HDR settings, snapshot isolation, transfer v2 and ABI model");
    }

    private static void NeutralReferenceKeepsOnlyCameraLensSettings()
    {
        var camera = new HDRCameraDevelopmentSettings(true,8400,24,true,2,true,true,false,"lens-id",
            new HDRCameraProfile(new string('a',64),"D65"));
        var hdr = new HDRSettings { Exposure=1,Temperature=7200,Tint=12,Contrast=30,
            Geometry=new(.1,.2,.7,.6,1,true,false,2) }.WithCameraDevelopment(camera)
            .WithDetail(new HDRDetailSettings(1,.4,.3,.2));
        var edited = new Adjustments { HDR=hdr,Geometry=hdr.Geometry,ProRAWDecodeVersion=1 };
        var before = NeutralReference.Settings("fixture.ARW",edited);
        var expectedCamera = new HDRCameraDevelopmentSettings(LensDistortion:true,LensTca:true,
            LensAutoCrop:false,LensProfile:"lens-id");
        Check(before.HDR!.CameraSettings==expectedCamera,
            "HDR neutral reference keeps distortion, TCA, auto-crop and lens profile while resetting WB, exposure, FBDD and camera profile");
        Check(before.HDR.Exposure==0 && before.HDR.Temperature==6500 && before.HDR.Tint==0 &&
            before.HDR.Contrast==0 && before.HDR.DetailSettings.IsDefault && before.Geometry==edited.Geometry &&
            before.ProRAWDecodeVersion==1,"HDR neutral reference retains composition and decoder version while resetting grading");
        Check(edited.HDR==hdr && edited.HDR.CameraSettings==camera,"Neutral preparation leaves committed HDR edits untouched");
        Check(NeutralReference.Settings("fixture.ARW",new Adjustments { HDR=new HDRSettings() }).HDR!.CameraDevelopment==null,
            "A legacy HDR neutral reference does not invent camera development");
        Check(hdr.Reset().CameraSettings.IsDefault,"Full HDR reset still clears lens corrections");
    }

    private static void NeutralReferenceIdentityTracksOnlyCameraLensSettings()
    {
        var camera = new HDRCameraDevelopmentSettings(LensDistortion:true,LensTca:true,LensAutoCrop:false,LensProfile:"lens-id");
        var hdr = new HDRSettings().WithCameraDevelopment(camera);
        var key = new NeutralReferenceKey(new("fixture.ARW",12,34,56),false,ProcessingIdentity.Legacy,new(),new(),640,
            HDR:true,HDRCamera:NeutralReference.HDRCameraSettings(hdr));
        foreach(var changed in new[] {camera with {LensDistortion=false},camera with {LensTca=false},
            camera with {LensAutoCrop=true},camera with {LensProfile="another lens"}}) {
            var referenceCamera = NeutralReference.HDRCameraSettings(hdr with {CameraDevelopment=changed});
            Check(key!=key with {HDRCamera=referenceCamera},"Each HDR lens field invalidates the neutral frame identity");
            Check(!NeutralReference.Matches(key,key.Source,key.Processing,key.Geometry,key.Lens,hdr:true,hdrCamera:referenceCamera),
                "An old HDR lens frame cannot be reported ready after a lens change");
        }
        var colorEdit = hdr with {Exposure=1,CameraDevelopment=camera with {CustomWhiteBalance=true,Temperature=8400,Tint=24,
            SensorExposure=true,FbddLevel=2,CameraProfile=new(new string('b',64),"D65")}};
        Check(NeutralReference.Matches(key,key.Source,key.Processing,key.Geometry,key.Lens,hdr:true,
            hdrCamera:NeutralReference.HDRCameraSettings(colorEdit)),"Color and camera grading edits reuse the neutral lens frame");
        Check(NeutralReference.HDRCameraSettings(new HDRSettings())==NeutralReference.HDRCameraSettings(new HDRSettings()
            .WithCameraDevelopment(new(CustomWhiteBalance:true,Temperature:8400))),
            "Creating a WB record without lens changes retains the default neutral identity");
        var legacy = key with {HDR=false,HDRCamera=null};
        Check(NeutralReference.Matches(legacy,legacy.Source,legacy.Processing,legacy.Geometry,legacy.Lens),
            "Existing SDR reference callers remain compatible with the optional HDR identity");
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

    private static void ResetAndModifiedIsolateActiveMode()
    {
        var all = new EditorResetScope(EditorResetKind.All);
        var rawIdentity = new OriginalIdentity("bayer.dng", 1, 2, 3);
        var dormantHdr = new HDRSettings { Mode = HDRMode.Sdr, Exposure = -1.25, Contrast = 30 };

        var sdrDefault = new Adjustments { HDR = dormantHdr, HDRCameraAIEnabled = true };
        sdrDefault.ResolveWhiteBalance((5200, 8));
        var sdrUnedited = new SavedEdit(rawIdentity, sdrDefault.Capture(), null);
        Check(!EditorAdjustmentRules.IsModified(all, sdrUnedited) &&
              EditorAdjustmentRules.PrepareReset(all, sdrUnedited).Status == EditorResetStatus.NoChange,
            "Dormant HDR and HDRCameraAIEnabled do not mark unedited SDR as modified");

        var sdrEditedState = sdrDefault.Clone();
        sdrEditedState.Set(Parameter.Exposure, .75);
        sdrEditedState.AIDenoiseEnabled = true;
        var sdrEdited = new SavedEdit(rawIdentity, sdrEditedState.Capture(), "builtin:classic");
        Check(EditorAdjustmentRules.IsModified(all, sdrEdited), "Active SDR edits mark All as modified");
        var sdrReset = EditorAdjustmentRules.PrepareReset(all, sdrEdited);
        Check(sdrReset.Status == EditorResetStatus.Ready &&
              sdrReset.Candidate!.Look == null &&
              !sdrReset.Candidate.Settings.AIDenoiseEnabled &&
              sdrReset.Candidate.Settings.Values[(int)Parameter.Exposure] == 0 &&
              sdrReset.Candidate.Settings.HDR == dormantHdr &&
              sdrReset.Candidate.Settings.HDRCameraAIEnabled &&
              !EditorAdjustmentRules.IsModified(all, sdrReset.Candidate),
            "SDR all-reset preserves dormant HDR and HDRCameraAIEnabled and immediately clears IsModified(All)");

        var proRawDefault = new Adjustments { HDR = dormantHdr, ProRAWDecodeVersion = 1 };
        proRawDefault.ResolveWhiteBalance((5200, 8));
        Check(!EditorAdjustmentRules.IsModified(all, new SavedEdit(rawIdentity, proRawDefault.Capture(), null)),
            "Dormant ProRAWDecodeVersion does not mark unedited SDR as modified");
        var proRawEdited = proRawDefault.Clone();
        proRawEdited.Set(Parameter.Exposure, -.5);
        var proRawReset = EditorAdjustmentRules.PrepareReset(all, new SavedEdit(rawIdentity, proRawEdited.Capture(), null));
        Check(proRawReset.Status == EditorResetStatus.Ready &&
              proRawReset.Candidate!.Settings.ProRAWDecodeVersion == 1 &&
              proRawReset.Candidate.Settings.HDR == dormantHdr &&
              !EditorAdjustmentRules.IsModified(all, proRawReset.Candidate),
            "SDR all-reset preserves dormant ProRAWDecodeVersion and clears IsModified(All)");

        void CheckHdrIsolation(Adjustments baseSdr, int? proRawVersion, bool hdrCameraAI)
        {
            var unedited = new SavedEdit(rawIdentity, (baseSdr.Capture() with {
                HDR = new HDRSettings { Mode = HDRMode.Hdr },
                ProRAWDecodeVersion = proRawVersion,
                HDRCameraAIEnabled = false
            }), "builtin:classic");
            Check(!EditorAdjustmentRules.IsModified(all, unedited) &&
                  EditorAdjustmentRules.PrepareReset(all, unedited).Status == EditorResetStatus.NoChange,
                "Active HDR ignores dormant SDR edits, Look, unknown recipe and ProRAWDecodeVersion when HDR is default");
            var activeHdr = new HDRSettings { Mode = HDRMode.Hdr, Exposure = 1.5, Contrast = 25 }
                .WithRendition(new HDRRenditionSettings { PeakLimitEV = 2 });
            var edited = unedited with {
                Settings = unedited.Settings with { HDR = activeHdr, HDRCameraAIEnabled = hdrCameraAI }
            };
            Check(EditorAdjustmentRules.IsModified(all, edited), "Active HDR edits mark All as modified");
            var reset = EditorAdjustmentRules.PrepareReset(all, edited);
            Check(reset.Status == EditorResetStatus.Ready &&
                  reset.Candidate!.Settings.HDR!.IsIdentity &&
                  !reset.Candidate.Settings.HDRCameraAIEnabled &&
                  reset.Candidate.Look == "builtin:classic" &&
                  reset.Candidate.Settings.Values[(int)Parameter.Exposure] == .75 &&
                  reset.Candidate.Settings.Denoise == DenoiseSettings.Clean &&
                  reset.Candidate.Settings.AIDenoiseEnabled &&
                  reset.Candidate.Settings.MasterRecipeID == "unknown-dormant-recipe" &&
                  reset.Candidate.Settings.ProRAWDecodeVersion == proRawVersion &&
                  !EditorAdjustmentRules.IsModified(all, reset.Candidate),
                "Active HDR all-reset preserves dormant SDR snapshot, Look and ProRAWDecodeVersion and clears IsModified(All)");
        }
        var dormantSdr = new Adjustments { Denoise = DenoiseSettings.Clean, AIDenoiseEnabled = true };
        dormantSdr.ResolveWhiteBalance((5200, 8));
        dormantSdr.Set(Parameter.Exposure, .75);
        dormantSdr.MasterRecipeID = "unknown-dormant-recipe";
        CheckHdrIsolation(dormantSdr, proRawVersion: 1, hdrCameraAI: false);
        CheckHdrIsolation(dormantSdr, proRawVersion: null, hdrCameraAI: true);
    }

    private static void EnablingPreservesLegacyState()
    {
        var recipe = new Adjustments();
        recipe.ApplyMasterRecipe(MasterRecipe.All[0]);
        recipe.Set(Parameter.Strength, 50); recipe.Set(Parameter.Exposure, 1);
        recipe.Set(Parameter.Contrast, 40); recipe.Set(Parameter.Highlights, -60);
        recipe.Set(Parameter.Shadows, 80); recipe.Set(Parameter.Saturation, -20);
        var effective = HDRSettings.FromSdr(recipe);
        Check(effective.Exposure == .5 && effective.Contrast == 20 && effective.Highlights == -30 &&
              effective.Shadows == 40 && effective.Saturation == -10, "Gain-map HDR uses effective recipe values");
        recipe.Set(Parameter.Strength, 200); recipe.Set(Parameter.Exposure, 4);
        recipe.Set(Parameter.Contrast, 100); recipe.Set(Parameter.Highlights, -100);
        recipe.Set(Parameter.Shadows, 100); recipe.Set(Parameter.Saturation, -100);
        var bounded = HDRSettings.FromSdr(recipe);
        Check(bounded.Exposure == 4 && bounded.Contrast == 100 && bounded.Highlights == -100 &&
              bounded.Shadows == 100 && bounded.Saturation == -100 && bounded.IsValid, "Gain-map HDR clamps effective values");
        var settings = new Adjustments { Denoise = DenoiseSettings.Clean };
        settings.Set(Parameter.Tint, 4);
        settings.SetHDRMode(true, true);
        Check(settings.IsHDREditing && settings.HDR!.Tint == 0, "HDR opens with neutral relative white balance");
        settings.SetHDRMode(false, true);
        Check(settings.Denoise == DenoiseSettings.Clean && settings[Parameter.Tint] == 4,
            "HDR switch preserved the original SDR denoise and white balance");
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
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequestV2>() == 648 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV2>(nameof(Native.HDRRequestV2.Curve)).ToInt32() == 104,
            "HDR v2 request preserves the base prefix and aligned curve tail");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequestV3>() == 792 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV3>(nameof(Native.HDRRequestV3.Hsl)).ToInt32() == 656 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV3>(nameof(Native.HDRRequestV3.Grading)).ToInt32() == 760,
            "HDR v3 preserves the native tone prefix and color tail");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequestV4>() == 808 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV4>(nameof(Native.HDRRequestV4.PeakLimitEV)).ToInt32() == 792,
            "HDR v4 preserves the native color prefix and rendition tail");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequestV5>() == 848 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV5>(nameof(Native.HDRRequestV5.Effects)).ToInt32() == 808,
            "HDR v5 preserves the native rendition prefix and effects tail");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequestV6>() == 864 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV6>(nameof(Native.HDRRequestV6.Sharpening)).ToInt32() == 848,
            "HDR v6 preserves the effects prefix and detail tail");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRRequestV7>() == 952 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRRequestV7>(nameof(Native.HDRRequestV7.LookPath)).ToInt32() == 864 &&
              System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRLookInfo>() == 108,
            "HDR v7 preserves the detail prefix and look probe layout");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRCameraDevelopment>() == 40,
            "Camera development has a stable ABI");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRSourceInfo>() == 76 &&
              System.Runtime.InteropServices.Marshal.OffsetOf<Native.HDRSourceInfo>(nameof(Native.HDRSourceInfo.CameraCapabilities)).ToInt32() == 72,
            "HDR camera source capabilities follow the stable source info prefix");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRBuffer>() == 56,
            "HDR buffer layout is stable");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRImagePair>() == 208,
            "HDR image pair layout is stable");
        Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRExportConfig>() == 64 &&
              System.Runtime.InteropServices.Marshal.SizeOf<Native.HDRSdrExportConfig>() == 56,
            "HDR export layouts are stable");
    }

    private static void RenditionKeepsHDRAndSDRIndependent()
    {
        var adjustments = new Adjustments();
        adjustments.Set(Parameter.Exposure, -2);
        adjustments.HDR = new();
        var identity = new OriginalIdentity("hdr.jpg", 1, 2, 3);
        var neutral = new SavedEdit(identity, adjustments.Capture(), null);
        var rendition = new HDRRenditionSettings { PeakLimitEV=2, SdrExposureEV=-.75, SdrContrast=25, SdrSaturation=-15 };
        adjustments.HDR = adjustments.HDR.WithRendition(rendition);
        var native = adjustments.HDR.NativeRenderRequest(HDRIntent.Final).Base.Base.Base.Base;
        Check(native.Base.Base.Base.StructSize == 808 && native.PeakLimitEV == 2 && native.SdrExposureEV == -.75 &&
              native.SdrContrast == 25 && native.SdrSaturation == -15, "Native HDR v4 values");
        var context = new AdjustmentTransferContext("hdr.jpg", false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified,new(identity,adjustments.Capture(),null),context);
        var prepared = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(payload.ToJson()),neutral,context);
        Check(payload.Source.HdrProcessingVersion == 4 && payload.Fields.SetEquals(AdjustmentFields.HDRRendition) &&
              prepared.Settings.HDR == adjustments.HDR && prepared.Settings.Values[(int)Parameter.Exposure] == -2,
            "HDR v4 transfers only selected rendition fields");
        var saved = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(prepared.Settings))!;
        Check(saved.HDR == adjustments.HDR && saved.HDR!.Reset().ProcessingVersion == 4 && saved.HDR.Reset().IsIdentity,
            "Saved HDR v4 round-trips and reset preserves its version");
        try {
            AdjustmentTransfer.Prepare(payload,neutral with { Settings=neutral.Settings with { HDR=null } },context);
            throw new Exception("HDR rendition reached an SDR record");
        } catch (AdjustmentTransferException error) {
            Check(error.Failure == AdjustmentFailure.Incompatible && error.Detail == "hdr.rendition",
                "HDR rendition is rejected atomically in SDR mode");
        }
    }

    private static void EffectsKeepHDRAndSDRIndependent()
    {
        var sdr = new PhotoEffectsSettings(GrainAmount:15);
        var state = new Adjustments { Effects=sdr, HDR=new() };
        state.SetEffect(PhotoEffectParameter.VignetteAmount,-55);
        state.SetEffect(PhotoEffectParameter.GrainAmount,40);
        var snapshot = state.Capture();
        var restored = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!;
        Check(restored.SameAs(snapshot) && restored.Effects == sdr &&
              restored.HDR!.ProcessingVersion == 5 && restored.HDR.EffectSettings.GrainAmount == 40,
            "HDR effects round-trip independently of the ordinary SDR effect");
        var native = restored.HDR!.NativeRenderRequest(HDRIntent.Final).Base.Base.Base;
        Check(native.Base.Base.Base.Base.StructSize == 848 && native.Effects.GrainAmount == 40 &&
              native.Effects.VignetteAmount == -55,"Native HDR v5 effects match the saved record");
        var id = new OriginalIdentity("hdr.jpg",1,2,3);
        var context = new AdjustmentTransferContext("hdr.jpg",false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified,new(id,snapshot,null),context);
        var target = new SavedEdit(id,new Adjustments { HDR=new() }.Capture(),null);
        var updated = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(payload.ToJson()),target,context);
        Check(payload.Source.HdrProcessingVersion == 5 && updated.Settings.HDR == restored.HDR &&
              payload.Fields.SetEquals(new[] { AdjustmentField.VignetteAmount, AdjustmentField.GrainAmount }),
            "HDR preset transfer preserves modified effects");
    }

    private static void DetailKeepsHDRAndSDRIndependent()
    {
        var state = new Adjustments();
        state.Set(Parameter.Sharpening, 25);
        state.SetAtmosphere(AtmosphereParameter.Clarity, -15);
        state.HDR = new HDRSettings();
        state.Set(Parameter.Sharpening, 130);
        state.SetAtmosphere(AtmosphereParameter.Clarity, 50);
        state.SetAtmosphere(AtmosphereParameter.Dehaze, -25);
        state.HDR = state.HDR.WithDetail(state.HDR.DetailSettings with { Denoise = .75 });
        var snapshot = state.Capture();
        var restored = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!;
        Check(restored.SameAs(snapshot) && restored.HDR!.ProcessingVersion == 6 &&
            restored.Values[(int)Parameter.Sharpening] == 25 && restored.Atmosphere!.Clarity == -15,
            "HDR detail persists independently of dormant SDR settings");
        var native = restored.HDR!.NativeRenderRequest(HDRIntent.Final).Base.Base;
        Check(native.Base.Base.Base.Base.Base.StructSize == 864 && native.Sharpening == 1.3f && native.Clarity == .5f &&
            native.Dehaze == -.25f && native.Denoise == .75f,"Native HDR v6 detail matches the saved record");
        var id = new OriginalIdentity("hdr.jpg",1,2,3);
        var context = new AdjustmentTransferContext("hdr.jpg",false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified,new(id,snapshot,null),context);
        var target = new SavedEdit(id,new Adjustments { HDR=new() }.Capture(),null);
        var updated = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(payload.ToJson()),target,context);
        Check(payload.Source.HdrProcessingVersion == 6 && updated.Settings.HDR == restored.HDR &&
            payload.Fields.SetEquals(AdjustmentFields.HDRDetail), "HDR detail transfer preserves four controls");
        try {
            AdjustmentTransfer.Prepare(payload, target with { Settings = target.Settings with { HDR = null } },context);
            throw new Exception("HDR detail reached an SDR record");
        } catch (AdjustmentTransferException error) {
            Check(error.Failure == AdjustmentFailure.Incompatible && error.Detail == "hdr.detail", "HDR detail rejects SDR targets");
        }
        Check(state.HDR.Reset() is { ProcessingVersion: 6, IsIdentity: true }, "Reset keeps HDR v6 version");
    }

    private static void LookKeepsHDRAndSDRIndependent()
    {
        var look = new HDRLookSettings(new string('a',64), "Test HDR", .65);
        var state = new Adjustments { HDR = new HDRSettings().WithLook(look) };
        var snapshot = state.Capture();
        var saved = new SavedEdit(new OriginalIdentity("hdr.jpg",1,2,3), snapshot, null);
        var restored = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!;
        Check(restored.SameAs(snapshot) && restored.HDR is { ProcessingVersion: 7 } &&
            restored.HDR.LookSettings == look, "HDR look round-trips independently");
        var request = restored.HDR!.NativeRenderRequest(HDRIntent.Final).Base;
        Check(request.Base.Base.Base.Base.Base.Base.StructSize == 952 && request.LookPath == look.AssetPath() &&
            request.LookStrength == .65f && System.Text.Encoding.ASCII.GetString(request.LookSha256, 0, 64) == look.Sha256,
            "HDR look maps to the v7 request");
        var context = new AdjustmentTransferContext("hdr.jpg",false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, saved, context);
        Check(payload.Source.HdrProcessingVersion == 7 && payload.Fields.SetEquals(new[] { AdjustmentField.HdrLook }) &&
            AdjustmentPayload.HDRLookValue(AdjustmentPayload.Parse(payload.ToJson())[AdjustmentField.HdrLook]!.Value) == look,
            "HDR look transfer carries identity and strength");
        try {
            AdjustmentTransfer.Prepare(payload,saved,context);
            throw new Exception("Missing HDR look was accepted");
        } catch (AdjustmentTransferException error) when (error.Failure == AdjustmentFailure.MissingLook) { }
        Check(state.HDR.Reset() is { ProcessingVersion: 7, IsIdentity: true },
            "Clearing the look keeps HDR v7");
    }

    private static void CameraDevelopmentUsesItsOwnVersion()
    {
        var development = new HDRCameraDevelopmentSettings(true,8400,24,true,2);
        var hdr = new HDRSettings().WithCameraDevelopment(development);
        var restored = JsonSerializer.Deserialize<HDRSettings>(JsonSerializer.Serialize(hdr))!;
        Check(restored==hdr && restored.RecordVersion==8 && restored.ProcessingVersion==1 && !restored.IsIdentity,
            "Camera development round-trips independently of the HDR render version");
        Check(restored.Reset() is { RecordVersion:8, IsIdentity:true },"Reset clears camera development");
        var identity = new OriginalIdentity("bayer.dng",1,2,3);
        var source = new SavedEdit(identity,new Adjustments { HDR=hdr }.Capture(),null);
        var lens = new HDRCameraDevelopmentSettings(LensTca:true,LensAutoCrop:false,LensProfile:"target profile");
        var target = source with { Settings = new Adjustments { HDR=new HDRSettings().WithCameraDevelopment(lens) }.Capture() };
        var preflights = 0;
        var context = new AdjustmentTransferContext(identity.Path,true,SupportsCameraHDR:true,ValidateHDRCamera:candidate=>{
            Check(candidate.HDR?.CameraSettings.FbddLevel==2,"Camera preflight receives the edited candidate"); preflights++;
        });
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified,source,context);
        var roundTrip = AdjustmentPayload.Parse(payload.ToJson());
        Check(roundTrip.Source.HdrProcessingVersion==1 && roundTrip.Fields.SetEquals(new[]{ AdjustmentField.HdrCameraDevelopment }),
            "Camera payload is independent of HDR render version");
        var prepared = AdjustmentTransfer.Prepare(roundTrip,target,context);
        var expected = development with { LensTca=true,LensAutoCrop=false,LensProfile="target profile" };
        Check(preflights==1 && prepared.Settings.HDR?.CameraSettings==expected,"Camera payload preserves target lens calibration");
        foreach (var unsupported in new[]{ new AdjustmentTransferContext("gain-map.jpg",false),context with { IsProRAW=true } }) {
            try {
                AdjustmentTransfer.Prepare(roundTrip,target,unsupported);
                throw new Exception("Camera transfer accepted an incompatible source");
            } catch (AdjustmentTransferException error) when (error.Failure==AdjustmentFailure.Incompatible) { }
        }
    }

    private static void ToneKeepsHDRAndSDRIndependent()
    {
        var sdrCurve = ToneCurveSettings.Identity;
        var settings = new Adjustments { Curve = sdrCurve, ToneControls = new(-8, 9) };
        settings.Set(Parameter.ToneCurve, 12);
        settings.HDR = new();
        Check(settings.HDR.NativeRenderRequest(HDRIntent.Preview).Base.Base.Base.Base.Base.Base.Base.StructSize == 88,
            "Unedited HDR stays on request v1");
        settings.SetTone(ToneControlParameter.BlackPoint, -25);
        settings.SetTone(ToneControlParameter.WhitePoint, 50);
        settings.Set(Parameter.ToneCurve, 30);
        settings.EditingCurve = ToneCurveSettings.Identity.Inserting(.5, .625);
        Check(settings[Parameter.ToneCurve] == 30 && settings.EditingToneValue(ToneControlParameter.BlackPoint) == -25 &&
              settings.EditingToneValue(ToneControlParameter.WhitePoint) == 50 && settings.HDR.ProcessingVersion == 2,
            "HDR tone edits use the active v2 record");
        var snapshot = settings.Capture();
        Check(snapshot.Values[(int)Parameter.ToneCurve] == 12 && snapshot.Curve == sdrCurve && snapshot.ToneControls == new ToneControlsSettings(-8, 9),
            "HDR tone edits preserve the dormant SDR record");
        var restored = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!.Restore();
        Check(restored.Capture().SameAs(snapshot), "Windows HDR tone settings round-trip");
        var request = restored.HDR!.NativeRenderRequest(HDRIntent.Final, 512).Base.Base.Base.Base.Base.Base;
        Check(request.Base.Version == 1 && request.Base.HDRProcessingVersion == 2 && request.Base.StructSize == 648 &&
              request.BlackPoint == -25 && request.WhitePoint == 50 && request.CurveStrength == 30 &&
              request.Curve.Count == 3 && request.Curve.Points[3] == .625, "Windows maps HDR tone to the C ABI");
        var identity = new OriginalIdentity("hdr.jpg", 1, 2, 3);
        var source = new SavedEdit(identity, snapshot, null);
        var reset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group, EditorAdjustmentGroup.Light), source).Candidate!;
        Check(reset.Settings.HDR!.ToneSettings.IsDefault && reset.Settings.HDR.ProcessingVersion == 2 &&
              reset.Settings.ToneControls == snapshot.ToneControls && reset.Settings.Curve == sdrCurve,
            "Windows HDR reset preserves version and SDR tone");
        var context = new AdjustmentTransferContext("hdr.jpg", false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, source, context);
        Check(payload.Source.HdrProcessingVersion == 2 && payload.Fields.SetEquals(AdjustmentFields.HDRTone),
            "Windows captures versioned modified tone fields");
        var target = source with { Settings = new Adjustments { HDR = new() }.Capture() };
        var applied = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(payload.ToJson()), target, context);
        Check(applied.Settings.HDR!.ToneSettings == restored.HDR.ToneSettings, "HDR tone paste preserves all points and scalars");
        try {
            _ = AdjustmentTransfer.Prepare(payload, target with { Settings = new Adjustments().Capture() }, context);
            throw new Exception("HDR tone entered SDR");
        } catch (AdjustmentTransferException error) when (error.Failure == AdjustmentFailure.Incompatible) { }
    }

    private static void ColorKeepsHDRAndSDRIndependent()
    {
        var sdrHsl = new HslSettings().WithValue(0, 1, 12);
        var settings = new Adjustments { Hsl = sdrHsl, HDR = new() };
        settings.SetTone(ToneControlParameter.Vibrance, 35);
        settings.EditingHsl = new HslSettings().WithValue(1, 5, -12.5);
        settings.EditingGrading = new ColorGradingSettings { Highlights = new(215, 30) };
        var snapshot = settings.Capture();
        var restored = JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(snapshot))!;
        Check(restored.SameAs(snapshot) && restored.Hsl!.Equals(sdrHsl) && (restored.ToneControls?.Vibrance ?? 0) == 0 &&
              restored.HDR!.ProcessingVersion == 3 && restored.HDR.ToneSettings.IsDefault, "HDR color round-trips independently");
        var request = restored.HDR!.NativeRenderRequest(HDRIntent.Preview).Base.Base.Base.Base.Base;
        Check(request.Base.Base.StructSize == 792 && request.Vibrance == 35 && request.Hsl.Saturation[5] == -12.5 &&
              request.Grading.HighlightsHue == 215 && request.Grading.HighlightsSaturation == 30, "HDR colors map to ABI");
        var source = new SavedEdit(new OriginalIdentity("hdr.jpg", 1, 2, 3), snapshot, null);
        var context = new AdjustmentTransferContext("hdr.jpg", false);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Modified, source, context);
        Check(payload.Source.HdrProcessingVersion == 3 && payload.Fields.SetEquals(new[] {
            AdjustmentField.Vibrance, AdjustmentField.HslSaturationBlue, AdjustmentField.GradingHighlights
        }), "HDR color modified scope retains precisely the changed fields");
        var target = source with { Settings = new Adjustments { HDR = new() }.Capture() };
        var applied = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(payload.ToJson()), target, context);
        Check(applied.Settings.HDR == snapshot.HDR, "HDR color paste preserves the active snapshot");
        var reset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.Group, EditorAdjustmentGroup.Color), source).Candidate!;
        Check(reset.Settings.HDR!.ProcessingVersion == 3 && reset.Settings.HDR.ColorSettings.IsDefault &&
              reset.Settings.Hsl!.Equals(sdrHsl), "HDR color reset preserves v3 and dormant color");
    }
}
