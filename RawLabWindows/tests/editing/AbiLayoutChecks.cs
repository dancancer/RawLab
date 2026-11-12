using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using RawLab.Windows;

internal static class AbiLayoutChecks
{
    private sealed record UnrolledArray(
        string CField,
        IReadOnlyList<string> ClrFields,
        string? ElementCStruct = null,
        int ElementBytes = 0);

    // Explicit registration for any C# instance field not directly mapped to a C ABI field
    // (e.g., manual reserved/padding fields or flattened extension tails), with exact [StartOffset..EndOffset) byte span.
    private sealed record ReservedFieldSpec(
        string ClrField,
        int StartOffset,
        int EndOffset,
        string Reason);

    private sealed record StructMapping(
        Type ClrType,
        IReadOnlyDictionary<string, string> Fields,
        string? PrefixEndField = null,
        IReadOnlyList<UnrolledArray>? UnrolledArrays = null,
        IReadOnlyList<ReservedFieldSpec>? ReservedFields = null,
        string? FlattenedBaseCStruct = null);

    // C ABI structs defined in the shared headers that intentionally have no mirror inside Native.*:
    // - sony2fuji_blob: mirrored separately in PInvokeNative.DcpBlob (outside EditWorkflow.Tests compile set).
    // - sony2fuji_curve_point: flattened into double[66] Points inside Native.ToneCurveConfig.
    // - sony2fuji_lens_metadata / sony2fuji_lens_profile_v2: corresponding C entrypoints are not bound on Windows.
    private static readonly HashSet<string> UnmappedInNative = new(StringComparer.Ordinal)
    {
        "sony2fuji_blob",
        "sony2fuji_curve_point",
        "sony2fuji_lens_metadata",
        "sony2fuji_lens_profile_v2",
    };

