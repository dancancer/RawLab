using System.Runtime.InteropServices;

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
    internal const uint ReasonNotHDR = 16;
    internal const uint ReasonUnsupportedGpu = 13;
    internal const uint PixelRGB32FLinear = 1;
    internal const uint LinearSRGB = 1;
    internal const uint OutputJpeg = 0;
    internal const uint OutputPng = 1;
    internal const uint OutputDng = 4;

    private static Native.HDRDiagnostic Diagnostic() => new() {
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

    internal static HDRPairOwner Decode(string path, HDRIntent intent, uint longEdge = 0, HDRSourceInfo? expected = null)
    {
        if (expected == null) {
            if (Probe(path, out expected) != HDRProbeState.Supported || expected == null)
                throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        }
        if (longEdge > 65535) throw new ArgumentOutOfRangeException(nameof(longEdge));
        var options = new Native.HDRDecodeOptions {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRDecodeOptions>(), Intent = (uint)intent, LongEdge = longEdge
        };
        var pair = Pair(); var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_decode(path, ref options, ref pair, ref diagnostic);
        if (status != StatusOk)
        {
            Native.sony2fuji_hdr_release_pair(ref pair);
            throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        }
        if (pair.SourceSha256 == null || !pair.SourceSha256.SequenceEqual(expected.SourceSha256)) {
            Native.sony2fuji_hdr_release_pair(ref pair);
            throw new HDRSourceException(1, 9, 1);
        }
        return new(pair);
    }

    internal static HDRPairOwner Render(Native.Session session, HDRPairOwner source, HDRSettings settings,
        HDRIntent intent, uint longEdge = 0)
    {
        if (longEdge > 65535) throw new ArgumentOutOfRangeException(nameof(longEdge));
        var request = settings.NativeRequest(intent, longEdge);
        var result = Pair(); var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_render(session, ref source.Pair, ref request, ref result, ref diagnostic);
        if (status != StatusOk)
        {
            Native.sony2fuji_hdr_release_pair(ref result);
            throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
        }
        return new(result);
    }

    internal static (uint Width,uint Height) GeometrySize(uint width,uint height,GeometrySettings geometry)
    {
        var request=new HDRSettings { Geometry=geometry }.NativeRequest(HDRIntent.Preview,0);
        var diagnostic=Diagnostic();
        var status=Native.sony2fuji_hdr_geometry_size(width,height,ref request,out var w,out var h,ref diagnostic);
        if(status!=0)throw new HDRSourceException(status,diagnostic.Reason,diagnostic.Field);
        return(w,h);
    }

    internal static void ExportHDR(HDRPairOwner source, string input, string destination, byte[] sha256, uint quality = 95)
    {
        var config = new Native.HDRExportConfig {
            Version = 1, StructSize = (uint)Marshal.SizeOf<Native.HDRExportConfig>(), JpegQuality = quality,
            BaseColor = 1, MetadataPolicy = 1, MetadataSourcePath = input, SourceSha256 = sha256.ToArray()
        };
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_export_jpeg(ref source.Pair, ref config, destination, ref diagnostic);
        if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
    }

    internal static void ExportSDR(HDRPairOwner source, ExportFormat format, string input, string destination,
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
            Quality = quality, MetadataSourcePath = input, SourceSha256 = sha256.ToArray()
        };
        var diagnostic = Diagnostic();
        var status = Native.sony2fuji_hdr_export_sdr(ref source.Pair, ref config, destination, ref diagnostic);
        if (status != StatusOk) throw new HDRSourceException(status, diagnostic.Reason, diagnostic.Field);
    }
}
