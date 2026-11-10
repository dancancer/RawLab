using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace RawLab.Windows;

internal sealed class HDRPairOwner : IDisposable
{
    private Native.HDRImagePair pair;
    private bool released;
    internal ref Native.HDRImagePair Pair => ref pair;
    internal HDRPairOwner(Native.HDRImagePair pair) => this.pair = pair;
    public void Dispose()
    {
        if (released) return;
        released = true;
        Native.sony2fuji_hdr_release_pair(ref pair);
    }
}

internal static class HDRNative
{
    internal const int StatusOk = 0;
    internal const int StatusUnsupported = 2;
    internal const int StatusCancelled = 7;
    internal const uint ReasonNotHDR = 16;
    internal const uint ReasonUnsupportedGpu = 13;
    internal const uint PixelRGB32FLinear = 1;
    internal const uint LinearSRGB = 1;
    internal const uint ContainerCameraRaw = 3;
    internal const uint ContainerProRAW = 4;
    private const uint CameraSourceBayer = 1;
    internal const uint ColorSrgb = 1;
    internal const uint HeadroomUnknown = 0;
    internal const uint ReasonUnsupportedRaw = 17;
    internal const uint ReasonCameraAI = 20;
    internal const uint OutputJpeg = 0;
    internal const uint OutputPng = 1;
    internal const uint OutputDng = 4;
    internal const uint MetadataIsoXmp = 1;
    internal const int ProRAWDecodeVersion = 2;

    internal static string TemporaryRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Cache", "HDR");

    private static string EnsureTemporaryRoot()
    {
        var root = TemporaryRoot;
        Directory.CreateDirectory(root);
        return root;
    }

    internal static Native.HDRDiagnostic Diagnostic() => new() {
        Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRDiagnostic>()
    };
    private static Native.HDRSourceInfo SourceInfo() => new() {
        Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRSourceInfo>(), SourceSha256 = new byte[32]
    };
    private static Native.HDRImagePair Pair() => new() {
        Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRImagePair>(), SourceSha256 = new byte[32]
    };

    internal static HDRProbeState Probe(string path, out HDRSourceInfo? info)
    {
        var native = SourceInfo(); var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_probe(path, ref native, ref diagnostic);
        if (status == StatusOk)
        {
            info = new(HDRProbeState.Supported, native.Width, native.Height, native.Orientation, native.Container,
                native.Protocol, native.ColorDescription, native.ContentHeadroom, native.HeadroomKind,
                native.SourceSha256?.ToArray() ?? []);
            return HDRProbeState.Supported;
        }
        // The shared ABI deliberately distinguishes ordinary input from malformed or unsupported HDR.
        if (status == StatusUnsupported && diagnostic.Reason == ReasonNotHDR)
        {
            info = null;
            return HDRProbeState.NotHDR;
        }
        throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
    }

    internal static HDRProbeState ProbeCameraRaw(string path, out HDRSourceInfo? info)
    {
        var native = SourceInfo(); var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_probe_camera_raw(path, ref native, ref diagnostic);
        if (status == StatusOk)
        {
            info = new(HDRProbeState.Supported, native.Width, native.Height, native.Orientation, native.Container,
                native.Protocol, native.ColorDescription, native.ContentHeadroom, native.HeadroomKind,
                native.SourceSha256?.ToArray() ?? []) {
                CameraStamp = HDRFileStamp.Read(path), SupportsBayerDevelopment = (native.CameraCapabilities & CameraSourceBayer) != 0
            };
            return HDRProbeState.Supported;
        }
        if (status == StatusUnsupported && diagnostic.Reason == ReasonUnsupportedRaw)
        {
            info = null;
            return HDRProbeState.NotHDR;
        }
        throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
    }

    internal static HDRProbeState ProbeProRAW(string path, out HDRSourceInfo? info)
    {
        var native = SourceInfo(); var diagnostic = Diagnostic();
        try
        {
            var status = Native.sony2fuji_hdr_probe_proraw(path, ref native, ref diagnostic);
            if (status == StatusOk)
            {
                info = new(HDRProbeState.Supported, native.Width, native.Height, native.Orientation, native.Container,
                    native.Protocol, native.ColorDescription, native.ContentHeadroom, native.HeadroomKind,
                    native.SourceSha256?.ToArray() ?? []) { CameraStamp = HDRFileStamp.Read(path) };
                return HDRProbeState.Supported;
            }
            if (status == StatusUnsupported && diagnostic.Reason == ReasonUnsupportedRaw)
            {
                info = null;
                return HDRProbeState.NotHDR;
            }
            throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        }
        catch (EntryPointNotFoundException)
        {
            info = null;
            return HDRProbeState.NotHDR;
        }
    }