    private static readonly Dictionary<string, StructMapping> Mappings = new(StringComparer.Ordinal)
    {
        ["sony2fuji_request"] = new(
            typeof(Native.Request),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.Request.Version),
                ["struct_size"] = nameof(Native.Request.StructSize),
                ["input_path"] = nameof(Native.Request.InputPath),
                ["input_type"] = nameof(Native.Request.InputType),
                ["input_pixels"] = nameof(Native.Request.InputPixels),
                ["input_width"] = nameof(Native.Request.InputWidth),
                ["input_height"] = nameof(Native.Request.InputHeight),
                ["input_pixel_format"] = nameof(Native.Request.InputPixelFormat),
                ["input_color_space"] = nameof(Native.Request.InputColorSpace),
                ["input_is_linear"] = nameof(Native.Request.InputIsLinear),
                ["lut_path"] = nameof(Native.Request.LutPath),
                ["lut_strength"] = nameof(Native.Request.LutStrength),
                ["wb_mode"] = nameof(Native.Request.WbMode),
                ["wb_mul"] = nameof(Native.Request.Wb0),
                ["exposure_ev"] = nameof(Native.Request.ExposureEv),
                ["brightness"] = nameof(Native.Request.Brightness),
                ["contrast"] = nameof(Native.Request.Contrast),
                ["saturation"] = nameof(Native.Request.Saturation),
                ["temperature"] = nameof(Native.Request.Temperature),
                ["tint"] = nameof(Native.Request.Tint),
                ["highlights"] = nameof(Native.Request.Highlights),
                ["shadows"] = nameof(Native.Request.Shadows),
                ["tone_curve"] = nameof(Native.Request.ToneCurve),
                ["noise_reduction"] = nameof(Native.Request.NoiseReduction),
                ["sharpening"] = nameof(Native.Request.Sharpening),
                ["size_mode"] = nameof(Native.Request.SizeMode),
                ["target_width"] = nameof(Native.Request.TargetWidth),
                ["target_height"] = nameof(Native.Request.TargetHeight),
                ["long_edge"] = nameof(Native.Request.LongEdge),
                ["short_edge"] = nameof(Native.Request.ShortEdge),
                ["output_target"] = nameof(Native.Request.OutputTarget),
                ["output_path"] = nameof(Native.Request.OutputPath),
                ["output_format"] = nameof(Native.Request.OutputFormat),
                ["jpeg_quality"] = nameof(Native.Request.JpegQuality),
                ["intent"] = nameof(Native.Request.Intent),
                ["preview_long_edge"] = nameof(Native.Request.PreviewLongEdge),
            },
            UnrolledArrays: new[]
            {
                new UnrolledArray(
                    "wb_mul",
                    new[] { nameof(Native.Request.Wb0), nameof(Native.Request.Wb1), nameof(Native.Request.Wb2), nameof(Native.Request.Wb3) },
                    ElementBytes: sizeof(float)),
            }),
        ["sony2fuji_buffer"] = new(
            typeof(Native.Buffer),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["data"] = nameof(Native.Buffer.Data),
                ["size_bytes"] = nameof(Native.Buffer.Size),
                ["width"] = nameof(Native.Buffer.Width),
                ["height"] = nameof(Native.Buffer.Height),
                ["stride_bytes"] = nameof(Native.Buffer.Stride),
                ["pixel_format"] = nameof(Native.Buffer.PixelFormat),
            }),
        ["sony2fuji_gpu_config"] = new(
            typeof(Native.GpuConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.GpuConfig.Version),
                ["struct_size"] = nameof(Native.GpuConfig.StructSize),
                ["mode"] = nameof(Native.GpuConfig.Mode),
            }),
        ["sony2fuji_wavelet_denoise_config"] = new(
            typeof(Native.WaveletConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.WaveletConfig.Version),
                ["struct_size"] = nameof(Native.WaveletConfig.StructSize),
                ["enabled"] = nameof(Native.WaveletConfig.Enabled),
                ["luma"] = nameof(Native.WaveletConfig.Luma),
                ["chroma"] = nameof(Native.WaveletConfig.Chroma),
                ["coarse"] = nameof(Native.WaveletConfig.Coarse),
            }),
        ["sony2fuji_photo_effects_config"] = new(
            typeof(Native.PhotoEffectsConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.PhotoEffectsConfig.Version),
                ["struct_size"] = nameof(Native.PhotoEffectsConfig.StructSize),
                ["vignette_amount"] = nameof(Native.PhotoEffectsConfig.VignetteAmount),
                ["vignette_midpoint"] = nameof(Native.PhotoEffectsConfig.VignetteMidpoint),
                ["vignette_roundness"] = nameof(Native.PhotoEffectsConfig.VignetteRoundness),
                ["vignette_feather"] = nameof(Native.PhotoEffectsConfig.VignetteFeather),
                ["vignette_highlights"] = nameof(Native.PhotoEffectsConfig.VignetteHighlights),
                ["grain_amount"] = nameof(Native.PhotoEffectsConfig.GrainAmount),
                ["grain_size"] = nameof(Native.PhotoEffectsConfig.GrainSize),
                ["grain_roughness"] = nameof(Native.PhotoEffectsConfig.GrainRoughness),
            }),
        ["sony2fuji_hsl_config"] = new(
            typeof(Native.HslConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HslConfig.Version),
                ["struct_size"] = nameof(Native.HslConfig.StructSize),
                ["hue"] = nameof(Native.HslConfig.Hue),
                ["saturation"] = nameof(Native.HslConfig.Saturation),
                ["lightness"] = nameof(Native.HslConfig.Lightness),
            }),
        ["sony2fuji_tone_controls_config"] = new(
            typeof(Native.ToneControlsConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.ToneControlsConfig.Version),
                ["struct_size"] = nameof(Native.ToneControlsConfig.StructSize),
                ["black_point"] = nameof(Native.ToneControlsConfig.BlackPoint),
                ["white_point"] = nameof(Native.ToneControlsConfig.WhitePoint),
                ["vibrance"] = nameof(Native.ToneControlsConfig.Vibrance),
            }),
        ["sony2fuji_atmosphere_config"] = new(
            typeof(Native.AtmosphereConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.AtmosphereConfig.Version),
                ["struct_size"] = nameof(Native.AtmosphereConfig.StructSize),
                ["clarity"] = nameof(Native.AtmosphereConfig.Clarity),
                ["dehaze"] = nameof(Native.AtmosphereConfig.Dehaze),
            }),
        ["sony2fuji_color_grading_config"] = new(
            typeof(Native.ColorGradingConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.ColorGradingConfig.Version),
                ["struct_size"] = nameof(Native.ColorGradingConfig.StructSize),
                ["shadows_hue"] = nameof(Native.ColorGradingConfig.ShadowsHue),
                ["shadows_saturation"] = nameof(Native.ColorGradingConfig.ShadowsSaturation),
                ["midtones_hue"] = nameof(Native.ColorGradingConfig.MidtonesHue),
                ["midtones_saturation"] = nameof(Native.ColorGradingConfig.MidtonesSaturation),
                ["highlights_hue"] = nameof(Native.ColorGradingConfig.HighlightsHue),
                ["highlights_saturation"] = nameof(Native.ColorGradingConfig.HighlightsSaturation),
            }),
        ["sony2fuji_tone_curve_config"] = new(
            typeof(Native.ToneCurveConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.ToneCurveConfig.Version),
                ["struct_size"] = nameof(Native.ToneCurveConfig.StructSize),
                ["mode"] = nameof(Native.ToneCurveConfig.Mode),
                ["count"] = nameof(Native.ToneCurveConfig.Count),
                ["points"] = nameof(Native.ToneCurveConfig.Points),
            }),
        ["sony2fuji_tone_curve_set_config"] = new(
            typeof(Native.ToneCurveSetConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.ToneCurveSetConfig.Version),
                ["struct_size"] = nameof(Native.ToneCurveSetConfig.StructSize),
                ["curves"] = nameof(Native.ToneCurveSetConfig.Master),
            },
            UnrolledArrays: new[]
            {
                new UnrolledArray(
                    "curves",
                    new[]
                    {
                        nameof(Native.ToneCurveSetConfig.Master),
                        nameof(Native.ToneCurveSetConfig.Red),
                        nameof(Native.ToneCurveSetConfig.Green),
                        nameof(Native.ToneCurveSetConfig.Blue),
                    },
                    ElementCStruct: "sony2fuji_tone_curve_config"),
            }),
        ["sony2fuji_geometry_config"] = new(
            typeof(Native.GeometryConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.GeometryConfig.Version),
                ["struct_size"] = nameof(Native.GeometryConfig.StructSize),
                ["crop_x"] = nameof(Native.GeometryConfig.CropX),
                ["crop_y"] = nameof(Native.GeometryConfig.CropY),
                ["crop_width"] = nameof(Native.GeometryConfig.CropWidth),
                ["crop_height"] = nameof(Native.GeometryConfig.CropHeight),
                ["quarter_turns"] = nameof(Native.GeometryConfig.QuarterTurns),
                ["flip_horizontal"] = nameof(Native.GeometryConfig.FlipHorizontal),
                ["flip_vertical"] = nameof(Native.GeometryConfig.FlipVertical),
                ["straighten_degrees"] = nameof(Native.GeometryConfig.StraightenDegrees),
            }),
        ["sony2fuji_perspective_config"] = new(
            typeof(Native.PerspectiveConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.PerspectiveConfig.Version),
                ["struct_size"] = nameof(Native.PerspectiveConfig.StructSize),
                ["horizontal"] = nameof(Native.PerspectiveConfig.Horizontal),
                ["vertical"] = nameof(Native.PerspectiveConfig.Vertical),
            }),
        ["sony2fuji_lens_correction_config"] = new(
            typeof(Native.LensConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.LensConfig.Version),
                ["struct_size"] = nameof(Native.LensConfig.StructSize),
                ["distortion"] = nameof(Native.LensConfig.Distortion),
                ["tca"] = nameof(Native.LensConfig.Tca),
                ["auto_crop"] = nameof(Native.LensConfig.AutoCrop),
                ["profile_id"] = nameof(Native.LensConfig.ProfileId),
            }),
        ["sony2fuji_lens_correction_config_v2"] = new(
            typeof(Native.LensConfigV2),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.LensConfigV2.Base),
                ["vignetting"] = nameof(Native.LensConfigV2.Vignetting),
            }),
        ["sony2fuji_lens_profile"] = new(
            typeof(Native.LensProfile),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["id"] = nameof(Native.LensProfile.Id),
                ["maker"] = nameof(Native.LensProfile.Maker),
                ["model"] = nameof(Native.LensProfile.Model),
                ["has_distortion"] = nameof(Native.LensProfile.HasDistortion),
                ["has_tca"] = nameof(Native.LensProfile.HasTca),
                ["is_match"] = nameof(Native.LensProfile.IsMatch),
            }),
        ["sony2fuji_lens_report"] = new(
            typeof(Native.LensReport),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["state"] = nameof(Native.LensReport.State),
                ["camera_make"] = nameof(Native.LensReport.CameraMake),
                ["camera_model"] = nameof(Native.LensReport.CameraModel),
                ["lens_model"] = nameof(Native.LensReport.LensModel),
                ["focal_length"] = nameof(Native.LensReport.FocalLength),
                ["profile"] = nameof(Native.LensReport.Profile),
                ["applied_distortion"] = nameof(Native.LensReport.AppliedDistortion),
                ["applied_tca"] = nameof(Native.LensReport.AppliedTca),
                ["crop_scale"] = nameof(Native.LensReport.CropScale),
            }),
        ["sony2fuji_lens_report_v2"] = new(
            typeof(Native.LensReportV2),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.LensReportV2.Base),
                ["has_vignetting"] = nameof(Native.LensReportV2.HasVignetting),
                ["applied_vignetting"] = nameof(Native.LensReportV2.AppliedVignetting),
            }),
        ["sony2fuji_hsl_probe_query"] = new(
            typeof(Native.HslProbeQuery),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HslProbeQuery.Version),
                ["struct_size"] = nameof(Native.HslProbeQuery.StructSize),
                ["source_revision"] = nameof(Native.HslProbeQuery.SourceRevision),
                ["request_revision"] = nameof(Native.HslProbeQuery.RequestRevision),
                ["x"] = nameof(Native.HslProbeQuery.X),
                ["y"] = nameof(Native.HslProbeQuery.Y),
            }),
        ["sony2fuji_hsl_probe_result"] = new(
            typeof(Native.HslProbeResult),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HslProbeResult.Version),
                ["struct_size"] = nameof(Native.HslProbeResult.StructSize),
                ["source_revision"] = nameof(Native.HslProbeResult.SourceRevision),
                ["request_revision"] = nameof(Native.HslProbeResult.RequestRevision),
                ["width"] = nameof(Native.HslProbeResult.Width),
                ["height"] = nameof(Native.HslProbeResult.Height),
                ["availability"] = nameof(Native.HslProbeResult.Availability),
                ["quality"] = nameof(Native.HslProbeResult.Quality),
                ["rgb"] = nameof(Native.HslProbeResult.Rgb),
                ["hsl"] = nameof(Native.HslProbeResult.Hsl),
                ["weights"] = nameof(Native.HslProbeResult.Weights),
            }),
        ["sony2fuji_ai_denoise_config"] = new(
            typeof(Native.AIConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.AIConfig.Version),
                ["struct_size"] = nameof(Native.AIConfig.StructSize),
                ["enabled"] = nameof(Native.AIConfig.Enabled),
                ["backend"] = nameof(Native.AIConfig.Backend),
                ["model_directory"] = nameof(Native.AIConfig.ModelDirectory),
                ["cache_directory"] = nameof(Native.AIConfig.CacheDirectory),
            }),
        ["sony2fuji_processing_migration_result"] = new(
            typeof(Native.ProcessingMigrationResult),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.ProcessingMigrationResult.Version),
                ["struct_size"] = nameof(Native.ProcessingMigrationResult.StructSize),
                ["source_version"] = nameof(Native.ProcessingMigrationResult.SourceVersion),
                ["target_version"] = nameof(Native.ProcessingMigrationResult.TargetVersion),
                ["disposition"] = nameof(Native.ProcessingMigrationResult.Disposition),
                ["evaluation_count"] = nameof(Native.ProcessingMigrationResult.EvaluationCount),
                ["exposure_ev"] = nameof(Native.ProcessingMigrationResult.ExposureEv),
                ["contrast"] = nameof(Native.ProcessingMigrationResult.Contrast),
                ["highlights"] = nameof(Native.ProcessingMigrationResult.Highlights),
                ["shadows"] = nameof(Native.ProcessingMigrationResult.Shadows),
                ["saturation"] = nameof(Native.ProcessingMigrationResult.Saturation),
                ["black_point"] = nameof(Native.ProcessingMigrationResult.BlackPoint),
                ["white_point"] = nameof(Native.ProcessingMigrationResult.WhitePoint),
                ["vibrance"] = nameof(Native.ProcessingMigrationResult.Vibrance),
                ["clarity"] = nameof(Native.ProcessingMigrationResult.Clarity),
                ["dehaze"] = nameof(Native.ProcessingMigrationResult.Dehaze),
                ["rgb_rmse"] = nameof(Native.ProcessingMigrationResult.RgbRmse),
                ["p99_error"] = nameof(Native.ProcessingMigrationResult.P99Error),
                ["worst_tile_rmse"] = nameof(Native.ProcessingMigrationResult.WorstTileRmse),
                ["detail_rmse"] = nameof(Native.ProcessingMigrationResult.DetailRmse),
            }),
        ["sony2fuji_hdr_diagnostic_v1"] = new(
            typeof(Native.HDRDiagnostic),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRDiagnostic.Version),
                ["struct_size"] = nameof(Native.HDRDiagnostic.StructSize),
                ["reason"] = nameof(Native.HDRDiagnostic.Reason),
                ["field"] = nameof(Native.HDRDiagnostic.Field),
            }),
        // Native.HDRSourceInfo flattens sony2fuji_hdr_source_info_v1 (72B prefix) + capabilities tail (76B).
        ["sony2fuji_hdr_source_info_v1"] = new(
            typeof(Native.HDRSourceInfo),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRSourceInfo.Version),
                ["struct_size"] = nameof(Native.HDRSourceInfo.StructSize),
                ["width"] = nameof(Native.HDRSourceInfo.Width),
                ["height"] = nameof(Native.HDRSourceInfo.Height),
                ["orientation"] = nameof(Native.HDRSourceInfo.Orientation),
                ["container"] = nameof(Native.HDRSourceInfo.Container),
                ["protocol"] = nameof(Native.HDRSourceInfo.Protocol),
                ["color_description"] = nameof(Native.HDRSourceInfo.ColorDescription),
                ["content_headroom"] = nameof(Native.HDRSourceInfo.ContentHeadroom),
                ["headroom_kind"] = nameof(Native.HDRSourceInfo.HeadroomKind),
                ["source_sha256"] = nameof(Native.HDRSourceInfo.SourceSha256),
            },
            PrefixEndField: nameof(Native.HDRSourceInfo.CameraCapabilities),
            ReservedFields: new[]
            {
                new ReservedFieldSpec(
                    nameof(Native.HDRSourceInfo.CameraCapabilities),
                    StartOffset: 72,
                    EndOffset: 76,
                    Reason: "Extension tail for sony2fuji_hdr_camera_source_info_v1.capabilities beyond 72B v1 prefix"),
            }),
        ["sony2fuji_hdr_camera_source_info_v1"] = new(
            typeof(Native.HDRSourceInfo),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRSourceInfo.Version),
                ["capabilities"] = nameof(Native.HDRSourceInfo.CameraCapabilities),
            },
            FlattenedBaseCStruct: "sony2fuji_hdr_source_info_v1"),
        ["sony2fuji_hdr_decode_options_v1"] = new(
            typeof(Native.HDRDecodeOptions),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRDecodeOptions.Version),
                ["struct_size"] = nameof(Native.HDRDecodeOptions.StructSize),
                ["intent"] = nameof(Native.HDRDecodeOptions.Intent),
                ["long_edge"] = nameof(Native.HDRDecodeOptions.LongEdge),
            }),
        ["sony2fuji_hdr_camera_development_v1"] = new(
            typeof(Native.HDRCameraDevelopment),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRCameraDevelopment.Version),
                ["struct_size"] = nameof(Native.HDRCameraDevelopment.StructSize),
                ["white_balance"] = nameof(Native.HDRCameraDevelopment.WhiteBalance),
                ["exposure_reference"] = nameof(Native.HDRCameraDevelopment.ExposureReference),
                ["temperature"] = nameof(Native.HDRCameraDevelopment.Temperature),
                ["tint"] = nameof(Native.HDRCameraDevelopment.Tint),
                ["fbdd_level"] = nameof(Native.HDRCameraDevelopment.FbddLevel),
                ["lens_flags"] = nameof(Native.HDRCameraDevelopment.LensFlags),
                ["lens_profile_id"] = nameof(Native.HDRCameraDevelopment.LensProfile),
            }),
        ["sony2fuji_hdr_camera_development_v2"] = new(
            typeof(Native.HDRCameraDevelopmentV2),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRCameraDevelopmentV2.Base),
                ["profile_path"] = nameof(Native.HDRCameraDevelopmentV2.ProfilePath),
                ["profile_sha256"] = nameof(Native.HDRCameraDevelopmentV2.ProfileSha256),
            }),
        ["sony2fuji_hdr_camera_profile_info_v1"] = new(
            typeof(Native.HDRCameraProfileInfo),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRCameraProfileInfo.Version),
                ["struct_size"] = nameof(Native.HDRCameraProfileInfo.StructSize),
                ["camera_model"] = nameof(Native.HDRCameraProfileInfo.CameraModel),
                ["sha256"] = nameof(Native.HDRCameraProfileInfo.Sha256),
            }),
        ["sony2fuji_hdr_buffer_v1"] = new(
            typeof(Native.HDRBuffer),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRBuffer.Version),
                ["struct_size"] = nameof(Native.HDRBuffer.StructSize),
                ["data"] = nameof(Native.HDRBuffer.Data),
                ["size_bytes"] = nameof(Native.HDRBuffer.SizeBytes),
                ["width"] = nameof(Native.HDRBuffer.Width),
                ["height"] = nameof(Native.HDRBuffer.Height),
                ["stride_bytes"] = nameof(Native.HDRBuffer.StrideBytes),
                ["pixel_format"] = nameof(Native.HDRBuffer.PixelFormat),
                ["color_encoding"] = nameof(Native.HDRBuffer.ColorEncoding),
                ["content_headroom"] = nameof(Native.HDRBuffer.ContentHeadroom),
                ["headroom_kind"] = nameof(Native.HDRBuffer.HeadroomKind),
            }),
        ["sony2fuji_hdr_image_pair_v1"] = new(
            typeof(Native.HDRImagePair),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRImagePair.Version),
                ["struct_size"] = nameof(Native.HDRImagePair.StructSize),
                ["hdr"] = nameof(Native.HDRImagePair.Hdr),
                ["sdr"] = nameof(Native.HDRImagePair.Sdr),
                ["native_width"] = nameof(Native.HDRImagePair.NativeWidth),
                ["native_height"] = nameof(Native.HDRImagePair.NativeHeight),
                ["orientation_applied"] = nameof(Native.HDRImagePair.OrientationApplied),
                ["source_intent"] = nameof(Native.HDRImagePair.SourceIntent),
                ["render_intent"] = nameof(Native.HDRImagePair.RenderIntent),
                ["is_proxy"] = nameof(Native.HDRImagePair.IsProxy),
                ["decode_revision"] = nameof(Native.HDRImagePair.DecodeRevision),
                ["source_headroom"] = nameof(Native.HDRImagePair.SourceHeadroom),
                ["source_headroom_kind"] = nameof(Native.HDRImagePair.SourceHeadroomKind),
                ["source_sha256"] = nameof(Native.HDRImagePair.SourceSha256),
                ["owner_token"] = nameof(Native.HDRImagePair.OwnerToken),
                ["output_native_width"] = nameof(Native.HDRImagePair.OutputNativeWidth),
                ["output_native_height"] = nameof(Native.HDRImagePair.OutputNativeHeight),
            }),
        ["sony2fuji_hdr_request_v1"] = new(
            typeof(Native.HDRRequest),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRRequest.Version),
                ["struct_size"] = nameof(Native.HDRRequest.StructSize),
                ["hdr_processing_version"] = nameof(Native.HDRRequest.HDRProcessingVersion),
                ["intent"] = nameof(Native.HDRRequest.Intent),
                ["exposure_ev"] = nameof(Native.HDRRequest.ExposureEv),
                ["temperature"] = nameof(Native.HDRRequest.Temperature),
                ["tint"] = nameof(Native.HDRRequest.Tint),
                ["contrast"] = nameof(Native.HDRRequest.Contrast),
                ["highlights"] = nameof(Native.HDRRequest.Highlights),
                ["shadows"] = nameof(Native.HDRRequest.Shadows),
                ["saturation"] = nameof(Native.HDRRequest.Saturation),
                ["crop_x"] = nameof(Native.HDRRequest.CropX),
                ["crop_y"] = nameof(Native.HDRRequest.CropY),
                ["crop_width"] = nameof(Native.HDRRequest.CropWidth),
                ["crop_height"] = nameof(Native.HDRRequest.CropHeight),
                ["quarter_turns"] = nameof(Native.HDRRequest.QuarterTurns),
                ["flip_horizontal"] = nameof(Native.HDRRequest.FlipHorizontal),
                ["flip_vertical"] = nameof(Native.HDRRequest.FlipVertical),
                ["straighten_degrees"] = nameof(Native.HDRRequest.StraightenDegrees),
                ["perspective_horizontal"] = nameof(Native.HDRRequest.PerspectiveHorizontal),
                ["perspective_vertical"] = nameof(Native.HDRRequest.PerspectiveVertical),
                ["long_edge"] = nameof(Native.HDRRequest.LongEdge),
            }),
        ["sony2fuji_hdr_request_v2"] = new(
            typeof(Native.HDRRequestV2),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV2.Base),
                ["black_point"] = nameof(Native.HDRRequestV2.BlackPoint),
                ["white_point"] = nameof(Native.HDRRequestV2.WhitePoint),
                ["curve_strength"] = nameof(Native.HDRRequestV2.CurveStrength),
                ["reserved"] = nameof(Native.HDRRequestV2.Reserved),
                ["curve"] = nameof(Native.HDRRequestV2.Curve),
            }),
        ["sony2fuji_hdr_request_v3"] = new(
            typeof(Native.HDRRequestV3),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV3.Base),
                ["vibrance"] = nameof(Native.HDRRequestV3.Vibrance),
                ["reserved"] = nameof(Native.HDRRequestV3.Reserved),
                ["hsl"] = nameof(Native.HDRRequestV3.Hsl),
                ["grading"] = nameof(Native.HDRRequestV3.Grading),
            }),
        ["sony2fuji_hdr_request_v4"] = new(
            typeof(Native.HDRRequestV4),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV4.Base),
                ["peak_limit_ev"] = nameof(Native.HDRRequestV4.PeakLimitEV),
                ["sdr_exposure_ev"] = nameof(Native.HDRRequestV4.SdrExposureEV),
                ["sdr_contrast"] = nameof(Native.HDRRequestV4.SdrContrast),
                ["sdr_saturation"] = nameof(Native.HDRRequestV4.SdrSaturation),
            }),
        ["sony2fuji_hdr_request_v5"] = new(
            typeof(Native.HDRRequestV5),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV5.Base),
                ["effects"] = nameof(Native.HDRRequestV5.Effects),
            }),
        ["sony2fuji_hdr_request_v6"] = new(
            typeof(Native.HDRRequestV6),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV6.Base),
                ["sharpening"] = nameof(Native.HDRRequestV6.Sharpening),
                ["clarity"] = nameof(Native.HDRRequestV6.Clarity),
                ["dehaze"] = nameof(Native.HDRRequestV6.Dehaze),
                ["denoise"] = nameof(Native.HDRRequestV6.Denoise),
            }),
        ["sony2fuji_hdr_request_v7"] = new(
            typeof(Native.HDRRequestV7),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV7.Base),
                ["look_path"] = nameof(Native.HDRRequestV7.LookPath),
                ["look_strength"] = nameof(Native.HDRRequestV7.LookStrength),
                ["reserved"] = nameof(Native.HDRRequestV7.Reserved),
                ["look_sha256"] = nameof(Native.HDRRequestV7.LookSha256),
            }),
        ["sony2fuji_hdr_request_v8"] = new(
            typeof(Native.HDRRequestV8),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["base"] = nameof(Native.HDRRequestV8.Base),
                ["channels"] = nameof(Native.HDRRequestV8.Red),
            },
            UnrolledArrays: new[]
            {
                new UnrolledArray(
                    "channels",
                    new[]
                    {
                        nameof(Native.HDRRequestV8.Red),
                        nameof(Native.HDRRequestV8.Green),
                        nameof(Native.HDRRequestV8.Blue),
                    },
                    ElementCStruct: "sony2fuji_tone_curve_config"),
            }),
        ["sony2fuji_hdr_look_info_v1"] = new(
            typeof(Native.HDRLookInfo),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRLookInfo.Version),
                ["struct_size"] = nameof(Native.HDRLookInfo.StructSize),
                ["grid_size"] = nameof(Native.HDRLookInfo.GridSize),
                ["reserved"] = nameof(Native.HDRLookInfo.Reserved),
                ["domain_min"] = nameof(Native.HDRLookInfo.DomainMin),
                ["domain_max"] = nameof(Native.HDRLookInfo.DomainMax),
                ["sha256"] = nameof(Native.HDRLookInfo.Sha256),
            }),
        ["sony2fuji_hdr_export_config_v1"] = new(
            typeof(Native.HDRExportConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRExportConfig.Version),
                ["struct_size"] = nameof(Native.HDRExportConfig.StructSize),
                ["jpeg_quality"] = nameof(Native.HDRExportConfig.JpegQuality),
                ["base_color"] = nameof(Native.HDRExportConfig.BaseColor),
                ["metadata_policy"] = nameof(Native.HDRExportConfig.MetadataPolicy),
                ["metadata_source_path"] = nameof(Native.HDRExportConfig.MetadataSourcePath),
                ["source_sha256"] = nameof(Native.HDRExportConfig.SourceSha256),
            }),
        ["sony2fuji_hdr_sdr_export_config_v1"] = new(
            typeof(Native.HDRSdrExportConfig),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRSdrExportConfig.Version),
                ["struct_size"] = nameof(Native.HDRSdrExportConfig.StructSize),
                ["output_format"] = nameof(Native.HDRSdrExportConfig.OutputFormat),
                ["quality"] = nameof(Native.HDRSdrExportConfig.Quality),
                ["metadata_source_path"] = nameof(Native.HDRSdrExportConfig.MetadataSourcePath),
                ["source_sha256"] = nameof(Native.HDRSdrExportConfig.SourceSha256),
            }),
        ["sony2fuji_hdr_stream_source_v1"] = new(
            typeof(Native.HDRStreamSource),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRStreamSource.Version),
                ["struct_size"] = nameof(Native.HDRStreamSource.StructSize),
                ["native_width"] = nameof(Native.HDRStreamSource.NativeWidth),
                ["native_height"] = nameof(Native.HDRStreamSource.NativeHeight),
                ["orientation_applied"] = nameof(Native.HDRStreamSource.OrientationApplied),
                ["source_intent"] = nameof(Native.HDRStreamSource.SourceIntent),
                ["decode_revision"] = nameof(Native.HDRStreamSource.DecodeRevision),
                ["decoder_identifier"] = nameof(Native.HDRStreamSource.DecoderIdentifier),
                ["source_sha256"] = nameof(Native.HDRStreamSource.SourceSha256),
                ["context"] = nameof(Native.HDRStreamSource.Context),
                ["read_rows"] = nameof(Native.HDRStreamSource.ReadRows),
                ["finish_decode"] = nameof(Native.HDRStreamSource.FinishDecode),
                ["is_cancelled"] = nameof(Native.HDRStreamSource.IsCancelled),
            }),
        ["sony2fuji_hdr_stream_result_v1"] = new(
            typeof(Native.HDRStreamResult),
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["version"] = nameof(Native.HDRStreamResult.Version),
                ["struct_size"] = nameof(Native.HDRStreamResult.StructSize),
                ["width"] = nameof(Native.HDRStreamResult.Width),
                ["height"] = nameof(Native.HDRStreamResult.Height),
                ["native_width"] = nameof(Native.HDRStreamResult.NativeWidth),
                ["native_height"] = nameof(Native.HDRStreamResult.NativeHeight),
                ["output_native_width"] = nameof(Native.HDRStreamResult.OutputNativeWidth),
                ["output_native_height"] = nameof(Native.HDRStreamResult.OutputNativeHeight),
                ["decode_revision"] = nameof(Native.HDRStreamResult.DecodeRevision),
                ["source_headroom"] = nameof(Native.HDRStreamResult.SourceHeadroom),
                ["edited_headroom"] = nameof(Native.HDRStreamResult.EditedHeadroom),
            }),
    };

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static bool TryGetUnmanagedScalarWidth(UnmanagedType unmanagedType, out int sizeBytes)
    {
        switch (unmanagedType)
        {
            case UnmanagedType.I1:
            case UnmanagedType.U1:
                sizeBytes = 1;
                return true;
            case UnmanagedType.I2:
            case UnmanagedType.U2:
                sizeBytes = 2;
                return true;
            case UnmanagedType.I4:
            case UnmanagedType.U4:
            case UnmanagedType.R4:
            case UnmanagedType.Bool:
                sizeBytes = 4;
                return true;
            case UnmanagedType.I8:
            case UnmanagedType.U8:
            case UnmanagedType.R8:
            case UnmanagedType.SysInt:
            case UnmanagedType.SysUInt:
                sizeBytes = 8;
                return true;
            default:
                sizeBytes = 0;
                return false;
        }
    }

    private static bool TryGetValueTypeUnmanagedSize(Type valueType, out int sizeBytes)
    {
        if (!valueType.IsValueType)
        {
            sizeBytes = 0;
            return false;
        }
        if (valueType == typeof(IntPtr) || valueType == typeof(UIntPtr))
        {
            sizeBytes = IntPtr.Size;
            return true;
        }
        if (valueType.IsEnum)
        {
            sizeBytes = Marshal.SizeOf(Enum.GetUnderlyingType(valueType));
            return true;
        }
        sizeBytes = Marshal.SizeOf(valueType);
        return true;
    }

    private static bool TryGetManagedFieldSize(FieldInfo fieldInfo, out int sizeBytes, out string error)
    {
        var marshalAs = fieldInfo.GetCustomAttribute<MarshalAsAttribute>();
        if (marshalAs is not null)
        {
            switch (marshalAs.Value)
            {
                case UnmanagedType.ByValArray:
                {
                    if (!fieldInfo.FieldType.IsArray || fieldInfo.FieldType.GetElementType() is not { } elementType)
                    {
                        sizeBytes = 0;
                        error = "[MarshalAs(ByValArray)] requires an array field type";
                        return false;
                    }
                    if (marshalAs.SizeConst <= 0)
                    {
                        sizeBytes = 0;
                        error = $"[MarshalAs(ByValArray)] must declare positive SizeConst (got {marshalAs.SizeConst})";
                        return false;
                    }
                    if (!TryGetValueTypeUnmanagedSize(elementType, out var elementSize))
                    {
                        sizeBytes = 0;
                        error = $"unsupported ByValArray element type {elementType.Name}";
                        return false;
                    }
                    if (TryGetUnmanagedScalarWidth(marshalAs.ArraySubType, out var subTypeSize) && subTypeSize != elementSize)
                    {
                        sizeBytes = 0;
                        error = $"ByValArray ArraySubType ({marshalAs.ArraySubType}={subTypeSize}B) mismatches {elementType.Name} ({elementSize}B)";
                        return false;
                    }
                    sizeBytes = marshalAs.SizeConst * elementSize;
                    error = string.Empty;
                    return true;
                }
                case UnmanagedType.LPUTF8Str:
                case UnmanagedType.LPStr:
                case UnmanagedType.LPWStr:
                case UnmanagedType.LPTStr:
                {
                    if (fieldInfo.FieldType != typeof(string))
                    {
                        sizeBytes = 0;
                        error = $"[MarshalAs({marshalAs.Value})] expects string field, got {fieldInfo.FieldType.Name}";
                        return false;
                    }
                    sizeBytes = IntPtr.Size;
                    error = string.Empty;
                    return true;
                }
                default:
                {
                    if (TryGetUnmanagedScalarWidth(marshalAs.Value, out sizeBytes))
                    {
                        error = string.Empty;
                        return true;
                    }
                    sizeBytes = 0;
                    error = $"unsupported [MarshalAs({marshalAs.Value})]";
                    return false;
                }
            }
        }

        if (typeof(Delegate).IsAssignableFrom(fieldInfo.FieldType))
        {
            if (fieldInfo.FieldType.GetCustomAttribute<UnmanagedFunctionPointerAttribute>() is null)
            {
                sizeBytes = 0;
                error = $"delegate field type {fieldInfo.FieldType.Name} is missing [UnmanagedFunctionPointer]";
                return false;
            }
            sizeBytes = IntPtr.Size;
            error = string.Empty;
            return true;
        }

        if (TryGetValueTypeUnmanagedSize(fieldInfo.FieldType, out sizeBytes))
        {
            error = string.Empty;
            return true;
        }

        sizeBytes = 0;
        error = $"reference field of type {fieldInfo.FieldType.Name} is missing [MarshalAs]";
        return false;
    }

    private static string ResolveFixturePath()
    {
        const string relativePath = "Shared/fixtures/abi-layout-v1.json";
        if (File.Exists(relativePath)) return relativePath;
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, relativePath);
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("ABI layout fixture not found: " + relativePath);
    }

    internal static void Run()
    {
        Check(IntPtr.Size == 8, "C ABI layout reconciliation requires a 64-bit process");

        using var document = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath()));
        var root = document.RootElement;
        Check(root.GetProperty("version").GetInt32() == 1, "ABI layout fixture version must be 1");

        var sources = root.GetProperty("source").EnumerateArray().Select(item => item.GetString()).ToArray();
        Check(sources.SequenceEqual(new[]
        {
            "lutools/include/sony2fuji/ffi/sony2fuji_c.h",
            "lutools/include/sony2fuji/ffi/sony2fuji_hdr.h",
        }), "ABI layout fixture sources must match canonical C ABI headers");

        var errors = new List<string>();
        var cSizes = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var entry in root.GetProperty("structs").EnumerateArray())
        {
            var cName = entry.GetProperty("name").GetString()
                ?? throw new InvalidDataException("Missing struct name in ABI layout fixture");
            Check(cSizes.TryAdd(cName, entry.GetProperty("size").GetInt32()),
                "Duplicate struct in ABI layout fixture: " + cName);
        }

        foreach (var entry in root.GetProperty("structs").EnumerateArray())
        {
            var cName = entry.GetProperty("name").GetString()!;

            if (UnmappedInNative.Contains(cName))
            {
                Check(!Mappings.ContainsKey(cName), "Struct cannot be both mapped and unmapped: " + cName);
                continue;
            }

            if (!Mappings.TryGetValue(cName, out var mapping))
            {
                errors.Add($"{cName}: missing C# mapping in AbiLayoutChecks");
                continue;
            }

            var clrFields = mapping.ClrType.GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
            var clrFieldByName = clrFields.ToDictionary(field => field.Name, StringComparer.Ordinal);
            var clrFieldOffsets = clrFields.ToDictionary(
                field => field.Name,
                field => Marshal.OffsetOf(mapping.ClrType, field.Name).ToInt32(),
                StringComparer.Ordinal);
            var clrFieldSizes = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var fieldInfo in clrFields)
            {
                if (!TryGetManagedFieldSize(fieldInfo, out var managedSize, out var sizeError))
                {
                    errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{fieldInfo.Name}: {sizeError}");
                }
                else
                {
                    clrFieldSizes[fieldInfo.Name] = managedSize;
                }
            }
            var actualStructSize = Marshal.SizeOf(mapping.ClrType);

            var expectedSize = cSizes[cName];
            if (mapping.PrefixEndField is { } prefixEndField)
            {
                if (!clrFieldOffsets.TryGetValue(prefixEndField, out var actualPrefixSize))
                {
                    errors.Add($"{cName} -> Native.{mapping.ClrType.Name}: PrefixEndField '{prefixEndField}' not found on struct");
                }
                else if (actualPrefixSize != expectedSize)
                {
                    errors.Add($"{cName} -> Native.{mapping.ClrType.Name} (prefix before {prefixEndField}): C size={expectedSize}, C# offset={actualPrefixSize}");
                }
            }
            else
            {
                if (actualStructSize != expectedSize)
                {
                    errors.Add($"{cName} -> Native.{mapping.ClrType.Name}: C size={expectedSize}, C# Marshal.SizeOf={actualStructSize}");
                }
            }

            var coveredClrFields = new HashSet<string>(StringComparer.Ordinal);
            var seenMappedClrFields = new HashSet<string>(StringComparer.Ordinal);
            foreach (var (mappedCField, mappedClrField) in mapping.Fields)
            {
                if (!seenMappedClrFields.Add(mappedClrField))
                {
                    errors.Add($"{cName}: duplicate C# field target Native.{mapping.ClrType.Name}.{mappedClrField} in mapping table");
                }
                if (!clrFieldOffsets.ContainsKey(mappedClrField))
                {
                    errors.Add($"{cName}.{mappedCField} -> Native.{mapping.ClrType.Name}.{mappedClrField}: C# field not found on struct");
                }
                else
                {
                    coveredClrFields.Add(mappedClrField);
                }
            }

            var unrolledCFields = mapping.UnrolledArrays?.Select(item => item.CField).ToHashSet(StringComparer.Ordinal)
                ?? new HashSet<string>(StringComparer.Ordinal);

            var cFieldList = new List<(string Name, int Offset, int Size)>();
            var cFieldOffsets = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var field in entry.GetProperty("fields").EnumerateArray())
            {
                var cField = field.GetProperty("name").GetString()
                    ?? throw new InvalidDataException($"Missing field name in {cName}");
                var expectedOffset = field.GetProperty("offset").GetInt32();
                var expectedFieldSize = field.GetProperty("size").GetInt32();
                Check(expectedFieldSize > 0, $"Invalid non-positive field size for {cName}.{cField}");
                cFieldList.Add((cField, expectedOffset, expectedFieldSize));
                cFieldOffsets.Add(cField, expectedOffset);

                if (!mapping.Fields.TryGetValue(cField, out var clrField))
                {
                    errors.Add($"{cName}.{cField} (C offset={expectedOffset}, size={expectedFieldSize}): missing field mapping on Native.{mapping.ClrType.Name}");
                    continue;
                }

                if (clrFieldOffsets.TryGetValue(clrField, out var actualOffset) && actualOffset != expectedOffset)
                {
                    errors.Add($"{cName}.{cField} -> Native.{mapping.ClrType.Name}.{clrField}: C offset={expectedOffset}, C# offset={actualOffset}");
                }

                var isFlattenedBaseField = cField == "base" && mapping.FlattenedBaseCStruct is not null;
                if (!unrolledCFields.Contains(cField) && !isFlattenedBaseField
                    && clrFieldSizes.TryGetValue(clrField, out var actualFieldSize)
                    && actualFieldSize != expectedFieldSize)
                {
                    errors.Add($"{cName}.{cField} -> Native.{mapping.ClrType.Name}.{clrField}: C size={expectedFieldSize}, C# marshaled size={actualFieldSize}");
                }
            }

            foreach (var mappedCField in mapping.Fields.Keys)
            {
                if (!cFieldOffsets.ContainsKey(mappedCField))
                {
                    errors.Add($"{cName}.{mappedCField}: mapped in C# check but absent from fixture");
                }
            }

            if (mapping.FlattenedBaseCStruct is { } flattenedBaseCStruct)
            {
                if (!Mappings.TryGetValue(flattenedBaseCStruct, out var baseMapping) || baseMapping.ClrType != mapping.ClrType)
                {
                    errors.Add($"{cName}: invalid FlattenedBaseCStruct '{flattenedBaseCStruct}' for Native.{mapping.ClrType.Name}");
                }
                else
                {
                    if (!cFieldOffsets.TryGetValue("base", out var baseOffset) || baseOffset != 0)
                    {
                        errors.Add($"{cName}: FlattenedBaseCStruct requires C 'base' field at offset 0");
                    }
                    var baseBound = cFieldList.Count > 1 ? cFieldList[1].Offset : expectedSize;
                    if (cSizes.TryGetValue(flattenedBaseCStruct, out var baseSize) && baseSize > baseBound)
                    {
                        errors.Add($"{cName}: flattened base {flattenedBaseCStruct} size ({baseSize}) exceeds limit {baseBound}");
                    }
                    if (cFieldList.Count > 0 && cFieldList[0].Name == "base")
                    {
                        var expectedBaseFieldSize = cFieldList[0].Size;
                        if (cSizes.TryGetValue(flattenedBaseCStruct, out var baseStructSize) && baseStructSize != expectedBaseFieldSize)
                        {
                            errors.Add($"{cName}.base: C field size={expectedBaseFieldSize} mismatches {flattenedBaseCStruct} size={baseStructSize}");
                        }
                        if (baseMapping.PrefixEndField is { } basePrefixField
                            && clrFieldOffsets.TryGetValue(basePrefixField, out var flattenedPrefixEnd)
                            && flattenedPrefixEnd != expectedBaseFieldSize)
                        {
                            errors.Add($"{cName}.base -> Native.{mapping.ClrType.Name} (flattened prefix before {basePrefixField}): C size={expectedBaseFieldSize}, C# span={flattenedPrefixEnd}");
                        }
                    }
                    foreach (var baseClrField in baseMapping.Fields.Values)
                    {
                        if (clrFieldOffsets.ContainsKey(baseClrField))
                        {
                            coveredClrFields.Add(baseClrField);
                        }
                    }
                    if (baseMapping.UnrolledArrays is { } baseArrays)
                    {
                        foreach (var baseArray in baseArrays)
                        {
                            foreach (var baseClrField in baseArray.ClrFields)
                            {
                                if (clrFieldOffsets.ContainsKey(baseClrField))
                                {
                                    coveredClrFields.Add(baseClrField);
                                }
                            }
                        }
                    }
                }
            }

            if (mapping.UnrolledArrays is { } unrolledArrays)
            {
                foreach (var array in unrolledArrays)
                {
                    var cFieldIndex = cFieldList.FindIndex(item => item.Name == array.CField);
                    if (cFieldIndex < 0)
                    {
                        errors.Add($"{cName}.{array.CField}: UnrolledArray C field absent from fixture");
                        continue;
                    }

                    if (array.ClrFields.Count == 0)
                    {
                        errors.Add($"{cName}.{array.CField}: UnrolledArray must list at least one C# field");
                        continue;
                    }

                    if (!mapping.Fields.TryGetValue(array.CField, out var headClrField) || headClrField != array.ClrFields[0])
                    {
                        errors.Add($"{cName}.{array.CField}: UnrolledArray head '{array.ClrFields[0]}' must match Fields['{array.CField}']");
                    }

                    var baseOffset = cFieldList[cFieldIndex].Offset;
                    var expectedArraySize = cFieldList[cFieldIndex].Size;
                    var stride = array.ElementCStruct is { } elementStruct ? cSizes[elementStruct] : array.ElementBytes;
                    if (stride <= 0)
                    {
                        errors.Add($"{cName}.{array.CField}: UnrolledArray element stride must be positive (got {stride})");
                        continue;
                    }

                    var seenElements = new HashSet<string>(StringComparer.Ordinal);
                    for (var index = 0; index < array.ClrFields.Count; index++)
                    {
                        var clrField = array.ClrFields[index];
                        if (!seenElements.Add(clrField))
                        {
                            errors.Add($"{cName}.{array.CField}[{index}]: duplicate C# field Native.{mapping.ClrType.Name}.{clrField} in UnrolledArray");
                            continue;
                        }

                        if (!clrFieldByName.ContainsKey(clrField))
                        {
                            errors.Add($"{cName}.{array.CField}[{index}] -> Native.{mapping.ClrType.Name}.{clrField}: C# field not found on struct");
                            continue;
                        }

                        coveredClrFields.Add(clrField);

                        var expectedOffset = baseOffset + index * stride;
                        var actualOffset = clrFieldOffsets[clrField];
                        if (actualOffset != expectedOffset)
                        {
                            errors.Add($"{cName}.{array.CField}[{index}] -> Native.{mapping.ClrType.Name}.{clrField}: C offset={expectedOffset}, C# offset={actualOffset}");
                        }

                        if (clrFieldSizes.TryGetValue(clrField, out var elementSize) && elementSize != stride)
                        {
                            errors.Add($"{cName}.{array.CField}[{index}] -> Native.{mapping.ClrType.Name}.{clrField}: expected element size={stride}, C# marshaled size={elementSize}");
                        }
                    }

                    var actualArraySize = array.ClrFields.Count * stride;
                    if (actualArraySize != expectedArraySize)
                    {
                        var tailField = array.ClrFields[array.ClrFields.Count - 1];
                        errors.Add($"{cName}.{array.CField} (tail Native.{mapping.ClrType.Name}.{tailField}): C size={expectedArraySize}, C# unrolled size={actualArraySize}");
                    }

                    var expectedSpanLimit = cFieldIndex + 1 < cFieldList.Count
                        ? cFieldList[cFieldIndex + 1].Offset
                        : expectedSize;
                    var actualSpanEnd = baseOffset + actualArraySize;
                    if (actualSpanEnd > expectedSpanLimit)
                    {
                        var tailField = array.ClrFields[array.ClrFields.Count - 1];
                        errors.Add($"{cName}.{array.CField} (tail Native.{mapping.ClrType.Name}.{tailField}): unrolled span [{baseOffset}..{actualSpanEnd}) exceeds C span limit {expectedSpanLimit}");
                    }
                }
            }

            var reservedFields = new Dictionary<string, ReservedFieldSpec>(StringComparer.Ordinal);
            if (mapping.ReservedFields is { } declaredReserved)
            {
                foreach (var spec in declaredReserved)
                {
                    if (!reservedFields.TryAdd(spec.ClrField, spec))
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: duplicate ReservedFieldSpec declaration");
                        continue;
                    }

                    if (string.IsNullOrWhiteSpace(spec.Reason))
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: ReservedFieldSpec must state a non-empty reason");
                    }

                    if (coveredClrFields.Contains(spec.ClrField))
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: field is already mapped to C ABI and cannot also be declared as reserved/padding");
                    }

                    if (!clrFieldOffsets.TryGetValue(spec.ClrField, out var actualOffset))
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: declared reserved/padding field not found on struct");
                        continue;
                    }

                    if (spec.StartOffset < 0 || spec.EndOffset <= spec.StartOffset || spec.EndOffset > actualStructSize)
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: invalid reserved byte range [{spec.StartOffset}..{spec.EndOffset}) for struct size {actualStructSize}");
                        continue;
                    }

                    if (actualOffset != spec.StartOffset)
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: reserved StartOffset={spec.StartOffset}, C# offset={actualOffset}");
                    }

                    if (clrFieldSizes.TryGetValue(spec.ClrField, out var reservedFieldSize)
                        && reservedFieldSize != spec.EndOffset - spec.StartOffset)
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: reserved width {spec.EndOffset - spec.StartOffset}B mismatches C# marshaled size={reservedFieldSize}B");
                    }

                    var nextFieldOffset = clrFieldOffsets.Values
                        .Where(offset => offset > actualOffset)
                        .DefaultIfEmpty(actualStructSize)
                        .Min();
                    if (spec.EndOffset > nextFieldOffset)
                    {
                        errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{spec.ClrField}: reserved range [{spec.StartOffset}..{spec.EndOffset}) overlaps next field/end at offset {nextFieldOffset}");
                    }
                }
            }

            foreach (var fieldInfo in clrFields)
            {
                if (!coveredClrFields.Contains(fieldInfo.Name) && !reservedFields.ContainsKey(fieldInfo.Name))
                {
                    var fieldOffset = clrFieldOffsets[fieldInfo.Name];
                    errors.Add($"{cName} -> Native.{mapping.ClrType.Name}.{fieldInfo.Name} (C# offset={fieldOffset}): unmapped instance field; map to C ABI or declare in ReservedFields with explicit [start..end) byte range");
                }
            }
        }

        Check(cSizes.ContainsKey("sony2fuji_hdr_request_v8"),
            "ABI layout fixture must cover sony2fuji_hdr_request_v8");

        foreach (var mappedCStruct in Mappings.Keys)
        {
            if (!cSizes.ContainsKey(mappedCStruct))
            {
                errors.Add($"{mappedCStruct}: mapped in AbiLayoutChecks but missing from ABI layout fixture");
            }
        }

        var mappedClrTypes = Mappings.Values.Select(item => item.ClrType).ToHashSet();
        var nativeStructs = typeof(Native)
            .GetNestedTypes(BindingFlags.Public | BindingFlags.NonPublic)
            .Where(type => type.IsValueType && !type.IsEnum && !Attribute.IsDefined(type, typeof(CompilerGeneratedAttribute)));
        foreach (var nativeStruct in nativeStructs)
        {
            if (!mappedClrTypes.Contains(nativeStruct))
            {
                errors.Add($"Native.{nativeStruct.Name}: unmapped managed P/Invoke struct");
            }
        }

        if (errors.Count > 0)
        {
            throw new Exception("ABI layout drift detected:\n" + string.Join("\n", errors));
        }

        Console.WriteLine($"PASS: Windows Native.cs ABI layout matches {Mappings.Count} C struct definitions ({cSizes.Count} total in fixture)");
    }
}