    internal static HDRPairOwner Decode(string path, HDRIntent intent, uint longEdge = 0, HDRSourceInfo? expected = null,
        Native.Session? session = null, HDRCameraDevelopmentSettings? development = null, bool cameraAI = false)
    {
        if (expected == null) {
            var state = PhotoInput.IsRaw(path)
                ? PhotoInput.ProbeCameraRaw(path, out expected)
                : Probe(path, out expected);
            if (state != HDRProbeState.Supported || expected == null)
                throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        if (longEdge > 65535 || expected.IsProRAW && intent == HDRIntent.Preview && (longEdge == 0 || longEdge > 2048))
            throw new ArgumentOutOfRangeException(nameof(longEdge));
        if (development is { IsDefault: false } && (!development.IsValid || !expected.IsCameraRaw || expected.IsProRAW))
            throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        if (expected.IsCameraRaw && expected.CameraStamp is { } stamp && HDRFileStamp.Read(path) != stamp)
            throw new HDRSourceException(1, 9, 1);
        var options = new Native.HDRDecodeOptions {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRDecodeOptions>(), Intent = (uint)intent, LongEdge = longEdge
        };
        var pair = Pair(); var diagnostic = Diagnostic();
        var status = expected.IsProRAW
            ? Native.sony2fuji_hdr_decode_proraw(session, path, ref options, EnsureTemporaryRoot(), ref pair, ref diagnostic)
            : expected.IsCameraRaw
                ? DecodeCameraRaw()
                : Native.sony2fuji_hdr_decode(path, ref options, ref pair, ref diagnostic);
        int DecodeCameraRaw()
        {
            if (!cameraAI && development is not { IsDefault: false })
                return Native.sony2fuji_hdr_decode_camera_raw(session,path,ref options,ref pair,ref diagnostic);
            var camera = development ?? new();
            if (cameraAI && !camera.AllowsAI) throw new HDRSourceException(2, ReasonCameraAI, 11);
            var config = new Native.HDRCameraDevelopment {
                Version=1, StructSize=(uint)Marshal.SizeOf<Native.HDRCameraDevelopment>(),
                WhiteBalance=camera.CustomWhiteBalance ? 1u : 0, ExposureReference=camera.SensorExposure ? 1u : 0,
                Temperature=(float)camera.Temperature, Tint=(float)camera.Tint, FbddLevel=(uint)camera.FbddLevel,
                LensFlags=(camera.LensDistortion ? 1u : 0) | (camera.LensTca ? 2u : 0) | (camera.LensVignetting ? 8u : 0) |
                    (camera.LensActive && camera.LensAutoCrop ? 4u : 0), LensProfile=camera.LensProfile
            };
            if (camera.CameraProfile is { } profile) {
                config.Version = 2;
                config.StructSize = (uint)Marshal.SizeOf<Native.HDRCameraDevelopmentV2>();
                var profiled = new Native.HDRCameraDevelopmentV2 {
                    Base = config, ProfilePath = profile.RequireAsset(), ProfileSha256 = Encoding.ASCII.GetBytes(profile.Sha256 + '\0')
                };
                return Native.DecodeWithHDRCameraProfile(session,path,ref options,ref profiled,ref pair,ref diagnostic);
            }
            return cameraAI
                ? Native.sony2fuji_hdr_decode_camera_raw_with_ai(session,path,ref options,ref config,ref pair,ref diagnostic)
                : Native.sony2fuji_hdr_decode_camera_raw_with_development(session,path,ref options,ref config,ref pair,ref diagnostic);
        }
        if (status != StatusOk)
        {
            Native.sony2fuji_hdr_release_pair(ref pair);
            if (status == StatusCancelled) throw new OperationCanceledException();
            throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        }
        if (expected.IsCameraRaw)
        {
            bool sameStamp;
            try { sameStamp = expected.CameraStamp is not { } expectedStamp || HDRFileStamp.Read(path) == expectedStamp; }
            catch
            {
                Native.sony2fuji_hdr_release_pair(ref pair);
                throw;
            }
            if (!sameStamp)
            {
                Native.sony2fuji_hdr_release_pair(ref pair);
                throw new HDRSourceException(1, 9, 1);
            }
        }
        else if (pair.SourceSha256 == null || !pair.SourceSha256.SequenceEqual(expected.SourceSha256)) {
            Native.sony2fuji_hdr_release_pair(ref pair);
            throw new HDRSourceException(1, 9, 1);
        }
        return new(pair);
    }

    internal static HDRPairOwner Render(Native.Session session, HDRPairOwner source, HDRSettings settings,
        HDRIntent intent, uint longEdge = 0)
    {
        if (longEdge > 65535) throw new ArgumentOutOfRangeException(nameof(longEdge));
        var request = settings.NativeRenderRequest(intent, longEdge);
        var result = Pair(); var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_render(session, ref source.Pair, ref request, ref result, ref diagnostic);
        if (status != StatusOk)
        {
            Native.sony2fuji_hdr_release_pair(ref result);
            if (status == StatusCancelled) throw new OperationCanceledException();
            throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        }
        return new(result);
    }

    internal static (uint Width,uint Height) GeometrySize(uint width,uint height,GeometrySettings geometry)
    {
        var request=new HDRSettings { Geometry=geometry }.NativeRenderRequest(HDRIntent.Preview).Base.Base.Base.Base.Base.Base.Base;
        var diagnostic=Diagnostic();
        var status=Native.sony2fuji_hdr_geometry_size(width,height,ref request,out var w,out var h,ref diagnostic);
        if(status==StatusCancelled)throw new OperationCanceledException();
        if(status!=0)throw new HDRSourceException(status,diagnostic.Reason,diagnostic.Field);
        return(w,h);
    }

    internal static HDRLookSettings ImportLook(string path, string? directory = null)
    {
        if (!Path.GetExtension(path).Equals(".cube", StringComparison.OrdinalIgnoreCase)) throw new HDRSourceException(1, 18, 10);
        directory ??= HDRLookSettings.Directory;
        Directory.CreateDirectory(directory);
        var staging = Path.Combine(directory, $".import-{Guid.NewGuid():N}.cube");
        try {
            using (var source = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (source.Length is <= 0 or > HDRLookSettings.MaximumBytes) throw new HDRSourceException(1, 18, 10);
                using var copy = File.Open(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                source.CopyTo(copy);
            }
            var info = new Native.HDRLookInfo {
                Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRLookInfo>(),
                DomainMin = new float[3], DomainMax = new float[3], Sha256 = new byte[65]
            };
            var diagnostic = Diagnostic();
            var status = Native.sony2fuji_hdr_probe_look(staging, ref info, ref diagnostic);
            if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
            var look = new HDRLookSettings(System.Text.Encoding.ASCII.GetString(info.Sha256, 0, 64), Path.GetFileNameWithoutExtension(path), 1);
            if (!look.IsValid || look.AssetPath(directory) is not { } destination) throw new HDRSourceException(1, 18, 10);
            if (!look.AssetIsAvailable(directory)) File.Move(staging, destination, overwrite: true);
            return look;
        } finally { File.Delete(staging); }
    }

    internal static string RequireAsset(this HDRCameraProfile profile)
    {
        var path = profile.AssetPath;
        return File.Exists(path) ? path : throw new HDRSourceException(3, 21, 11);
    }

    internal static HDRCameraProfile ImportCameraProfile(string path)
    {
        if (Path.GetExtension(path).ToLowerInvariant() is not (".dcp" or ".rlook"))
            throw new HDRSourceException(1, 21, 11);
        Directory.CreateDirectory(HDRCameraProfile.Directory);
        var staging = Path.Combine(HDRCameraProfile.Directory, $".import-{Guid.NewGuid():N}.profile");
        try {
            using (var source = File.OpenRead(path)) {
                if (source.Length is <= 0 or > HDRLookSettings.MaximumBytes) throw new HDRSourceException(1, 21, 11);
                using var copy = File.Open(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                source.CopyTo(copy);
            }
            var info = new Native.HDRCameraProfileInfo {
                Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRCameraProfileInfo>(),
                CameraModel = new byte[64], Sha256 = new byte[65]
            };
            var diagnostic = Diagnostic();
            var status = Native.sony2fuji_hdr_probe_camera_profile(staging, ref info, ref diagnostic);
            if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
            var profile = new HDRCameraProfile(Encoding.ASCII.GetString(info.Sha256, 0, 64), Path.GetFileNameWithoutExtension(path));
            if (!profile.IsValid) throw new HDRSourceException(1, 21, 11);
            File.Move(staging, profile.AssetPath, overwrite: true);
            return profile;
        } finally { File.Delete(staging); }
    }

    internal static double EstimateAutoExposure(HDRPairOwner source, HDRSettings settings)
    {
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_estimate_auto_exposure(ref source.Pair,
            (float)settings.Temperature, (float)settings.Tint, out var exposure, ref diagnostic);
        if (status != StatusOk)
            throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        return exposure;
    }

    internal static IntPtr CreateHslProbe(Native.Session session, HDRPairOwner source, HDRSettings settings,
        uint longEdge, HslTargetRevision revision)
    {
        var request = settings.NativeRenderRequest(HDRIntent.Preview, longEdge);
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_create_hsl_probe(session, ref source.Pair, ref request,
            revision.Source, revision.Request, out var probe, ref diagnostic);
        if (status == StatusCancelled) throw new OperationCanceledException();
        if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        return probe;
    }

    internal static void ExportHDR(HDRPairOwner source, string? metadataSourcePath, string destination, byte[] sha256, uint quality = 95)
    {
        var config = new Native.HDRExportConfig {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRExportConfig>(), JpegQuality = quality,
            BaseColor = 1, MetadataPolicy = 1, MetadataSourcePath = metadataSourcePath, SourceSha256 = sha256.ToArray()
        };
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_export_jpeg(ref source.Pair, ref config, destination, ref diagnostic);
        if (status == StatusCancelled) throw new OperationCanceledException();
        if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
    }

    internal static void ExportSDR(HDRPairOwner source, ExportFormat format, string? metadataSourcePath, string destination,
        byte[] sha256, uint quality = 95)
    {
        var output = format switch {
            ExportFormat.Jpeg or ExportFormat.SdrJpeg => OutputJpeg,
            ExportFormat.Png => OutputPng,
            ExportFormat.RenderedDng => OutputDng,
            _ => throw new ArgumentOutOfRangeException(nameof(format))
        };
        var config = new Native.HDRSdrExportConfig {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRSdrExportConfig>(), OutputFormat = output,
            Quality = quality, MetadataSourcePath = metadataSourcePath, SourceSha256 = sha256.ToArray()
        };
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_export_sdr(ref source.Pair, ref config, destination, ref diagnostic);
        if (status == StatusCancelled) throw new OperationCanceledException();
        if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
    }

    internal static Native.HDRStreamResult ExportProRAW(Native.Session session, string sourcePath, HDRSettings settings,
        string destination, byte[] sha256, bool keepHdr, uint longEdge = 0, uint quality = 95)
    {
        if (longEdge > 65535) throw new ArgumentOutOfRangeException(nameof(longEdge));
        if (sha256.Length != 32) throw new ArgumentException("A frozen SHA-256 digest is required.", nameof(sha256));
        var request = settings.NativeRenderRequest(HDRIntent.Final, longEdge);
        var config = new Native.HDRExportConfig {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRExportConfig>(), JpegQuality = quality,
            BaseColor = ColorSrgb, MetadataPolicy = MetadataIsoXmp, MetadataSourcePath = sourcePath,
            SourceSha256 = sha256.ToArray()
        };
        var result = new Native.HDRStreamResult {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRStreamResult>()
        };
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_export_proraw(session, sourcePath, ref request, ref config,
            keepHdr ? 1u : 0u, EnsureTemporaryRoot(), destination, ref result, ref diagnostic);
        if (status == StatusCancelled) throw new OperationCanceledException();
        if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        return result;
    }
}
